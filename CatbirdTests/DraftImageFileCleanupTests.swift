#if os(iOS)
import CryptoKit
import Foundation
import Petrel
import SwiftData
import Testing
import UIKit
@testable import Catbird

/// Composer photos are copied into the App Group's SharedDrafts folder as
/// draft_image_<sha256>.jpg. Discarding a composition that never became a saved draft removes the
/// files it created, unless a saved draft of any account, a recovery envelope, the handoff slot,
/// the outbox, an open editor or a pending account handoff still names them. Nothing else is
/// ever removed: files that were already there and saved drafts' media are kept here, and
/// DraftImageFileJanitorTests covers each store, unmanaged names and videos on their own.
///
/// These run against the real App Group folder. Every photo has random pixels, so its
/// content-named file belongs to that test alone.
@Suite("Draft photo file cleanup", .serialized)
@MainActor
struct DraftImageFileCleanupTests {
  // MARK: Discarding an unsaved composition

  @Test("Discarding an unsaved composition removes exactly the photo files it wrote")
  func discardRemovesCreatedFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let bystander = try fixture.writeLeftoverFile()
    defer { removeIfPresent(bystander) }
    let editor = try fixture.newEditor()
    let first = try uniquePhoto(), second = try uniquePhoto()

    await fixture.pick(first, into: editor)
    await fixture.pick(second, into: editor)
    #expect(exists(draftFile(for: first)) && exists(draftFile(for: second)), "fixture: picking writes draft files")

    #expect(editor.discardEditingDraft())

    #expect(!exists(draftFile(for: first)))
    #expect(!exists(draftFile(for: second)))
    #expect(exists(bystander), "a file the composition did not write is never removed")
  }

  @Test("Removing a photo keeps its file until the composition is discarded")
  func removedPhotoIsCleanedAtDiscard() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = try fixture.newEditor()
    let removed = try uniquePhoto(), kept = try uniquePhoto()
    let removedID = await fixture.pick(removed, into: editor)
    await fixture.pick(kept, into: editor)

    editor.removeMediaItem(withId: removedID)
    #expect(exists(draftFile(for: removed)), "removing an attachment never unlinks its file")

    #expect(editor.discardEditingDraft())
    #expect(!exists(draftFile(for: removed)))
    #expect(!exists(draftFile(for: kept)))
  }

  @Test("A photo whose file was already on disk keeps it, even when nothing names it")
  func preexistingFileIsKept() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let leftover = try #require(CodableMediaItem.persistImageData(photo).flatMap(URL.init(string:)))
    defer { removeIfPresent(leftover) }
    let editor = try fixture.newEditor()

    await fixture.pick(photo, into: editor)
    #expect(editor.discardEditingDraft())

    #expect(exists(leftover))
  }

  // MARK: Saved drafts

  @Test("Saving a draft keeps its photos, and discarding it after a restore removes nothing")
  func savedDraftFilesSurvive() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let saved = try uniquePhoto(), addedLater = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: saved)); removeIfPresent(draftFile(for: addedLater)) }

    let author = try fixture.newEditor()
    await fixture.pick(saved, into: author)
    let snapshot = try #require(author.captureEditingSnapshot())
    let rowID = try #require(author.editingSession).stash(snapshot)
    author.clearAll()
    #expect(exists(draftFile(for: saved)))

    let row = try #require(try fixture.persistence.fetchDraftModel(id: rowID))
    let reopened = PostComposerViewModel(appState: fixture.state, editingSession: fixture.session())
    try reopened.restoreSavedDraft(DraftPostViewModel(draftPost: row))
    await fixture.pick(addedLater, into: reopened)
    #expect(reopened.discardEditingDraft())

    #expect(try fixture.persistence.syncState(for: row).deletedAt != nil, "fixture: the row is tombstoned")
    #expect(exists(draftFile(for: saved)), "a saved draft's media waits for its row's deletion")
    #expect(exists(draftFile(for: addedLater)), "a restored composition removes nothing")
  }

  enum SavedReference: String, CaseIterable, CustomTestStringConvertible {
    case otherAccountRow
    case tombstonedRow
    case remoteSnapshotInSyncMetadata
    var testDescription: String { rawValue }
  }

  @Test("A photo file a saved draft shares by content survives discard", arguments: SavedReference.allCases)
  func sharedWithSavedDraftSurvives(reference: SavedReference) async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)

    switch reference {
    case .otherAccountRow:
      _ = try fixture.persistence.saveDraft(draft(naming: file), accountDID: "did:plc:someoneelse")
    case .tombstonedRow:
      let id = try fixture.persistence.saveDraft(draft(naming: file), accountDID: fixture.accountDID)
      try fixture.persistence.markDeleted(id: id, accountDID: fixture.accountDID)
    case .remoteSnapshotInSyncMetadata:
      let id = try fixture.persistence.saveDraft(draft(naming: nil), accountDID: fixture.accountDID)
      let model = try #require(try fixture.persistence.fetchDraftModel(id: id))
      let remote = Data(#"{"posts":[{"embedImages":[{"localRef":{"path":"\#(file.absoluteString)"}}]}]}"#.utf8)
      try fixture.persistence.saveSyncState(DraftSyncState(baselineRemote: remote), for: model)
    }

    #expect(editor.discardEditingDraft())
    #expect(exists(file))
  }

  // MARK: Live holders

  @Test("An open composition in another scene keeps a photo it shares")
  func otherSceneEditorKeepsSharedFile() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let first = try fixture.newEditor(), second = try fixture.newEditor()
    await fixture.pick(photo, into: first)
    await fixture.pick(photo, into: second)

    #expect(first.discardEditingDraft())
    #expect(exists(file))
    // The second composition did not create the file, so its own discard keeps it as well.
    #expect(second.discardEditingDraft())
    #expect(exists(file))
  }

  @Test("A pending account handoff keeps a photo it names")
  func pendingHandoffKeepsSharedFile() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)
    let queue = ComposerAccountSwitchQueue()
    let handoff = ComposerEditingSnapshot(
      claim: ComposerDraftClaim(sceneID: UUID(), accountDID: fixture.accountDID, token: UUID()),
      revision: 1, draft: draft(naming: file), savedDraftID: nil
    )
    guard case .accepted = queue.begin(
      to: "did:plc:handofftarget", transfer: handoff,
      authenticatedAccountDID: fixture.accountDID, isTransitioning: false
    ) else {
      Issue.record("fixture: the handoff was not admitted")
      return
    }

    #expect(editor.discardEditingDraft())
    #expect(exists(file))
    withExtendedLifetime(queue) {}
  }

  @Test("A cleanup that runs in a cancelled task still sees open editors")
  func cancelledCleanupSeesOpenEditors() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let writer = try fixture.newEditor(), holder = try fixture.newEditor()
    let write = try #require(CodableMediaItem.writeImageData(photo))
    #expect(write.created)
    var item = PostComposerViewModel.MediaItem()
    item.rawData = photo
    holder.mediaItems.append(item)
    // Loaded but not saved yet: only the editor's memory names the file.
    await holder.loadImageForItem(withId: item.id)

    // A cancelled load task drops its result the same way.
    await Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      writer.releaseUnusedDraftImageFile(write)
    }.value

    #expect(exists(file))
  }

  @Test("An unreadable saved draft cancels the cleanup")
  func unreadableRowCancelsCleanup() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let id = try fixture.persistence.saveDraft(draft(naming: nil), accountDID: fixture.accountDID)
    let model = try #require(try fixture.persistence.fetchDraftModel(id: id))
    model.syncMetadata = Data("not sync metadata".utf8)
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)

    #expect(editor.discardEditingDraft())
    #expect(exists(file))
  }

  // MARK: Work that outlives its composition

  @Test("A photo written after its composition ended is removed unless something names it", arguments: [false, true])
  func lateWriteAfterDiscard(namedBySavedDraft: Bool) async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = try fixture.newEditor()
    let staleClaim = try #require(editor.editingClaim)
    #expect(editor.discardEditingDraft())

    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    if namedBySavedDraft {
      _ = try fixture.persistence.saveDraft(draft(naming: file), accountDID: fixture.accountDID)
    }
    // What loadImageForItem and finishImageEdit hand over when their load finishes late.
    let write = try #require(CodableMediaItem.writeImageData(photo))
    #expect(write.created)
    editor.rememberDraftImageFile(write, for: UUID(), data: photo, claim: staleClaim)

    #expect(exists(file) == namedBySavedDraft)
  }

  @Test("A photo written for an attachment that was then dropped is removed now")
  func droppedWriteIsRemoved() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = try fixture.newEditor()
    let photo = try uniquePhoto()
    let write = try #require(CodableMediaItem.writeImageData(photo))
    let url = try #require(URL(string: write.urlString))
    defer { removeIfPresent(url) }

    editor.releaseUnusedDraftImageFile(DraftImageWrite(urlString: write.urlString, created: false))
    #expect(exists(url), "a write that found the file already there owns nothing")
    editor.releaseUnusedDraftImageFile(write)
    #expect(!exists(url))
  }
}

// MARK: - Helpers

@MainActor
private struct Fixture {
  let accountDID = "did:plc:draftphotocleanup"
  let state: AppState
  let container: ModelContainer
  let suiteName: String
  let defaults: UserDefaults
  let manager: ComposerDraftManager
  let persistence: DraftPersistence

  init() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    state = AppState(userDID: accountDID, client: client)
    suiteName = "blue.catbird.tests.draft-photo-cleanup.\(UUID().uuidString)"
    defaults = try #require(UserDefaults(suiteName: suiteName))
    container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    persistence = DraftPersistence(modelContext: container.mainContext)
    manager = ComposerDraftManager(accountDID: accountDID, modelContext: container.mainContext, defaults: defaults)
  }

  func session() -> SceneComposerEditingSession {
    SceneComposerEditingSession(
      manager: manager, accountDID: accountDID, sceneID: UUID(), defaults: defaults,
      persistDelay: .seconds(60)
    )
  }

  /// A new, unsaved composition in its own scene.
  func newEditor() throws -> PostComposerViewModel {
    let editor = PostComposerViewModel(appState: state, editingSession: session())
    try editor.startEditing()
    return editor
  }

  /// What the picker does: append a placeholder holding the bytes, then load it in place.
  @discardableResult
  func pick(_ photo: Data, into editor: PostComposerViewModel) async -> UUID {
    var item = PostComposerViewModel.MediaItem()
    item.rawData = photo
    editor.mediaItems.append(item)
    await editor.loadImageForItem(withId: item.id)
    editor.saveDraftIfNeeded()
    return item.id
  }

  /// A managed draft photo left by something else.
  func writeLeftoverFile() throws -> URL {
    try #require(CodableMediaItem.persistImageData(uniquePhoto()).flatMap(URL.init(string:)))
  }

  func cleanUp() {
    defaults.removePersistentDomain(forName: suiteName)
  }
}

/// A JPEG of random pixels, so its content-named draft file is unique to the calling test.
private func uniquePhoto() throws -> Data {
  let format = UIGraphicsImageRendererFormat()
  format.scale = 1
  let size = CGSize(width: 32, height: 24)
  let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
    for row in 0..<6 {
      for column in 0..<8 {
        UIColor(
          red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1
        ).setFill()
        context.fill(CGRect(x: column * 4, y: row * 4, width: 4, height: 4))
      }
    }
  }
  return try #require(image.jpegData(compressionQuality: 0.9))
}

/// Where CodableMediaItem.writeImageData puts `photo`.
private func draftFile(for photo: Data) -> URL {
  let digest = SHA256.hash(data: photo).map { String(format: "%02x", $0) }.joined()
  return CodableMediaItem.draftImagesDirectory!.appendingPathComponent("draft_image_\(digest).jpg")
}

/// A saved draft whose one photo is `file`, or a text-only draft.
private func draft(naming file: URL?) -> PostComposerDraft {
  let media = file.map {
    [CodableMediaItem(
      altText: "", aspectRatio: nil, isLoading: false, isAudioVisualizerVideo: false,
      rawVideoURLString: nil, rawImageURLString: $0.absoluteString
    )]
  } ?? []
  return PostComposerDraft(
    postText: "Draft photo cleanup", mediaItems: media, videoItem: nil, selectedGif: nil,
    selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
    isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
  )
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

private func removeIfPresent(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}
#endif
