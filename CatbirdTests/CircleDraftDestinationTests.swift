import Foundation
import Petrel
import PetrelCatbird
import SwiftData
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

@Suite("Circle draft destination", .serialized)
@MainActor
struct CircleDraftDestinationTests {
  private let account = "did:plc:alice"
  private var parentURI: String { "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/parent123" }
  private var rootURI: String { "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/root456" }

  // MARK: - Saving and decoding

  @Test("A Circle reply saves its Circle, account and thread references, and decodes them unchanged")
  func circleReplyRoundTrips() async throws {
    let appState = await makeAppState()
    let parent = CircleTestFixtures.makePostView(uri: try ATProtocolURI(uriString: parentURI))
    let model = PostComposerViewModel(
      parentPost: parent, destination: .circle(CircleTestFixtures.family), appState: appState
    )
    model.postText = "Private reply"

    let draft = model.saveDraftState()
    let saved = try #require(draft.circleDestination)
    #expect(saved.accountDID == account)
    #expect(saved.spaceURI == CircleTestFixtures.familyURI.uriString())
    #expect(saved.circleID == CircleTestFixtures.familyCircleId.toString())
    #expect(saved.name == "Family")
    #expect(saved.ownerDID == CircleTestFixtures.alice.didString())
    #expect(saved.reply?.parentURI == parentURI)
    #expect(saved.reply?.parentCID == parent.cid.string)
    #expect(saved.reply?.rootURI == parentURI)

    let decoded = try JSONDecoder().decode(PostComposerDraft.self, from: JSONEncoder().encode(draft))
    #expect(decoded == draft)
    let circle = try #require(decoded.circleDestination?.circle)
    #expect(circle.uri == CircleTestFixtures.familyURI)
    #expect(circle.circleId == CircleTestFixtures.familyCircleId)
    #expect(circle.name == "Family")
    #expect(circle.owner == CircleTestFixtures.alice)
    let ref = try #require(decoded.circleDestination?.reply?.ref)
    #expect(ref.parent.uri.uriString() == parentURI)
    #expect(ref.parent.cid.string == parent.cid.string)
  }

  @Test("A draft saved before destinations existed decodes and restores as Public")
  func legacyDraftRestoresPublic() async throws {
    let legacy = Data("""
      {"postText":"Saved long ago","mediaItems":[],"selectedLanguages":[],"selectedLabels":[],
       "outlineTags":[],"threadEntries":[],"isThreadMode":false,"currentThreadIndex":0}
      """.utf8)
    let draft = try JSONDecoder().decode(PostComposerDraft.self, from: legacy)
    #expect(draft.circleDestination == nil)

    let appState = await makeAppState()
    let model = PostComposerViewModel(destination: .circle(CircleTestFixtures.family), appState: appState)
    model.restoreDraftState(draft)
    #expect(model.postText == "Saved long ago")
    #expect(model.destination == .public)
    #expect(model.unresolvedCircleAudience == nil)
    #expect(model.canChangeDestination)

    // A Public draft saves exactly the keys it always did.
    let encoded = try JSONEncoder().encode(model.saveDraftState())
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(!object.keys.contains("circleDestination"))
  }

  // MARK: - Restoring

  @Test("Restoring a Circle reply rebuilds the Circle composer and posts with the saved references")
  func restoreIntoCircle() async throws {
    let appState = await makeAppState(circlesEnabled: true, allowWrites: true)
    let transport = DestinationRecordingCircleTransport()
    let model = PostComposerViewModel(appState: appState, circleService: CircleService(transport: transport))
    let reply = savedReply()
    let saved = CircleDraftDestination(circle: CircleTestFixtures.family, accountDID: account, reply: reply)

    model.restoreDraftState(makeDraft("Private reply", parentURI: parentURI, destination: saved))

    guard case .circle(let restored) = model.destination else {
      Issue.record("A Circle draft must restore into its Circle")
      return
    }
    #expect(restored.uri == CircleTestFixtures.familyURI)
    #expect(restored.name == "Family")
    #expect(model.isReplyLockedToCircle)
    #expect(!model.canChangeDestination)
    #expect(model.unresolvedCircleAudience == nil)

    // The parent loads through the Circle's own thread read; the saved references win.
    try await waitUntil { model.parentPost != nil }
    let ref = try #require(model.circleReplyRef())
    #expect(ref.root.uri.uriString() == rootURI)
    #expect(ref.root.cid.string == reply.rootCID)
    #expect(ref.parent.uri.uriString() == parentURI)
    #expect(ref.parent.cid.string == reply.parentCID)

    _ = try await model.createPost()
    let published = await transport.publishedPosts
    #expect(published.count == 1)
    #expect(published.first?.destination.uri == CircleTestFixtures.familyURI)
    #expect(published.first?.draft.text == "Private reply")
    #expect(published.first?.draft.reply?.root.uri.uriString() == rootURI)
    #expect(published.first?.draft.reply?.parent.cid.string == reply.parentCID)
    #expect(await transport.publicEndpointCallCount == 0)
  }

  @Test("A Circle that is gone keeps the draft private and blocks posting until an audience is chosen")
  func missingCircleBlocksPosting() async throws {
    let appState = await makeAppState(circlesEnabled: true, allowWrites: true)
    // The account's Circles list only Family.
    let transport = DestinationRecordingCircleTransport()
    let model = PostComposerViewModel(appState: appState, circleService: CircleService(transport: transport))
    let saved = CircleDraftDestination(circle: CircleTestFixtures.work, accountDID: account, reply: nil)

    model.restoreDraftState(makeDraft("Only for Work", destination: saved))
    try await waitUntil { model.unresolvedCircleAudience != nil }

    #expect(model.unresolvedCircleAudience?.issue == .circleUnavailable(name: "Work"))
    #expect(model.destination != .public)
    #expect(!model.submitValidationState.canSubmit)
    #expect(model.submitValidationState.reason == .circleAudienceUnresolved(.circleUnavailable(name: "Work")))
    do {
      _ = try await model.createPost()
      Issue.record("A Circle that is gone must block posting")
    } catch {
      #expect(error.localizedDescription == CircleDraftAudienceIssue.circleUnavailable(name: "Work").message)
    }
    #expect(await transport.publishedPosts.isEmpty)

    // Saving keeps the block, so the next restore is still private.
    #expect(model.saveDraftState().circleDestination == saved)
    let reopened = PostComposerViewModel(appState: appState, circleService: CircleService(transport: transport))
    reopened.restoreDraftState(model.saveDraftState())
    try await waitUntil { reopened.unresolvedCircleAudience != nil }
    #expect(reopened.destination != .public)

    // Only the author's explicit choice makes it Public.
    model.selectDestination(.public)
    #expect(model.unresolvedCircleAudience == nil)
    #expect(model.destination == .public)
    #expect(model.saveDraftState().circleDestination == nil)
  }

  @Test("While Circles are unavailable a Circle draft stays in its Circle and reads nothing")
  func unavailableCirclesStayPrivate() async throws {
    let appState = await makeAppState()
    let transport = MockCircleTransport()
    let listings = CallCounter()
    await transport.setOnListCircles { await listings.increment() }
    let model = PostComposerViewModel(appState: appState, circleService: CircleService(transport: transport))
    let saved = CircleDraftDestination(circle: CircleTestFixtures.family, accountDID: account, reply: savedReply())
    let circle = try #require(saved.circle)

    model.restoreDraftState(makeDraft("Private reply", parentURI: parentURI, destination: saved))

    #expect(model.destination == .circle(circle))
    #expect(!model.canPostToDestination)
    #expect(model.isReplyLockedToCircle)
    #expect(model.parentRestoreFailed)
    #expect(model.saveDraftState().circleDestination == saved)

    // Turning it into a new post keeps the Circle and posting stays blocked.
    model.detachUnavailableParent()
    #expect(model.destination == .circle(circle))
    #expect(!model.canPostToDestination)
    #expect(model.saveDraftState().circleDestination?.reply == nil)

    try await Task.sleep(for: .milliseconds(100))
    #expect(await listings.count == 0)
    #expect(await transport.threadCallCount == 0)
  }

  @Test("A Circle draft never restores under another account and its reply is never read")
  func otherAccountBlocksPosting() async throws {
    let appState = await makeAppState(circlesEnabled: true)
    let transport = MockCircleTransport()
    let listings = CallCounter()
    await transport.setOnListCircles { await listings.increment() }
    let model = PostComposerViewModel(appState: appState, circleService: CircleService(transport: transport))
    let saved = CircleDraftDestination(
      circle: CircleTestFixtures.family, accountDID: "did:plc:someoneelse", reply: savedReply()
    )

    let circle = try #require(saved.circle)

    model.restoreDraftState(makeDraft("Their reply", parentURI: parentURI, destination: saved))

    #expect(model.unresolvedCircleAudience?.issue == .otherAccount)
    #expect(model.destination != .circle(circle))
    #expect(!model.submitValidationState.canSubmit)
    #expect(model.parentRestoreFailed)
    // A reply into a Circle never becomes a public reply.
    #expect(!model.canChangeDestination)
    // Saving keeps the original account, so it stays blocked here.
    #expect(model.saveDraftState().circleDestination == saved)

    model.detachUnavailableParent()
    #expect(model.canChangeDestination)
    #expect(model.unresolvedCircleAudience != nil)
    #expect(model.saveDraftState().circleDestination?.accountDID == "did:plc:someoneelse")
    #expect(model.saveDraftState().circleDestination?.reply == nil)

    // Clearing the composer ends the restored draft; the next post shows its audience.
    model.clearAll()
    #expect(model.unresolvedCircleAudience == nil)
    #expect(model.canChangeDestination)
    #expect(model.saveDraftState().circleDestination == nil)

    try await Task.sleep(for: .milliseconds(100))
    #expect(await listings.count == 0)
    #expect(await transport.threadCallCount == 0)
  }

  @Test("A draft waiting for an audience cannot become a thread, which would hide its picker")
  func unresolvedAudienceBlocksThreadMode() async throws {
    let appState = await makeAppState(circlesEnabled: true)
    let model = PostComposerViewModel(appState: appState, circleService: CircleService(transport: MockCircleTransport()))
    let saved = CircleDraftDestination(
      circle: CircleTestFixtures.family, accountDID: "did:plc:someoneelse", reply: nil
    )

    model.restoreDraftState(makeDraft("Their post", destination: saved))
    #expect(model.unresolvedCircleAudience?.issue == .otherAccount)
    #expect(model.canChangeDestination)
    #expect(!model.allowsThreads)

    model.enterThreadMode()
    model.addNewThreadEntry()
    #expect(!model.isThreadMode)
    #expect(model.threadEntries.count == 1)
    #expect(model.unresolvedCircleAudience != nil)

    // Choosing Public is the author's decision; threads work from then on.
    model.selectDestination(.public)
    #expect(model.allowsThreads)
    model.enterThreadMode()
    model.addNewThreadEntry()
    #expect(model.isThreadMode)
    #expect(model.threadEntries.count == 2)
  }

  @Test("Minimizing, scene recovery and the saved-drafts list keep the Circle")
  func sceneRecoveryKeepsCircle() async throws {
    let appState = await makeAppState()
    let suiteName = "CircleDraftDestinationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let manager = ComposerDraftManager(accountDID: account, modelContext: container.mainContext, defaults: defaults)
    let sceneID = UUID()
    let scene = SceneComposerEditingSession(manager: manager, accountDID: account, sceneID: sceneID, defaults: defaults)
    defer { scene.invalidate() }
    let model = PostComposerViewModel(appState: appState, editingSession: scene)
    let saved = CircleDraftDestination(circle: CircleTestFixtures.family, accountDID: account, reply: nil)

    try model.startEditing(restoring: makeDraft("Minimized Circle post", destination: saved))
    #expect(model.minimizeEditingDraft())
    #expect(scene.currentDraft?.circleDestination == saved)

    let recovered = SceneComposerEditingSession(
      manager: manager, accountDID: account, sceneID: sceneID, defaults: defaults
    )
    defer { recovered.invalidate() }
    #expect(recovered.currentDraft?.circleDestination == saved)
    let id = try recovered.stash(try #require(recovered.snapshot()))
    let row = try #require(try DraftPersistence(modelContext: container.mainContext).fetchDraftModel(id: id))
    #expect(try row.decodeDraft().circleDestination == saved)
    #expect(DraftPostViewModel(draftPost: row).circleName == "Family")
  }

  // MARK: - Sync

  @Test("Circle drafts are never sent to Bluesky draft sync")
  func circleDraftsNeverSync() async throws {
    let saved = CircleDraftDestination(circle: CircleTestFixtures.family, accountDID: account, reply: nil)
    #expect(DraftSyncTranslator.isSyncable(makeDraft("Public")))
    #expect(!DraftSyncTranslator.isSyncable(makeDraft("Secret circle text", destination: saved)))

    let store = DraftPersistence(modelContainer: try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    ))
    let publicID = try store.saveDraft(makeDraft("Public"), accountDID: account)
    let circleID = try store.saveDraft(makeDraft("Secret circle text", destination: saved), accountDID: account)
    let network = RecordingDraftTransport()
    let service = DraftSyncService(
      persistence: store, clientProvider: { nil }, accountProvider: { [account] in account },
      enabledProvider: { true }, transportProvider: { _ in network }
    )

    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "create"])
    #expect(try store.fetchDraftModel(id: publicID)?.remoteId != nil)
    let circleRow = try #require(try store.fetchDraftModel(id: circleID))
    #expect(circleRow.remoteId == nil)
    #expect(try store.syncState(for: circleRow).issue == nil)
    #expect(service.lastIssue == nil)

    // A synced draft moved into a Circle keeps its edits here and never updates the remote copy.
    try await store.updateDraft(id: publicID, draft: makeDraft("Now private", destination: saved), accountDID: account)
    await service.syncDrafts(accountDID: account)
    #expect(!network.operations.contains("update"))
    #expect(network.operations.filter { $0 == "create" }.count == 1)
    #expect(try store.fetchDraftModel(id: publicID)?.decodeDraft().circleDestination == saved)
    #expect(!network.sentPayloads.contains { $0.contains("Secret circle text") || $0.contains("Now private") })
  }

  // MARK: - Helpers

  private func makeAppState(circlesEnabled: Bool = false, allowWrites: Bool = false) async -> AppState {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let appState = AppState(userDID: account, client: client, regulatoryChecker: NoAgeRequirement())
    if allowWrites {
      await appState.ageAccess.refreshRequirements()
      #expect(appState.ageAccess.allows(.generalContent))
    }
    if circlesEnabled {
      appState.circleCapability = .supported
    }
    return appState
  }

  private func savedReply() -> CircleDraftDestination.Reply {
    CircleDraftDestination.Reply(AppBskyFeedPost.ReplyRef(
      root: ComAtprotoRepoStrongRef(
        uri: try! ATProtocolURI(uriString: rootURI), cid: CID.fromDAGCBOR(Data("saved-root".utf8))
      ),
      parent: ComAtprotoRepoStrongRef(
        uri: try! ATProtocolURI(uriString: parentURI), cid: CID.fromDAGCBOR(Data("saved-parent".utf8))
      )
    ))
  }

  private func makeDraft(
    _ text: String, parentURI: String? = nil, destination: CircleDraftDestination? = nil
  ) -> PostComposerDraft {
    var draft = PostComposerDraft(
      postText: text, mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: parentURI, quotedPostURI: nil
    )
    draft.circleDestination = destination
    return draft
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}

private struct NoAgeRequirement: AgeRegulatoryChecking {
  func preflight() async -> PlatformAgeSignal { .none }
  #if canImport(UIKit)
  func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  #endif
}

private actor CallCounter {
  private(set) var count = 0
  func increment() { count += 1 }
}

private final class RecordingDraftTransport: DraftSyncTransport {
  private var records: [DraftRemoteRecord] = []
  private(set) var operations: [String] = []
  private(set) var sentPayloads: [String] = []

  func list(cursor: String?) async throws -> DraftRemotePage {
    operations.append("list")
    return DraftRemotePage(records: records, cursor: nil)
  }

  func create(payload: Data) async throws -> String {
    operations.append("create")
    sentPayloads.append(String(decoding: payload, as: UTF8.self))
    let id = "created-\(records.count)"
    records.append(DraftRemoteRecord(id: id, payload: payload, createdAt: Date(), updatedAt: Date()))
    return id
  }

  func update(id: String, payload: Data) async throws {
    operations.append("update")
    sentPayloads.append(String(decoding: payload, as: UTF8.self))
  }

  func delete(id: String) async throws {
    operations.append("delete")
  }
}
