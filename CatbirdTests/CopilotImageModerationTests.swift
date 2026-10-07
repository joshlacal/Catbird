import CoreGraphics
import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("AskCatbird image moderation")
struct CopilotImageModerationTests {
  private typealias F = RenderingFixtures

  @Test @MainActor
  func textRowRevealNeverUnlocksAdultOffMediaAndWarningsRequireTheirOwnReveal() throws {
    let live = try LivePolicy(label: "porn", policy: F.policy(adult: false))
    let locked = try #require(live.snapshot())
    #expect(locked.rowVisible, "The fixture has already revealed the text row")
    #expect(locked.imageUI.noOverride)
    let revealSession = CopilotImageRevealSession()
    var reveal = ModerationRevealState()
    reveal.show(locked.imageUI)
    #expect(!locked.allows(reveal))
    #expect(!live.source.authorization(snapshot: locked, revealSession: revealSession).permits(live.context, F.viewerDID))

    live.policy = F.policy(labels: ["porn": "warn"])
    let warned = try #require(live.snapshot())
    #expect(warned.imageUI.blur && !warned.imageUI.noOverride)
    #expect(!warned.allows(ModerationRevealState()))
    reveal.show(warned.imageUI)
    #expect(warned.allows(reveal))
    revealSession.show(warned)
    #expect(live.source.authorization(snapshot: warned, revealSession: revealSession).permits(live.context, F.viewerDID))
    reveal.hide()
    #expect(!warned.allows(reveal))
  }

  @Test @MainActor
  func grantIsBoundToLiveAccountRevisionPolicyAndExactPostContext() throws {
    let live = try LivePolicy()
    let snapshot = try #require(live.snapshot())
    let grant = live.source.authorization(snapshot: snapshot, revealSession: .init())
    #expect(grant.permits(live.context, F.viewerDID))
    #expect(!grant.permits(live.context, "did:web:another.test"))
    #expect(!grant.permits(.search(query: "other"), F.viewerDID))
    live.active = false
    #expect(!grant.permits(live.context, F.viewerDID))
    live.active = true
    live.revision += 1
    #expect(!grant.permits(live.context, F.viewerDID), "Leaving and returning cannot restore a prior grant")
    let renewed = live.source.authorization(snapshot: live.snapshot(), revealSession: .init())
    live.post = try F.post(uri: "at://\(F.authorDID)/app.bsky.feed.post/replaced", embed: F.imageEmbed)
    #expect(!renewed.permits(live.context, F.viewerDID))
    #expect(live.snapshot() == nil)
  }

  #if canImport(FoundationModels)
  private static var supportsAttachments: Bool {
    if #available(iOS 27.0, macOS 27.0, *) { return true }
    return false
  }

  @Test(.enabled(if: supportsAttachments), arguments: ["porn", "!hide"])
  @MainActor
  func lockedDecisionNeverLoadsOrAttaches(label: String) async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let live = try LivePolicy(label: label, policy: F.policy(adult: false))
    let snapshot = try #require(live.snapshot())
    var reveal = ModerationRevealState()
    reveal.show(snapshot.imageUI)
    let probe = Probe()
    let revealSession = CopilotImageRevealSession()
    revealSession.show(snapshot)
    let events = try await run(live, probe: probe,
      authorization: live.source.authorization(snapshot: snapshot, revealSession: revealSession))
    #expect(await probe.loads == 0)
    #expect(await probe.counted.allSatisfy { $0.attachmentCount == 0 })
    #expect(await probe.submitted.count == 1)
    #expect(await probe.submitted.allSatisfy { $0.attachmentCount == 0 })
    #expect(events.contains { if case .evidence(let value) = $0 { return value.text.contains("Current moderation") }; return false })
  }

  @Test(.enabled(if: supportsAttachments), arguments: [false, true]) @MainActor
  func allowedControlLoadsAndSubmitsOneCountedImage(revealWarning: Bool) async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let live = try LivePolicy(label: revealWarning ? "porn" : nil, policy: F.policy(labels: ["porn": "warn"]))
    let revealSession = CopilotImageRevealSession()
    if revealWarning { revealSession.show(try #require(live.snapshot())) }
    let probe = Probe()
    let events = try await run(live, probe: probe,
      authorization: live.source.authorization(snapshot: live.snapshot(), revealSession: revealSession))
    #expect(await probe.loads == 1)
    let submitted = try #require(await probe.submitted.first)
    #expect(submitted.attachmentCount == 1)
    #expect(await probe.counted.contains { $0 === submitted })
    #expect(events.contains { if case .completed = $0 { return true }; return false })
  }

  @Test(.enabled(if: supportsAttachments)) @MainActor
  func policyChangeWhileSheetIsOpenInvalidatesSelectionBeforeDownload() async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let live = try LivePolicy(label: "porn", policy: F.policy(labels: ["porn": "warn"]))
    let warned = try #require(live.snapshot())
    var reveal = ModerationRevealState()
    reveal.show(warned.imageUI)
    let revealSession = CopilotImageRevealSession()
    revealSession.show(warned)
    let grant = live.source.authorization(snapshot: warned, revealSession: revealSession)
    #expect(grant.permits(live.context, F.viewerDID))
    live.policy = F.policy(adult: false)
    #expect(live.snapshot()?.allows(reveal) == false)
    let probe = Probe()
    _ = try await run(live, probe: probe, authorization: grant)
    #expect(await probe.loads == 0)
    #expect(await probe.submitted.allSatisfy { $0.attachmentCount == 0 })
  }

  @Test(.enabled(if: supportsAttachments), arguments: [Stage.load, .count, .stream])
  @MainActor
  func policyRevocationAtAsyncBoundaryCannotSubmitOrEmitStaleImageResult(stage: Stage) async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let live = try LivePolicy(label: "porn", policy: F.policy(labels: ["porn": "ignore"]))
    let grant = live.source.authorization(snapshot: live.snapshot(), revealSession: .init())
    let probe = Probe(revokeAt: stage, revoke: {
      #expect(grant.permits(live.context, F.viewerDID), "The named boundary must be reached while authorized")
      live.policy = F.policy(adult: false)
    })
    let events = try await run(live, probe: probe, authorization: grant)
    #expect(await probe.loads == 1)
    #expect(await probe.revokedStages == [stage], "The actual revocation callback must execute exactly once")
    if stage == .load {
      #expect(await probe.counted.allSatisfy { $0.attachmentCount == 0 })
      #expect(await probe.submitted.allSatisfy { $0.attachmentCount == 0 })
    } else if stage == .count {
      let counted = await probe.counted
      #expect(counted.filter { $0.attachmentCount == 1 }.count == 1)
      #expect(await probe.submitted.isEmpty)
      #expect(events.allSatisfy { if case .route = $0 { return true }; return false })
    } else {
      // The request was submitted while permitted; a later revocation must
      // suppress the model's result and every subsequent evidence event.
      let submissions = await probe.submitted
      #expect(submissions.count == 1)
      let submitted = try #require(submissions.first)
      #expect(submitted.attachmentCount == 1)
      #expect(await probe.counted.contains { $0 === submitted })
      #expect(events.allSatisfy { if case .route = $0 { return true }; return false })
    }
  }

  enum SubjectCase: CaseIterable, Equatable, Sendable { case ownPost, recordSelfLabel, quotedLock, avatarLock }

  @Test(.enabled(if: supportsAttachments), arguments: SubjectCase.allCases) @MainActor
  func currentPresentationExceptionsAndSelfLabelsReachTheActualImageRunner(subject: SubjectCase) async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let post: AppBskyFeedDefs.PostView
    switch subject {
    case .ownPost:
      post = try F.post(author: F.profile(did: F.viewerDID), labels: [F.label("porn")], embed: F.imageEmbed)
    case .recordSelfLabel:
      post = try F.post(selfLabels: ["porn"], embed: F.imageEmbed)
    case .quotedLock:
      let quote = try F.quoted(labels: [F.label("!hide", uri: F.quotedURI)], withImage: true)
      post = try F.post(embed: F.imageEmbed, quote: quote, quoteWithMedia: true)
    case .avatarLock:
      post = try F.post(author: F.profile(labels: [F.accountLabel("porn")]), embed: F.imageEmbed)
    }
    let live = LivePolicy(post: post, policy: F.policy(adult: false))
    let snapshot = try #require(live.snapshot())
    let revealSession = CopilotImageRevealSession()
    revealSession.show(snapshot)
    let shouldAllow = subject != .recordSelfLabel
    #expect(snapshot.allows(revealSession.reveal(for: snapshot)) == shouldAllow)
    if subject == .ownPost {
      #expect(snapshot.presentation.media.blurs.contains { $0.noOverride })
      #expect(!snapshot.presentation.media.noOverride, "Use the UI exception, never the raw cause lock")
    }
    if subject == .quotedLock {
      #expect(snapshot.presentation.isFilteredFromList)
      #expect(!snapshot.presentation.hidesRow)
    }
    if subject == .avatarLock { #expect(snapshot.presentation.concealsAvatar) }
    let probe = Probe()
    _ = try await run(live, probe: probe,
      authorization: live.source.authorization(snapshot: snapshot, revealSession: revealSession))
    #expect(await probe.loads == (shouldAllow ? 1 : 0))
    let submitted = try #require(await probe.submitted.first)
    #expect(submitted.attachmentCount == (shouldAllow ? 1 : 0))
    if shouldAllow { #expect(submitted.selectedImageID == live.context.imageCandidates.first?.id) }
  }

  @Test(.enabled(if: supportsAttachments)) @MainActor
  func hidingImageOptionsDuringLoadRevokesGrantWithoutRelyingOnConsumerCancellation() async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let live = try LivePolicy(label: "porn", policy: F.policy(labels: ["porn": "warn"]))
    let snapshot = try #require(live.snapshot())
    let revealSession = CopilotImageRevealSession()
    revealSession.show(snapshot)
    let grant = live.source.authorization(snapshot: snapshot, revealSession: revealSession)
    #expect(grant.permits(live.context, F.viewerDID))
    let probe = Probe(revokeAt: .load, revoke: { revealSession.hide() })
    _ = try await run(live, probe: probe, authorization: grant)
    #expect(!grant.permits(live.context, F.viewerDID))
    #expect(await probe.loads == 1)
    #expect(await probe.counted.allSatisfy { $0.attachmentCount == 0 })
    #expect(await probe.submitted.count == 1)
    #expect(await probe.submitted.allSatisfy { $0.attachmentCount == 0 })
  }

  @available(iOS 27.0, macOS 27.0, *) @MainActor
  private func run(_ live: LivePolicy, probe: Probe, authorization: CopilotImageAuthorization) async throws -> [CopilotTurnEvent] {
    let client = await ATProtoClient(baseURL: URL(string: "https://moderation-fixture.invalid")!)
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: probe.hooks())
    let stream = await agent.streamTurn(conversationID: UUID(), accountDID: F.viewerDID,
      prompt: "Describe the selected image", context: live.context, history: [],
      selectedImageID: live.context.imageCandidates.first?.id, currentClient: client,
      imageAuthorization: authorization)
    var events: [CopilotTurnEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  enum Stage: Equatable, Sendable { case load, count, stream }

  @available(iOS 27.0, macOS 27.0, *)
  private actor Probe {
    let revokeAt: Stage?
    let revoke: @MainActor @Sendable () -> Void
    private(set) var loads = 0
    private(set) var counted: [CopilotTurnInput] = []
    private(set) var submitted: [CopilotTurnInput] = []
    private(set) var revokedStages: [Stage] = []
    init(revokeAt: Stage? = nil, revoke: @escaping @MainActor @Sendable () -> Void = {}) {
      self.revokeAt = revokeAt
      self.revoke = revoke
    }
    nonisolated func hooks() -> CopilotTurnHooks {
      .init(runtime: .init(contextSize: 4_096, reservedTokenCount: 1_000,
        countsFullPrompt: true, imageUnavailableReason: nil,
        tokenCount: { await self.count($0) }, stream: { input in
          AsyncThrowingStream { continuation in
            let task = Task {
              await self.submit(input)
              continuation.yield("Image answer")
              continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
          }
        }), read: { _, _ in .init(evidence: []) }, loadImage: { _ in try await self.load() })
    }
    private func load() async throws -> CGImage {
      loads += 1
      await revokeIfNeeded(.load)
      let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      return try #require(context.makeImage())
    }
    private func count(_ input: CopilotTurnInput) async -> Int {
      counted.append(input)
      await revokeIfNeeded(.count)
      return 100
    }
    private func submit(_ input: CopilotTurnInput) async {
      submitted.append(input)
      await revokeIfNeeded(.stream)
    }
    private func revokeIfNeeded(_ stage: Stage) async {
      guard revokeAt == stage else { return }
      await revoke()
      revokedStages.append(stage)
    }
  }
  #endif

  @MainActor
  private final class LivePolicy {
    var post: AppBskyFeedDefs.PostView
    var policy: ModerationPolicy
    var active = true
    var revision: UInt64 = 1
    let context: CopilotContext
    convenience init(label: String? = nil, policy: ModerationPolicy = F.policy()) throws {
      let labels = try label.map { [try F.label($0)] }
      let post = try F.post(labels: labels, embed: F.imageEmbed)
      self.init(post: post, policy: policy)
    }
    init(post: AppBskyFeedDefs.PostView, policy: ModerationPolicy) {
      self.post = post
      self.policy = policy
      let evidence = CopilotPostEvidenceBuilder.build(post)
      context = .post(uri: post.uri.uriString(), cid: post.cid.string,
        authorDID: post.author.did.didString(), text: "Post text", evidence: evidence)
    }
    var source: CopilotImageModerationSource {
      .init { context, account in
        guard self.active, context == self.context, account == F.viewerDID else { return nil }
        return self.snapshot()
      }
    }
    func snapshot() -> CopilotImageModerationSnapshot? {
      guard active else { return nil }
      let presentation = PostModerationPresentation.make(post: post, policy: policy)
      return .make(context: context, accountDID: F.viewerDID, accountRevision: revision,
        clientID: nil, post: post, policy: policy, revealedFilter: presentation.filterIdentity)
    }
  }
}
