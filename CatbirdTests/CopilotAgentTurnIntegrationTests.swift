import CoreGraphics
import Foundation
import Petrel
import Testing
#if canImport(FoundationModels)
import FoundationModels
@testable import Catbird

struct CopilotAgentTurnIntegrationTests {
  private static var supported: Bool {
    if #available(iOS 26.0, macOS 26.0, *) { return true }
    return false
  }
  private static var imageSupported: Bool {
    if #available(iOS 27.0, macOS 27.0, *) { return true }
    return false
  }

  @Test(.enabled(if: supported))
  func currentClientInjectionReplacesCachedClientBeforeReadAndNilDoesNotReuseIt() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let original = await ATProtoClient(baseURL: URL(string: "https://old-client.invalid")!)
    let replacement = await ATProtoClient(baseURL: URL(string: "https://new-client.invalid")!)
    let fixture = Fixture()
    let agent = BlueskyIntelligenceAgent(client: original, turnHooks: fixture.hooks())
    let events = try await collect(await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a",
      prompt: "Answer", context: .search(query: "text"), history: [], currentClient: replacement, imageAuthorization: .init { _, _ in true }))
    #expect(await fixture.readClients == [ObjectIdentifier(replacement)])
    #expect(events.contains { if case .completed = $0 { return true }; return false })
    do {
      _ = try await collect(await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a",
        prompt: "Answer", context: .search(query: "text"), history: [], currentClient: nil, imageAuthorization: .init { _, _ in true }))
      Issue.record("A nil current client reused the cached client")
    } catch let error as BlueskyAgentError {
      #expect(error.localizedDescription == BlueskyAgentError.missingClient.localizedDescription)
    }
    #expect(await fixture.readClients.count == 1)
  }

  @Test(.enabled(if: supported), arguments: Stage.allCases, Invalidation.allCases)
  func actualActorInvalidationSuppressesAllStaleEvents(_ stage: Stage, _ invalidation: Invalidation) async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let client = await ATProtoClient(baseURL: URL(string: "https://turn-client.invalid")!)
    let fixture = Fixture(pausedStage: stage)
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: fixture.hooks())
    let context = imageContext()
    let stream = await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Inspect",
      context: context, history: [], selectedImageID: context.imageCandidates.first?.id, currentClient: client, imageAuthorization: .init { _, _ in true })
    let consumer = Task { try await self.collect(stream) }
    await fixture.gate.waitForEntry()
    var replacementStream: AsyncThrowingStream<CopilotTurnEvent, Error>?
    switch invalidation {
    case .client:
      let replacement = await ATProtoClient(baseURL: URL(string: "https://replacement.invalid")!)
      await agent.updateClient(replacement)
    case .context:
      await agent.resetContext()
    case .conversation:
      // This is the production new conversation/history boundary: a new stream
      // atomically supersedes the earlier context and history on the same actor.
      replacementStream = await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "New history",
        context: .search(query: "replacement context"), history: [.init(role: .user, text: "Replacement")], currentClient: client, imageAuthorization: .init { _, _ in true })
    }
    await fixture.gate.release()
    let events = try await consumer.value
    #expect(events.allSatisfy { if case .route = $0 { return true }; return false })
    if let replacementStream {
      let replacementEvents = try await collect(replacementStream)
      #expect(replacementEvents.contains { if case .completed = $0 { return true }; return false })
    }
  }

  @Test(.enabled(if: supported), arguments: Stage.allCases)
  func cancellingActualConsumerStopsTurnAtEachSuspension(_ stage: Stage) async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let client = await ATProtoClient(baseURL: URL(string: "https://cancel-client.invalid")!)
    let fixture = Fixture(pausedStage: stage)
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: fixture.hooks())
    let context = imageContext()
    let stream = await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Inspect",
      context: context, history: [], selectedImageID: context.imageCandidates.first?.id, currentClient: client, imageAuthorization: .init { _, _ in true })
    let consumer = Task { try await self.collect(stream) }
    await fixture.gate.waitForEntry()
    consumer.cancel()
    await fixture.gate.release()
    let events = try await consumer.value
    #expect(events.allSatisfy { if case .route = $0 { return true }; return false })
    await fixture.gate.waitForExit()
  }

  @Test(.enabled(if: supported))
  func staleDependencyFailureDoesNotEscapeAfterClientReplacement() async throws {
    guard #available(iOS 26.0, macOS 26.0, *) else { return }
    let client = await ATProtoClient(baseURL: URL(string: "https://failure-client.invalid")!)
    let fixture = Fixture(pausedStage: .count, failAfterPause: true)
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: fixture.hooks())
    let stream = await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Read",
      context: .search(query: "source"), history: [], currentClient: client, imageAuthorization: .init { _, _ in true })
    let consumer = Task { try await self.collect(stream) }
    await fixture.gate.waitForEntry()
    await agent.updateClient(nil)
    await fixture.gate.release()
    let events = try await consumer.value
    #expect(events.allSatisfy { if case .route = $0 { return true }; return false })
  }

  @Test(.enabled(if: imageSupported))
  func actorCountsAndSubmitsSameCurrentAttachmentAndNeverHistoricalAttachment() async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let client = await ATProtoClient(baseURL: URL(string: "https://prompt-client.invalid")!)
    let fixture = Fixture()
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: fixture.hooks())
    let context = imageContext()
    let selected = try #require(context.imageCandidates.last)
    let historicalImageID = "old-post:historical-image"
    let history: [CopilotStoredTurn] = [
      .init(role: .user, text: "Prior", createdAt: Date(timeIntervalSince1970: 1), selectedImageID: historicalImageID),
      .init(role: .assistant, text: "Prior answer", createdAt: Date(timeIntervalSince1970: 2))
    ]
    let events = try await collect(await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Inspect this",
      context: context, history: history, selectedImageID: selected.id, currentClient: client, imageAuthorization: .init { _, _ in true }))
    let submitted = try #require(await fixture.submitted.first)
    #expect(submitted.attachmentCount == 1)
    #expect(submitted.selectedImageID == selected.id)
    #expect(submitted.image?.width == 3)
    #expect(submitted.text.contains(historicalImageID))
    #expect(await fixture.counted.contains { $0 === submitted })
    #expect(await fixture.loadedURLs == [selected.thumbnailURL!])
    #expect(events.contains { if case .source = $0 { return true }; return false })
    #expect(events.contains { if case .evidence(let evidence) = $0 { return evidence.origin == "selected_image" }; return false })
    #expect(events.contains { if case .proposal = $0 { return true }; return false })
    #expect(events.contains { if case .completed = $0 { return true }; return false })

    _ = try await collect(await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Follow up",
      context: context, history: history, selectedImageID: nil, currentClient: client, imageAuthorization: .init { _, _ in true }))
    let followup = try #require(await fixture.submitted.last)
    #expect(followup.attachmentCount == 0 && followup.selectedImageID == nil)
    #expect(await fixture.loadedURLs.count == 1)
    #expect(await fixture.counted.contains { $0 === followup })
  }

  @Test(.enabled(if: imageSupported))
  func actorRecountsAndSubmitsSameMetadataFallbackWhenAttachmentCannotFit() async throws {
    guard #available(iOS 27.0, macOS 27.0, *) else { return }
    let client = await ATProtoClient(baseURL: URL(string: "https://budget-client.invalid")!)
    let fixture = Fixture(imageCannotFit: true)
    let agent = BlueskyIntelligenceAgent(client: client, turnHooks: fixture.hooks())
    let context = imageContext()
    let events = try await collect(await agent.streamTurn(conversationID: UUID(), accountDID: "did:plc:a", prompt: "Inspect",
      context: context, history: [], selectedImageID: context.imageCandidates.first?.id, currentClient: client, imageAuthorization: .init { _, _ in true }))
    #expect(await fixture.counted.contains { $0.attachmentCount == 1 })
    let submitted = try #require(await fixture.submitted.first)
    #expect(submitted.attachmentCount == 0 && submitted.selectedImageID == nil)
    #expect(submitted.text.contains("Image not inspected"))
    #expect(submitted.text.contains("context budget"))
    #expect(await fixture.counted.contains { $0 === submitted })
    let statuses = events.compactMap { event -> CopilotEvidence? in
      if case .evidence(let evidence) = event, evidence.origin == "selected_image" { return evidence }
      return nil
    }
    #expect(statuses.count == 1)
    #expect(statuses.first?.text.contains("Image not inspected") == true)
  }

  enum Stage: String, CaseIterable, Sendable { case read, load, count, stream }
  enum Invalidation: String, CaseIterable, Sendable { case client, context, conversation }

  private func collect(_ stream: AsyncThrowingStream<CopilotTurnEvent, Error>) async throws -> [CopilotTurnEvent] {
    var events: [CopilotTurnEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  private func imageContext() -> CopilotContext {
    let uri = "at://did:plc:a/app.bsky.feed.post/image"
    let snapshot = CopilotPostEvidence(selectedPost: .init(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Selected", media: [
      .init(kind: .image, altText: "First", thumbnailURL: URL(string: "https://example.invalid/first")),
      .init(kind: .image, altText: "Second", thumbnailURL: URL(string: "https://example.invalid/second"))
    ]), quotedPosts: [], coverage: ["Metadata snapshot"])
    return .post(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Selected", evidence: snapshot)
  }

  private actor Gate {
    var entered = false
    var exited = false
    var released = false
    var entrants: [CheckedContinuation<Void, Never>] = []
    var exits: [CheckedContinuation<Void, Never>] = []
    var blocked: [CheckedContinuation<Void, Never>] = []
    func pause() async {
      entered = true
      entrants.forEach { $0.resume() }; entrants.removeAll()
      if !released { await withCheckedContinuation { blocked.append($0) } }
      exited = true
      exits.forEach { $0.resume() }; exits.removeAll()
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { entrants.append($0) } } }
    func waitForExit() async { if !exited { await withCheckedContinuation { exits.append($0) } } }
    func release() {
      released = true
      blocked.forEach { $0.resume() }; blocked.removeAll()
    }
  }

  @available(iOS 26.0, macOS 26.0, *)
  private actor Fixture {
    nonisolated let gate = Gate()
    nonisolated let pausedStage: Stage?
    nonisolated let imageCannotFit: Bool
    nonisolated let failAfterPause: Bool
    private(set) var readClients: [ObjectIdentifier] = []
    private(set) var loadedURLs: [URL] = []
    private(set) var counted: [CopilotTurnInput] = []
    private(set) var submitted: [CopilotTurnInput] = []
    init(pausedStage: Stage? = nil, imageCannotFit: Bool = false, failAfterPause: Bool = false) {
      self.pausedStage = pausedStage
      self.imageCannotFit = imageCannotFit
      self.failAfterPause = failAfterPause
    }
    nonisolated func hooks() -> CopilotTurnHooks {
      .init(runtime: .init(contextSize: 4_096, reservedTokenCount: 1_000, countsFullPrompt: true,
        imageUnavailableReason: nil, tokenCount: { try await self.count($0) }, stream: { input in
          AsyncThrowingStream { continuation in
            let task = Task {
              do {
                try await self.submit(input)
                continuation.yield("Fixture answer")
                continuation.finish()
              } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
          }
        }), read: { try await self.read($0, context: $1) }, loadImage: { try await self.load($0) })
    }
    private func pause(_ stage: Stage) async throws {
      if pausedStage == stage {
        await gate.pause()
        if failAfterPause { throw FixtureError.failed }
      }
    }
    private func read(_ client: ATProtoClient, context: CopilotContext) async throws -> CopilotTurnHooks.Material {
      readClients.append(ObjectIdentifier(client))
      try await pause(.read)
      return .init(evidence: [.init(origin: "fixture_source", text: "Supplied source",
        sources: [.init(label: "Source", uri: "at://did:plc:a/app.bsky.feed.post/source")], wasTruncated: false)],
        proposal: .preparePostDraft(text: "Draft"))
    }
    private func load(_ url: URL) async throws -> CGImage {
      loadedURLs.append(url)
      try await pause(.load)
      let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      return try #require(context.makeImage())
    }
    private func count(_ input: CopilotTurnInput) async throws -> Int {
      counted.append(input)
      try await pause(.count)
      return imageCannotFit && input.attachmentCount == 1 ? 4_000 : 100
    }
    private func submit(_ input: CopilotTurnInput) async throws {
      submitted.append(input)
      try await pause(.stream)
    }
    private enum FixtureError: Error { case failed }
  }
}
#endif
