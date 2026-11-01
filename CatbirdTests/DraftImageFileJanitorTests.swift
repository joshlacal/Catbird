#if os(iOS)
import Foundation
import SwiftData
import Testing
@testable import Catbird

/// DraftImageFileJanitor on its own, in a temporary draft folder with its own stores
/// (DraftPhotoSandbox): which stores keep a draft photo, which files are never candidates, how
/// names are read out of stored bytes, the modification-date window, and what cancels a pass.
@Suite("Draft photo janitor")
@MainActor
struct DraftImageFileJanitorTests {
  enum StoredReference: String, CaseIterable, CustomTestStringConvertible {
    case nothing
    case otherSceneEnvelope
    case legacyMinimizedDraft
    case handoffSlot
    case outboxQueue
    case legacyJSONDraft
    var testDescription: String { rawValue }
  }

  @Test("Each store that can name a draft photo keeps it", arguments: StoredReference.allCases)
  func storesKeepNamedFiles(reference: StoredReference) throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    let named = DraftPhotoSandbox.naming(file)
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
    case .legacyJSONDraft:
      // A draft an earlier version saved as JSON whose migration failed; it can still migrate.
      try FileManager.default.createDirectory(at: sandbox.legacyDrafts, withIntermediateDirectories: true)
      try named.write(to: sandbox.legacyDrafts.appendingPathComponent("\(UUID().uuidString).json"))
    }

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(DraftPhotoSandbox.exists(file) == (reference != .nothing))
    #expect(outcome.removed.isEmpty == (reference != .nothing))
  }

  @Test("A store that cannot be read cancels the pass")
  func unreadableStoreCancels() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    sandbox.recoveryDefaults.set("not data", forKey: SceneComposerEditingSession.legacyRecoveryKey)

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(outcome.cancelled)
    #expect(DraftPhotoSandbox.exists(file))
  }

  @Test("A legacy-drafts folder that cannot be listed cancels the pass")
  func unreadableLegacyDraftsCancels() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    try Data("not a folder".utf8).write(to: sandbox.legacyDrafts)

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(outcome.cancelled)
    #expect(DraftPhotoSandbox.exists(file))
  }

  @Test("A saved draft whose local sync baseline no longer decodes still lets the pass run")
  func undecodableSyncBaselineDoesNotCancel() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let unnamed = try sandbox.managedFile()
    let namedByBaseline = try sandbox.managedFile()
    let namedByRemote = try sandbox.managedFile()
    let persistence = sandbox.persistence
    let id = try persistence.saveDraft(DraftPhotoSandbox.draft(naming: nil), accountDID: "did:plc:draftphotojanitor")
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
    #expect(!DraftPhotoSandbox.exists(unnamed), "the pass ran")
    #expect(DraftPhotoSandbox.exists(namedByBaseline), "the raw metadata names it")
    #expect(DraftPhotoSandbox.exists(namedByRemote), "the decoded remote snapshot names it")
  }

  @Test("Sync metadata that is not JSON still cancels the pass")
  func unreadableSyncMetadataCancels() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    let persistence = sandbox.persistence
    let id = try persistence.saveDraft(DraftPhotoSandbox.draft(naming: nil), accountDID: "did:plc:draftphotojanitor")
    try #require(try persistence.fetchDraftModel(id: id)).syncMetadata = Data("not sync metadata".utf8)

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(outcome.cancelled)
    #expect(DraftPhotoSandbox.exists(file))
  }

  @Test("A deleted saved draft names nothing unless its Bluesky create is unconfirmed", arguments: [false, true])
  func tombstonesNameNothing(createUnconfirmed: Bool) throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let file = try sandbox.managedFile()
    let persistence = sandbox.persistence
    let id = try persistence.saveDraft(DraftPhotoSandbox.draft(naming: file), accountDID: "did:plc:draftphotojanitor")
    try persistence.markDeleted(id: id, accountDID: "did:plc:draftphotojanitor")
    if createUnconfirmed {
      let model = try #require(try persistence.fetchDraftModel(id: id))
      var state = try persistence.syncState(for: model)
      state.pendingCreate = Data(#"{"posts":[]}"#.utf8)
      try persistence.saveSyncState(state, for: model)
    }

    let outcome = sandbox.janitor().removeUnreferenced([file.absoluteString])

    #expect(!outcome.cancelled)
    #expect(DraftPhotoSandbox.exists(file) == createUnconfirmed)
  }

  @Test("A file is removed only while its modification date, read right before, is in the window")
  func eligibleDatesRecheckedBeforeUnlink() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let now = Date()
    let file = try sandbox.managedFile(modifiedAt: now)
    let window = Date.distantPast..<now.addingTimeInterval(-3_600)

    let recent = sandbox.janitor().removeUnreferenced([file.absoluteString], eligibleModificationDates: window)
    #expect(recent.skippedByDate == [file.absoluteString])
    #expect(recent.removed.isEmpty)
    #expect(DraftPhotoSandbox.exists(file))

    try DraftPhotoSandbox.setModified(file, to: now.addingTimeInterval(-8 * 86_400))
    let old = sandbox.janitor().removeUnreferenced([file.absoluteString], eligibleModificationDates: window)
    #expect(old.removed == [file.absoluteString])
    #expect(old.removedBytes == 4)
    #expect(!DraftPhotoSandbox.exists(file))
  }

  @Test("Videos, unmanaged names and files outside the draft folder are never touched")
  func unmanagedFilesAreIgnored() throws {
    let sandbox = try DraftPhotoSandbox()
    defer { sandbox.remove() }
    let elsewhere = sandbox.root.appendingPathComponent("Elsewhere", isDirectory: true)
    let hex = DraftPhotoSandbox.randomHex
    let untouched = [
      try sandbox.file(named: "\(UUID().uuidString).mov"),
      try sandbox.file(named: "\(UUID().uuidString).jpg"),
      try sandbox.file(named: "draft_video_\(hex()).mov"),
      try sandbox.file(named: "draft_image_\(hex()).png"),
      try sandbox.file(named: "draft_image_\(hex().uppercased()).jpg"),
      try sandbox.file(named: "draft_image_\(hex()).jpg", in: elsewhere)
    ]
    let managed = try sandbox.managedFile()

    let outcome = sandbox.janitor().removeUnreferenced(Set(untouched.map(\.absoluteString) + [managed.absoluteString]))

    #expect(untouched.allSatisfy(DraftPhotoSandbox.exists))
    #expect(outcome.ignored == Set(untouched.map(\.absoluteString)))
    #expect(!DraftPhotoSandbox.exists(managed), "control: an unreferenced managed file is removed")
  }

  @Test("Only content-hash photo names are managed")
  func managedNames() {
    let hex = DraftPhotoSandbox.randomHex
    #expect(DraftImageFileJanitor.isManagedFileName("draft_image_\(hex()).jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_\(hex().dropLast()).jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_\(hex())x.jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("draft_image_abc.jpg"))
    #expect(!DraftImageFileJanitor.isManagedFileName("\(UUID().uuidString).jpg"))
  }

  @Test("Managed names are read out of stored bytes in every form a store keeps them")
  func managedNameExtraction() {
    let first = "draft_image_\(DraftPhotoSandbox.randomHex()).jpg"
    let second = "draft_image_\(DraftPhotoSandbox.randomHex()).jpg"
    let hex = DraftPhotoSandbox.randomHex()
    let names = DraftImageFileJanitor.managedFileNames(in:)

    let escaped = Data(#"{"rawImageURLString":"file:\/\/\/private\/var\/SharedDrafts\/\#(first)"}"#.utf8)
    #expect(names(escaped) == [first], "JSON with escaped slashes")
    #expect(names(Data((first + second).utf8)) == [first, second], "two names back to back")
    #expect(names(Data(("draft_image_" + first).utf8)) == [first], "a prefix that is not followed by a digest")
    let buffer = Data(("padding draft_image_ " + first + " trailer").utf8)
    let slice = buffer[buffer.startIndex.advanced(by: 3)..<buffer.endIndex.advanced(by: -2)]
    #expect(slice.startIndex != 0, "fixture: a slice of a larger buffer")
    #expect(names(slice) == [first], "a slice keeps its parent's indices")

    #expect(names(Data("draft_image_\(hex.uppercased()).jpg".utf8)).isEmpty, "uppercase digest")
    #expect(names(Data("draft_image_\(hex.dropLast()).jpg".utf8)).isEmpty, "63 hex characters")
    #expect(names(Data("draft_image_\(hex)a.jpg".utf8)).isEmpty, "a 65th hex character before .jpg")
    #expect(names(Data(String(first.dropLast(2)).utf8)).isEmpty, "a name cut off at the end of the bytes")
    #expect(names(Data()).isEmpty)
  }
}
#endif
