import Foundation
import SwiftData
import Testing
@testable import Catbird
import Petrel

@Suite("Saved draft reconciliation", .serialized)
@MainActor
struct DraftSyncReconciliationTests {
  private let account = "did:plc:draft-owner"

  private func draft(_ text: String) -> PostComposerDraft {
    PostComposerDraft(
      postText: text, mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
    )
  }

  private func store() throws -> DraftPersistence {
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    return DraftPersistence(modelContainer: try ModelContainer(for: DraftPost.self, configurations: config))
  }

  private func remote(_ id: String, text: String) throws -> DraftRemoteRecord {
    let payload = try DraftWireEnvelope.encode(DraftSyncTranslator.remoteDraft(
      from: draft(text), deviceId: "other-app", deviceName: "Bluesky"
    ))
    return DraftRemoteRecord(id: id, payload: payload, createdAt: .distantPast, updatedAt: Date())
  }

  private func service(_ store: DraftPersistence, transport: MockDraftTransport, account: @escaping @MainActor () -> String?) -> DraftSyncService {
    DraftSyncService(persistence: store, clientProvider: { nil }, accountProvider: account,
                     enabledProvider: { true }, transportProvider: { _ in transport })
  }

  @Test("A failed initial pull never uploads or changes legacy local drafts")
  func failedPullPreservesLegacyDraft() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Keep me"), accountDID: account)
    let network = MockDraftTransport()
    network.failList = true
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list"])
    #expect(try store.fetchDraftModel(id: id)?.decodeDraft().postText == "Keep me")
    #expect(try store.fetchDraftModel(id: id)?.remoteId == nil)
    #expect(service.lastIssue != nil)
  }

  @Test("Complete pagination precedes any local upload, including more than 500 drafts")
  func paginationBeforeUpload() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Local"), accountDID: account)
    let network = MockDraftTransport()
    network.pages = try (0..<6).map { page in
      DraftRemotePage(records: try (0..<100).map { try remote("\(page)-\($0)", text: "Remote \(page)-\($0)") }, cursor: "page-\(page)")
    } + [DraftRemotePage(records: [], cursor: nil)]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations.prefix(7).allSatisfy { $0 == "list" })
    #expect(network.operations.last == "create")
    #expect(try store.fetchDrafts(for: account).count == 601)
  }

  @Test("A cursor cycle does not reconcile a partial list")
  func cursorCycleDoesNotDeleteOrPush() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Local"), accountDID: account)
    let network = MockDraftTransport()
    network.pages = [
      DraftRemotePage(records: [try remote("remote", text: "First")], cursor: "same"),
      DraftRemotePage(records: [try remote("remote", text: "First")], cursor: "same")
    ]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "list"])
    #expect(try store.fetchDrafts(for: account).map(\.id) == [id])
  }

  @Test("A remote deletion retains an offline copy without recreating it")
  func missingRemoteKeepsRecoveryCopy() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Original")]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    network.records = []
    network.operations = []
    await service.syncDrafts(accountDID: account)
    let local = try #require(store.fetchDrafts(for: account).first)
    #expect(try local.decodeDraft().postText == "Original")
    #expect(try store.syncState(for: local).recoveryReason != nil)
    #expect(network.operations == ["list"])
    await service.syncDrafts(accountDID: account)
    #expect(!network.operations.contains("create"))
  }

  @Test("A failed deletion persists a tombstone across service restart and cannot resurrect")
  func failedDeletionSurvivesRestart() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Delete me")]
    let first = service(store, transport: network, account: { account })
    await first.syncDrafts(accountDID: account)
    let local = try #require(store.fetchDrafts(for: account).first)
    try store.markDeleted(id: local.id, accountDID: account)
    network.failDelete = true
    await first.syncDrafts(accountDID: account)
    #expect(try store.fetchDrafts(for: account).isEmpty)
    #expect(try store.allDrafts(for: account).count == 1)
    let restarted = service(store, transport: network, account: { account })
    network.failDelete = false
    await restarted.syncDrafts(accountDID: account)
    #expect(network.records.isEmpty)
    #expect(try store.fetchDrafts(for: account).isEmpty)
  }

  @Test("Concurrent edits preserve the local version and apply the remote version")
  func conflictingEditsKeepBothVersions() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Original")]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let local = try #require(store.fetchDrafts(for: account).first)
    try await store.updateDraft(id: local.id, draft: draft("Local edit"), accountDID: account)
    network.records = [try remote("remote", text: "Remote edit")]
    network.operations = []
    await service.syncDrafts(accountDID: account)
    let results = try store.fetchDrafts(for: account)
    #expect(Set(try results.map { try $0.decodeDraft().postText }) == ["Local edit", "Remote edit"])
    #expect(network.operations == ["list"])
    #expect(try results.filter { try store.syncState(for: $0).recoveryReason != nil }.count == 1)
  }

  @Test("A local edit made during update is not falsely marked synced")
  func newerLocalEditSurvivesRequest() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Original")]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let local = try #require(store.fetchDrafts(for: account).first)
    let first = DraftSyncTranslator.localDraft(from: try network.records[0].draft, includeLocalMedia: false)
    var edit = first
    // Construct a text edit with the same interaction metadata as the import.
    edit = replacingText(first, text: "First edit")
    try await store.updateDraft(id: local.id, draft: edit, accountDID: account)
    network.onUpdate = {
      try await store.updateDraft(id: local.id, draft: replacingText(first, text: "Newer edit"), accountDID: account)
    }
    await service.syncDrafts(accountDID: account)
    #expect(try local.decodeDraft().postText == "Newer edit")
    #expect(try store.syncState(for: local).baselineLocal?.postText == "First edit")
    #expect(!DraftPostViewModel(draftPost: local).isSynced)
  }

  @Test("Account switch during pull prevents writes and importing another account’s drafts")
  func accountSwitchDuringPull() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Owner draft"), accountDID: account)
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Owner remote")]
    var active: String? = account
    network.onList = { active = "did:plc:other" }
    let service = service(store, transport: network, account: { active })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list"])
    #expect(try store.fetchDrafts(for: account).count == 1)
    #expect(try store.fetchDrafts(for: "did:plc:other").isEmpty)
  }

  @Test("Persistence refuses cross-account updates and deletions")
  func persistenceAccountIsolation() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Owner"), accountDID: account)
    await #expect(throws: DraftError.self) {
      try await store.updateDraft(id: id, draft: draft("Wrong"), accountDID: "did:plc:other")
    }
    #expect(throws: DraftError.self) { try store.markDeleted(id: id, accountDID: "did:plc:other") }
    #expect(try store.fetchDraftModel(id: id)?.decodeDraft().postText == "Owner")
  }

  @Test("An ambiguous create is matched on next pull without a duplicate upload")
  func ambiguousCreateRecoversIdentity() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Create once"), accountDID: account)
    let network = MockDraftTransport()
    network.loseCreateResponse = true
    let first = service(store, transport: network, account: { account })
    await first.syncDrafts(accountDID: account)
    let local = try #require(try store.fetchDraftModel(id: id))
    #expect(try store.syncState(for: local).pendingCreate != nil)
    #expect(local.remoteId == nil)
    let restarted = service(store, transport: network, account: { account })
    await restarted.syncDrafts(accountDID: account)
    #expect(local.remoteId == "created")
    #expect(network.operations.filter { $0 == "create" }.count == 1)
    #expect(try store.fetchDrafts(for: account).count == 1)
  }

  @Test("An unconfirmed create is not retried blindly")
  func ambiguousCreateWithoutVisibleResultStaysLocal() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Create once"), accountDID: account)
    let network = MockDraftTransport()
    network.failCreate = true
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    await service.syncDrafts(accountDID: account)
    #expect(network.operations.filter { $0 == "create" }.count == 1)
    let local = try #require(store.fetchDrafts(for: account).first)
    #expect(try store.syncState(for: local).issue != nil)
  }

  @Test("Delete during create retains the returned remote identity for deletion")
  func deleteDuringCreate() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Soon deleted"), accountDID: account)
    let network = MockDraftTransport()
    network.onCreate = { try store.markDeleted(id: id, accountDID: account) }
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "create", "list", "delete"])
    #expect(try store.fetchDrafts(for: account).isEmpty)
    #expect(network.records.isEmpty)
  }

  @Test("Raw envelope edits preserve unknown fields, media, quote CID and interaction rules")
  func rawEnvelopePreservesUnrepresentedFields() throws {
    let original = Data(#"{"deviceId":"other","future":{"enabled":true},"posts":[{"text":"Before","futurePost":42,"embedImages":[{"localRef":{"path":"opaque"},"futureMedia":true}],"embedRecords":[{"record":{"uri":"at://did:plc:author/app.bsky.feed.post/3k4duaz5vfs2b","cid":"bafyreia6lqbkx5cocvtf4pbbmbfyosfwf54izqgiqbbiudqlhjcxkhbxie"}}]}],"threadgateAllow":[],"postgateEmbeddingRules":[{"$type":"future.rule"}]}"#.utf8)
    let before = Data(#"{"deviceId":"catbird","posts":[{"text":"Before"}]}"#.utf8)
    let after = Data(#"{"deviceId":"catbird","posts":[{"text":"After"}]}"#.utf8)
    let changed = try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after)
    let expected = Data(String(decoding: original, as: UTF8.self).replacingOccurrences(of: "Before", with: "After").utf8)
    #expect(try changed == DraftWireEnvelope.canonical(expected))
  }

  @Test("Unknown metadata remains untouched when a draft is unchanged")
  func unchangedEnvelopeIsExact() throws {
    let raw = Data(#"{"posts":[{"text":"Draft","future":[1,2,3]}],"newField":null}"#.utf8)
    let projection = Data(#"{"posts":[{"text":"Draft"}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: raw, before: projection, after: projection) == DraftWireEnvelope.canonical(raw))
  }

  @Test("Empty advancing pages are followed before reconciliation")
  func emptyIntermediatePageIsNotTerminal() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Local"), accountDID: account)
    let network = MockDraftTransport()
    network.pages = [
      DraftRemotePage(records: [], cursor: "next"),
      DraftRemotePage(records: [try remote("later", text: "Later page")], cursor: nil)
    ]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "list", "create"])
    #expect(try store.fetchDrafts(for: account).count == 2)
  }

  @Test("Empty page cursor cycle is incomplete, so no upload occurs")
  func emptyPageCycleAborts() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Local"), accountDID: account)
    let network = MockDraftTransport()
    network.pages = [DraftRemotePage(records: [], cursor: "same"), DraftRemotePage(records: [], cursor: "same")]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "list"])
    #expect(service.lastIssue != nil)
  }

  @Test("An acknowledged tombstone does not block an unrelated draft on the next sync")
  func acknowledgedDeletionDoesNotBlockFutureSync() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("deleted", text: "Old")]
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let old = try #require(store.fetchDrafts(for: account).first)
    try store.markDeleted(id: old.id, accountDID: account)
    await service.syncDrafts(accountDID: account)
    network.failDelete = true
    network.operations = []
    _ = try store.saveDraft(draft("New"), accountDID: account)
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list", "create"])
    #expect(try store.fetchDrafts(for: account).count == 1)
  }

  @Test("Posts carry unknown metadata through a same-count reorder using stable entry identity")
  func reorderedPostEnvelopesFollowTheirEntries() throws {
    let original = Data(#"{"posts":[{"text":"A","future":"Ameta"},{"text":"B","future":"Bmeta"}]}"#.utf8)
    let before = Data(#"{"posts":[{"text":"A"},{"text":"B"}]}"#.utf8)
    let after = Data(#"{"posts":[{"text":"B edited"},{"text":"A"}]}"#.utf8)
    let expected = Data(#"{"posts":[{"text":"B edited","future":"Bmeta"},{"text":"A","future":"Ameta"}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after, postOrder: [1, 0]) == DraftWireEnvelope.canonical(expected))
  }

  @Test("Cancelled old-account work cannot apply after switching back to that account")
  func accountABARejectsOldPass() async throws {
    let store = try store()
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Original")]
    let service = service(store, transport: network, account: { account })
    network.onList = { service.cancelPendingWork() }
    await service.syncDrafts(accountDID: account)
    #expect(try store.fetchDrafts(for: account).isEmpty)
    #expect(network.operations == ["list"])
  }

  @Test("Definitive rejected creates remain retryable")
  func rejectedCreateCanRetry() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Retry"), accountDID: account)
    let network = MockDraftTransport()
    network.createRejection = 400
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let local = try #require(try store.fetchDraftModel(id: id))
    #expect(try store.syncState(for: local).pendingCreate == nil)
    network.createRejection = nil
    await service.syncDrafts(accountDID: account)
    #expect(try store.fetchDraftModel(id: id)?.remoteId == "created")
  }

  @Test("Legacy saved drafts snapshot restricted account interaction defaults before upload")
  func legacyDraftRetainsAccountDefaultRestrictions() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Legacy"), accountDID: account)
    let network = MockDraftTransport()
    network.preferences = .init(threadgateAllowRules: [], postgateEmbeddingRules: [.appBskyFeedPostgateDisableRule(.init())])
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let remote = try #require(network.records.first)
    #expect(try remote.draft.threadgateAllow?.isEmpty == true)
    #expect(try remote.draft.postgateEmbeddingRules?.count == 1)
    #expect(try store.fetchDraftModel(id: id)?.decodeDraft().hasDraftInteractionSettings == true)
  }

  @Test("Media in another app or missing local files is not treated as restorable")
  func localMediaRequiresSameInstallAndExistingManagedFile() {
    let draft = AppBskyDraftDefs.Draft(deviceId: DraftSyncService.deviceId, posts: [
      .init(text: "Image", embedImages: [.init(localRef: .init(path: "file:///etc/passwd"))])
    ])
    #expect(!DraftSyncService.canRestoreMedia(draft))
    let other = AppBskyDraftDefs.Draft(deviceId: "another-app", posts: [.init(text: "Other")])
    #expect(!DraftSyncService.canRestoreMedia(other))
  }

  @Test("Deleting an unconfirmed duplicate never adopts or deletes another saved draft’s identity")
  func pendingDuplicateCannotDeleteExistingRemote() async throws {
    let store = try store()
    let firstID = try store.saveDraft(draft("Identical"), accountDID: account)
    let network = MockDraftTransport()
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    let original = try #require(network.records.first)
    let secondID = try store.saveDraft(draft("Identical"), accountDID: account)
    network.failCreate = true
    await service.syncDrafts(accountDID: account)
    try store.markDeleted(id: secondID, accountDID: account)
    network.operations = []
    await service.syncDrafts(accountDID: account)
    #expect(network.operations == ["list"])
    #expect(network.records.map(\.id) == [original.id])
    #expect(try store.fetchDraftModel(id: firstID)?.remoteId == original.id)
    #expect(try store.fetchDraftModel(id: secondID)?.remoteId == nil)
  }

  @Test("Downloaded drafts remain available even when uploading an existing local draft fails")
  func importPrecedesFailedUpload() async throws {
    let store = try store()
    _ = try store.saveDraft(draft("Local"), accountDID: account)
    let network = MockDraftTransport()
    network.records = [try remote("remote", text: "Already on Bluesky")]
    network.failCreate = true
    let service = service(store, transport: network, account: { account })
    await service.syncDrafts(accountDID: account)
    #expect(Set(try store.fetchDrafts(for: account).map { try $0.decodeDraft().postText }) == ["Local", "Already on Bluesky"])
  }

  @Test("Removing a legacy image removes both upstream image aliases")
  func legacyImageRemovalDoesNotResurrectImage() throws {
    let original = Data(#"{"posts":[{"text":"Image","embedImages":[{"localRef":{"path":"local.jpg"},"alt":"Old","future":"keep"}]}]}"#.utf8)
    let before = Data(#"{"posts":[{"text":"Image","embedGallery":{"$type":"app.bsky.draft.defs#draftEmbedGallery","items":[{"$type":"app.bsky.draft.defs#draftEmbedImage","localRef":{"path":"local.jpg"},"alt":"Old"}]}}]}"#.utf8)
    let after = Data(#"{"posts":[{"text":"Image"}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after) == DraftWireEnvelope.canonical(after))
    #expect(try DraftWireEnvelope.applyingChanges(original: original, before: before, after: before) == DraftWireEnvelope.canonical(original))
  }

  @Test("Editing legacy image alt text preserves unknown metadata while normalizing its alias")
  func legacyImageAltEditPreservesUnknownMetadata() throws {
    let original = Data(#"{"posts":[{"text":"Image","embedImages":[{"localRef":{"path":"local.jpg"},"alt":"Old","future":"keep"}]}]}"#.utf8)
    let before = Data(#"{"posts":[{"text":"Image","embedGallery":{"$type":"app.bsky.draft.defs#draftEmbedGallery","items":[{"$type":"app.bsky.draft.defs#draftEmbedImage","localRef":{"path":"local.jpg"},"alt":"Old"}]}}]}"#.utf8)
    let after = Data(String(decoding: before, as: UTF8.self).replacingOccurrences(of: "Old", with: "New").utf8)
    let output = try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after)
    let object = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
    let post = try #require((object["posts"] as? [[String: Any]])?.first)
    #expect(post["embedImages"] == nil)
    let gallery = try #require(post["embedGallery"] as? [String: Any])
    let image = try #require((gallery["items"] as? [[String: Any]])?.first)
    #expect(image["future"] as? String == "keep")
    #expect(image["alt"] as? String == "New")
  }

  @Test("Multiple new equal remote candidates remain unconfirmed and cannot be auto-deleted")
  func ambiguousMultipleMatchesStaySuppressed() async throws {
    let store = try store()
    let id = try store.saveDraft(draft("Identical"), accountDID: account)
    let network = MockDraftTransport()
    network.failCreate = true
    let first = service(store, transport: network, account: { account })
    await first.syncDrafts(accountDID: account)
    let local = try #require(try store.fetchDraftModel(id: id))
    let payload = try #require(store.syncState(for: local).pendingCreate)
    network.records = ["candidate-1", "candidate-2"].map {
      .init(id: $0, payload: payload, createdAt: Date(), updatedAt: Date())
    }
    try store.markDeleted(id: id, accountDID: account)
    network.operations = []
    let restarted = service(store, transport: network, account: { account })
    await restarted.syncDrafts(accountDID: account)
    #expect(local.remoteId == nil)
    #expect(try store.syncState(for: local).pendingCreate != nil)
    #expect(network.operations == ["list"])
    #expect(network.records.count == 2)
    #expect(try store.fetchDrafts(for: account).isEmpty)
    #expect(try store.allDrafts(for: account).count == 1)
  }

  @Test("Surviving images retain only their own unknown metadata when the gallery shrinks")
  func galleryRemovalPreservesSurvivorMetadata() throws {
    let original = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"},"alt":"A","future":"Ameta"},{"localRef":{"path":"b.jpg"},"alt":"B","future":"Bmeta"}]}}]}"#.utf8)
    let before = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"},"alt":"A"},{"localRef":{"path":"b.jpg"},"alt":"B"}]}}]}"#.utf8)
    let after = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"b.jpg"},"alt":"B edited"}]}}]}"#.utf8)
    let expected = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"b.jpg"},"alt":"B edited","future":"Bmeta"}]}}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after) == DraftWireEnvelope.canonical(expected))
  }

  @Test("Replacement and duplicated image references cannot inherit a different image’s metadata")
  func ambiguousOrReplacedMediaDoesNotInheritMetadata() throws {
    let original = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"},"future":"Ameta"},{"localRef":{"path":"a.jpg"},"future":"OtherAmeta"}]}}]}"#.utf8)
    let before = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"}},{"localRef":{"path":"a.jpg"}}]}}]}"#.utf8)
    let after = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"}}]}}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: original, before: before, after: after) == DraftWireEnvelope.canonical(after))
    let singleOriginal = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"a.jpg"},"future":"Ameta"}]}}]}"#.utf8)
    let replacement = Data(#"{"posts":[{"text":"Gallery","embedGallery":{"items":[{"localRef":{"path":"replacement.jpg"}}]}}]}"#.utf8)
    #expect(try DraftWireEnvelope.applyingChanges(original: singleOriginal, before: after, after: replacement) == DraftWireEnvelope.canonical(replacement))
  }

  @Test("Adding local media cannot silently replace a missing same-install remote attachment")
  func missingSameInstallMediaRequiresNewCopy() {
    let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg").absoluteString
    let remote = AppBskyDraftDefs.Draft(deviceId: DraftSyncService.deviceId, posts: [
      .init(text: "Missing media", embedImages: [.init(localRef: .init(path: missingPath))])
    ])
    let baseline = draft("Missing media")
    let edited = PostComposerDraft(
      postText: baseline.postText,
      mediaItems: [.init(altText: "Replacement", aspectRatio: nil, isLoading: false, isAudioVisualizerVideo: false,
                        rawVideoURLString: nil, rawImageURLString: "file:///tmp/replacement.jpg")],
      videoItem: nil, selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
    )
    #expect(DraftSyncService.wouldReplaceUnavailableMedia(remote: remote, baseline: baseline, edited: edited))
    #expect(!DraftSyncService.wouldReplaceUnavailableMedia(remote: remote, baseline: baseline, edited: baseline))
  }

  private func replacingText(_ original: PostComposerDraft, text: String) -> PostComposerDraft {
    PostComposerDraft(
      postText: text, mediaItems: original.mediaItems, videoItem: original.videoItem, selectedGif: original.selectedGif,
      selectedLanguages: original.selectedLanguages, selectedLabels: original.selectedLabels, outlineTags: original.outlineTags,
      threadEntries: original.threadEntries, isThreadMode: original.isThreadMode, currentThreadIndex: original.currentThreadIndex,
      parentPostURI: original.parentPostURI, quotedPostURI: original.quotedPostURI,
      quotedPostCID: original.quotedPostCID, draftPostgateEmbeddingRules: original.draftPostgateEmbeddingRules,
      draftThreadgateAllow: original.draftThreadgateAllow, hasDraftInteractionSettings: original.hasDraftInteractionSettings
    )
  }
}

@MainActor
private final class MockDraftTransport: DraftSyncTransport {
  var records: [DraftRemoteRecord] = []
  var pages: [DraftRemotePage] = []
  var operations: [String] = []
  var failList = false
  var failDelete = false
  var failCreate = false
  var loseCreateResponse = false
  var createRejection: Int?
  var preferences: AppBskyActorDefs.PostInteractionSettingsPref?
  var onList: (() -> Void)?
  var onCreate: (() throws -> Void)?
  var onUpdate: (() async throws -> Void)?

  func list(cursor: String?) async throws -> DraftRemotePage {
    operations.append("list")
    onList?()
    if failList { throw DraftSyncFailure.http(503) }
    if !pages.isEmpty { return pages.removeFirst() }
    return DraftRemotePage(records: records, cursor: nil)
  }

  func interactionDefaults() async throws -> AppBskyActorDefs.PostInteractionSettingsPref? { preferences }

  func create(payload: Data) async throws -> String {
    operations.append("create")
    if let createRejection { throw DraftSyncFailure.http(createRejection) }
    if failCreate { throw URLError(.networkConnectionLost) }
    records.append(.init(id: "created", payload: payload, createdAt: Date(), updatedAt: Date()))
    try onCreate?()
    if loseCreateResponse { throw URLError(.networkConnectionLost) }
    return "created"
  }

  func update(id: String, payload: Data) async throws {
    operations.append("update")
    records = records.map { $0.id == id ? .init(id: id, payload: payload, createdAt: $0.createdAt, updatedAt: Date()) : $0 }
    try await onUpdate?()
  }

  func delete(id: String) async throws {
    operations.append("delete")
    if failDelete { throw DraftSyncFailure.http(503) }
    records.removeAll { $0.id == id }
  }
}
