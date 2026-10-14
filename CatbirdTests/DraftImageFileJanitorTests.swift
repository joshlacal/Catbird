#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import Catbird

/// DraftImageFileJanitor on its own, in a temporary draft folder with its own stores: which stores
/// keep a draft photo, which files are never candidates, and what cancels a pass.
@Suite("Draft photo janitor")
@MainActor
struct DraftImageFileJanitorTests {
  enum StoredReference: String, CaseIterable, CustomTestStringConvertible {
    case nothing
    case otherSceneEnvelope
    case legacyMinimizedDraft
    case handoffSlot
    case outboxQueue
    var testDescription: String { rawValue }
  }

  @Test("Each store that can name a draft photo keeps it", arguments: StoredReference.allCases)
  func storesKeepNamedFiles(reference: StoredReference) throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    let named = Data(#"{"rawImageURLString":"\#(file.absoluteString)"}"#.utf8)
    switch reference {
    case .nothing:
      break
    case .otherSceneEnvelope:
      sandbox.recoveryDefaults.set(
        named, forKey: SceneComposerEditingSession.persistenceKey(sceneID: UUID(), accountDID: "did:plc:other")
      )
    case .legacyMinimizedDraft:
      sandbox.recoveryDefaults.set(named, forKey: SceneComposerEditingSession.legacyRecoveryKey)
    case .handoffSlot:
      sandbox.handoffDefaults.set(named, forKey: ComposeDraftStasher.draftKey)
    case .outboxQueue:
      try named.write(to: sandbox.outboxQueue)
    }

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(exists(file) == (reference != .nothing))
    #expect(outcome.removed.isEmpty == (reference != .nothing))
  }

  @Test("A store that cannot be read cancels the pass")
  func unreadableStoreCancels() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    sandbox.recoveryDefaults.set("not data", forKey: SceneComposerEditingSession.legacyRecoveryKey)

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(outcome.cancelled)
    #expect(exists(file))
  }

  @Test("A saved draft whose local sync baseline no longer decodes still lets the pass run")
  func undecodableSyncBaselineDoesNotCancel() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let unnamed = try sandbox.managedFile()
    let namedByBaseline = try sandbox.managedFile()
    let namedByRemote = try sandbox.managedFile()
    let persistence = DraftPersistence(modelContext: sandbox.container.mainContext)
    let id = try persistence.saveDraft(textOnlyDraft(), accountDID: "did:plc:draftphotojanitor")
    let model = try #require(try persistence.fetchDraftModel(id: id))
    let remote = Data(#"{"posts":[{"embedImages":[{"localRef":{"path":"\#(namedByRemote.absoluteString)"}}]}]}"#.utf8)
    // A local baseline that is no longer a PostComposerDraft (another app version wrote it),
    // still naming a photo, next to a remote snapshot stored as base64.
    model.syncMetadata = Data("""
      {"baselineLocal":{"rawImageURLString":"\(namedByBaseline.absoluteString)"},\
      "baselineRemote":"\(remote.base64EncodedString())"}
      """.utf8)
    #expect(throws: (any Error).self, "fixture: the full sync state no longer decodes") {
      try persistence.syncState(for: model)
    }

    let outcome = sandbox.janitor().removeUnreferenced(
      Set([unnamed, namedByBaseline, namedByRemote].map(\.absoluteString))
    )

    #expect(!outcome.cancelled)
    #expect(!exists(unnamed), "the pass ran")
    #expect(exists(namedByBaseline), "the raw metadata names it")
    #expect(exists(namedByRemote), "the decoded remote snapshot names it")
  }

  @Test("Sync metadata that is not JSON still cancels the pass")
  func unreadableSyncMetadataCancels() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    let persistence = DraftPersistence(modelContext: sandbox.container.mainContext)
    let id = try persistence.saveDraft(textOnlyDraft(), accountDID: "did:plc:draftphotojanitor")
    try #require(try persistence.fetchDraftModel(id: id)).syncMetadata = Data("not sync metadata".utf8)

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(outcome.cancelled)
    #expect(exists(file))
  }

  @Test("Videos, unmanaged names and files outside the draft folder are never touched")
  func unmanagedFilesAreIgnored() throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let elsewhere = FileManager.default.temporaryDirectory
      .appendingPathComponent("DraftImageFileCleanupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let untouched = [
      try sandbox.file(named: "\(UUID().uuidString).mov"),
      try sandbox.file(named: "\(UUID().uuidString).jpg"),
      try sandbox.file(named: "draft_video_\(randomHex()).mov"),
      try sandbox.file(named: "draft_image_\(randomHex()).png"),
      try sandbox.file(named: "draft_image_\(randomHex().uppercased()).jpg"),
      try sandbox.file(named: "draft_image_\(randomHex()).jpg", in: elsewhere)
    ]
    let managed = try sandbox.managedFile()

    let outcome = sandbox.janitor().removeUnreferenced(Set(untouched.map(\.absoluteString) + [managed.absoluteString]))

    #expect(untouched.allSatisfy(exists))
    #expect(outcome.ignored == Set(untouched.map(\.absoluteString)))
    #expect(!exists(managed), "control: an unreferenced managed file is removed")
  }

  @Test("Only content-hash photo names are managed")
  func managedNames() {
    #expect(DraftImageFileJanitor.isManagedFileName("draft_image_\(randomHex()).jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_\(randomHex().dropLast()).jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_\(randomHex())x.jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_abc.jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("\(UUID().uuidString).jpg"))
  }
}

/// A temporary draft folder with its own stores, for the janitor alone.
@MainActor
private struct Sandbox {
  let directory: URL
  let recoveryDefaults: UserDefaults
  let handoffDefaults: UserDefaults
  let outboxQueue: URL
  private let suites: [String]
  let container: ModelContainer

  init() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SharedDrafts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let recoverySuite = "blue.catbird.tests.draft-photo-janitor.recovery.\(UUID().uuidString)"
    let handoffSuite = "blue.catbird.tests.draft-photo-janitor.handoff.\(UUID().uuidString)"
    recoveryDefaults = try #require(UserDefaults(suiteName: recoverySuite))
    handoffDefaults = try #require(UserDefaults(suiteName: handoffSuite))
    suites = [recoverySuite, handoffSuite]
    outboxQueue = directory.deletingLastPathComponent().appendingPathComponent("outbox-\(UUID().uuidString).json")
    container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
  }

  func janitor() -> DraftImageFileJanitor {
    DraftImageFileJanitor.standard(
      persistence: DraftPersistence(modelContext: container.mainContext),
      recoveryDefaults: recoveryDefaults,
      handoffDefaults: handoffDefaults,
      outboxQueueURL: outboxQueue,
      directory: directory
    )
  }

  func managedFile() throws -> URL {
    try file(named: "draft_image_\(randomHex()).jpg")
  }

  func file(named name: String, in folder: URL? = nil) throws -> URL {
    let url = (folder ?? directory).appendingPathComponent(name)
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    return url
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
    try? FileManager.default.removeItem(at: outboxQueue)
    suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
  }
}

private func textOnlyDraft() -> PostComposerDraft {
  PostComposerDraft(
    postText: "Draft photo janitor", mediaItems: [], videoItem: nil, selectedGif: nil,
    selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
    isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
  )
}

private func randomHex() -> String {
  (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}
#endif
