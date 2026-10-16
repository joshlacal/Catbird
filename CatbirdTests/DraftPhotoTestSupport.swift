#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import Catbird

/// A temporary draft photo folder with its own stores, for the janitor and the orphan sweep: a
/// SharedDrafts folder, a quarantine folder, a legacy-drafts folder, recovery and handoff
/// defaults suites, an outbox file and an in-memory saved-draft store. Nothing here reads or
/// touches the host app's folders or defaults.
@MainActor
struct DraftPhotoSandbox {
  let root: URL
  let directory: URL
  let quarantine: URL
  let legacyDrafts: URL
  let outboxQueue: URL
  let recoveryDefaults: UserDefaults
  let handoffDefaults: UserDefaults
  let container: ModelContainer
  private let suites: [String]

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("DraftPhotoSandbox-\(UUID().uuidString)", isDirectory: true)
    directory = root.appendingPathComponent("SharedDrafts", isDirectory: true)
    quarantine = root.appendingPathComponent("quarantine", isDirectory: true)
    legacyDrafts = root.appendingPathComponent("Drafts", isDirectory: true)
    outboxQueue = root.appendingPathComponent("composer_outbox.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let recoverySuite = "blue.catbird.tests.draft-photo-sandbox.recovery.\(UUID().uuidString)"
    let handoffSuite = "blue.catbird.tests.draft-photo-sandbox.handoff.\(UUID().uuidString)"
    recoveryDefaults = try #require(UserDefaults(suiteName: recoverySuite))
    handoffDefaults = try #require(UserDefaults(suiteName: handoffSuite))
    suites = [recoverySuite, handoffSuite]
    container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
  }

  var persistence: DraftPersistence { DraftPersistence(modelContext: container.mainContext) }

  func janitor() -> DraftImageFileJanitor {
    DraftImageFileJanitor.standard(
      persistence: persistence,
      recoveryDefaults: recoveryDefaults,
      handoffDefaults: handoffDefaults,
      outboxQueueURL: outboxQueue,
      legacyDraftsDirectory: legacyDrafts,
      directory: directory
    )
  }

  /// A sweep over this sandbox's folder and stores.
  func sweep(
    storeResetDate: Date? = nil,
    batchSize: Int = DraftImageOrphanSweep.batchSize,
    interruption: @escaping @MainActor () -> DraftImageOrphanSweep.StopReason? = { nil }
  ) -> DraftImageOrphanSweep {
    var sweep = DraftImageOrphanSweep(
      directory: directory, quarantineDirectory: quarantine, storeResetDate: storeResetDate,
      janitor: { janitor() }, interruption: interruption
    )
    sweep.batchSize = batchSize
    return sweep
  }

  /// A managed draft photo, last modified at `date` (now when nil).
  func managedFile(modifiedAt date: Date? = nil) throws -> URL {
    try file(named: "draft_image_\(Self.randomHex()).jpg", modifiedAt: date)
  }

  /// Four bytes at `name` in `folder` (the draft folder when nil), last modified at `date`.
  func file(named name: String, in folder: URL? = nil, modifiedAt date: Date? = nil) throws -> URL {
    let folder = folder ?? directory
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
    if let date { try Self.setModified(url, to: date) }
    return url
  }

  /// A quarantined store's folder, created at `date`.
  @discardableResult
  func quarantinedStore(createdAt date: Date) throws -> URL {
    let url = quarantine.appendingPathComponent("\(UUID().uuidString)_schema_mismatch", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: url.path)
    return url
  }

  /// JSON naming `file` the way a stored draft does.
  static func naming(_ file: URL) -> Data {
    Data(#"{"rawImageURLString":"\#(file.absoluteString)"}"#.utf8)
  }

  /// A saved draft whose one photo is `file`, or a text-only draft.
  static func draft(naming file: URL?) -> PostComposerDraft {
    let media = file.map {
      [CodableMediaItem(
        altText: "", aspectRatio: nil, isLoading: false, isAudioVisualizerVideo: false,
        rawVideoURLString: nil, rawImageURLString: $0.absoluteString
      )]
    } ?? []
    return PostComposerDraft(
      postText: "Draft photo sandbox", mediaItems: media, videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
    )
  }

  static func setModified(_ url: URL, to date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

  static func randomHex() -> String {
    (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
  }

  static func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
    suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
  }
}

/// An object that holds draft media in memory, as an open editor does.
@MainActor
final class DraftPhotoTestHolder: DraftMediaReferenceHolder {
  var heldDraftMediaURLStrings: [String]

  init(_ urls: [URL]) {
    heldDraftMediaURLStrings = urls.map(\.absoluteString)
    LiveDraftMediaReferences.register(self)
  }
}
#endif
