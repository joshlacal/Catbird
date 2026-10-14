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

private func randomHex() -> String {
  (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}
#endif
