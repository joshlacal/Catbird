#if os(iOS)
import CryptoKit
import Foundation
import Petrel
import SwiftData
import Testing
import UIKit
@testable import Catbird

/// Composer photos are copied into the App Group's SharedDrafts folder as
/// draft_image_<sha256>.jpg. A composition that ends (discarded, posted, saved as a draft, closed
/// as an empty reply, or replaced) removes the files it created, unless a live saved draft of any
/// account, an unconfirmed tombstone, a recovery envelope, the handoff slot, the outbox, a legacy
/// JSON draft, an open editor or a pending account handoff still names them. Files it did not
/// create, a restored row's own photos included, are kept here and left to DraftImageOrphanSweep;
/// DraftImageFileJanitorTests covers each store, unmanaged names and videos on their own.
///
/// These run against the real App Group folder, with the fixture's own handoff slot, outbox and
/// legacy-drafts folder. Every photo has random pixels, so its content-named file belongs to that
/// test alone.
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

  // MARK: Discarding after minimize, from the bubble and from Clear Draft

  @Test("A minimized composition reopened in a new editor removes its photo files on discard")
  func minimizedThenReopenedDiscardRemovesFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let session = fixture.session()
    let first = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try first.startEditing()
    let a = try uniquePhoto(), b = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: a)); removeIfPresent(draftFile(for: b)) }
    await fixture.pick(a, into: first)
    first.removeMediaItem(withId: await fixture.pick(b, into: first))
    #expect(first.minimizeEditingDraft())
    #expect(session.isMinimized)

    // Compose reopens the minimized composition in a new editor (openComposerResumingDraft);
    // the first editor is kept alive to show its stale view does not hold the files.
    let reopened = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try reopened.startEditing(claim: try #require(first.editingClaim))
    #expect(reopened.mediaItems.count == 1, "fixture: the reopened editor shows the kept photo")
    #expect(reopened.discardEditingDraft())

    #expect(!exists(draftFile(for: a)))
    #expect(!exists(draftFile(for: b)), "a photo removed before minimizing is still the composition's")
    withExtendedLifetime(first) {}
  }

  @Test("Dismissing the minimized bubble, or Clear Draft, removes the photo files after the editor is gone")
  func sessionDiscardAfterEditorReleased() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let session = fixture.session()
    let photo = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: photo)) }
    do {
      let editor = PostComposerViewModel(appState: fixture.state, editingSession: session)
      try editor.startEditing()
      await fixture.pick(photo, into: editor)
      #expect(editor.minimizeEditingDraft())
    }

    // TabViewBottomAccessoryWrapper's dismiss button and ContentView's clearDraftAction.
    let claim = try #require(session.activeClaim)
    #expect(session.discard(claim: claim))

    #expect(!exists(draftFile(for: photo)))
  }

  // MARK: Compositions that end empty without Discard

  @Test("Closing an empty reply removes the photo files it picked and removed")
  func emptyReplyCloseRemovesCreatedFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = PostComposerViewModel(appState: fixture.state, editingSession: fixture.session())
    try editor.startEditing(restoring: replyDraft())
    let photo = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: photo)) }
    editor.removeMediaItem(withId: await fixture.pick(photo, into: editor))
    #expect(exists(draftFile(for: photo)), "fixture: removing the photo keeps its file")

    // X on an empty reply, and swiping it away, minimize it; an empty reply then simply ends.
    #expect(editor.minimizeEditingDraft())
    #expect(editor.editingSession?.currentDraft == nil, "fixture: the reply ended")

    #expect(!exists(draftFile(for: photo)))
  }

  @Test("A new composition replacing one too empty to keep removes that one's photo files")
  func emptyReplacedCompositionRemovesCreatedFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let session = fixture.session()
    let swipedAway = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try swipedAway.startEditing()
    let photo = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: photo)) }
    let photoID = await fixture.pick(photo, into: swipedAway)
    // Minimizing and reopening stores the scene's recovery envelope with the photo in it.
    #expect(swipedAway.minimizeEditingDraft())
    #expect(session.resume(claim: try #require(swipedAway.editingClaim)))
    let slot = SceneComposerEditingSession.persistenceKey(sceneID: session.sceneID, accountDID: fixture.accountDID)
    let envelopeWithPhoto = try #require(fixture.defaults.data(forKey: slot))
    #expect(envelopeWithPhoto.range(of: Data(draftFile(for: photo).lastPathComponent.utf8)) != nil,
            "fixture: the scene's envelope names the photo")
    swipedAway.removeMediaItem(withId: photoID)
    // The editor goes away. Its last change reaches the envelope only after the autosave delay,
    // so the slot still holds the body with the photo.
    #expect(swipedAway.unregisterLiveDraftProvider())
    fixture.defaults.set(envelopeWithPhoto, forKey: slot)

    // A reply, a share or a reopened handoff starts a new composition in the same scene. Its
    // envelope replaces the old one before the cleanup reads the stores.
    let next = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try next.startEditing()

    #expect(try fixture.persistence.allDrafts(for: fixture.accountDID).isEmpty, "fixture: nothing to archive")
    #expect(!exists(draftFile(for: photo)))
  }

  @Test("A replaced composition with content keeps only the photo files its recovery copy names")
  func replacedCompositionWithContentKeepsFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let session = fixture.session()
    let replaced = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try replaced.startEditing()
    let kept = try uniquePhoto(), removed = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: kept)); removeIfPresent(draftFile(for: removed)) }
    await fixture.pick(kept, into: replaced)
    replaced.removeMediaItem(withId: await fixture.pick(removed, into: replaced))

    let next = PostComposerViewModel(appState: fixture.state, editingSession: session)
    try next.startEditing()

    let recovery = try #require(try fixture.persistence.allDrafts(for: fixture.accountDID).first)
    #expect(try fixture.persistence.allDrafts(for: fixture.accountDID).count == 1, "fixture: a recovery copy")
    #expect(names(recovery, draftFile(for: kept)), "fixture: the recovery copy names the kept photo")
    #expect(exists(draftFile(for: kept)))
    #expect(!exists(draftFile(for: removed)), "a photo the recovery copy dropped goes with the composition")
  }

  // MARK: Saved drafts

  @Test("Discarding a restored draft removes the photos it added and keeps the row's own")
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
    #expect(exists(draftFile(for: saved)), "the restored composition did not create the row's own photo")
    #expect(!exists(draftFile(for: addedLater)), "a photo the restored composition added goes with it")
  }

  enum SavedReference: String, CaseIterable, CustomTestStringConvertible {
    case otherAccountRow
    case unconfirmedTombstone
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
    case .unconfirmedTombstone:
      // Deleted while its Bluesky create was still unconfirmed: the next sync can still resolve it
      // to a server draft. The pending payload itself names no file here.
      let id = try fixture.persistence.saveDraft(draft(naming: file), accountDID: fixture.accountDID)
      try fixture.persistence.markDeleted(id: id, accountDID: fixture.accountDID)
      let model = try #require(try fixture.persistence.fetchDraftModel(id: id))
      var state = try fixture.persistence.syncState(for: model)
      state.pendingCreate = Data(#"{"posts":[]}"#.utf8)
      try fixture.persistence.saveSyncState(state, for: model)
    case .remoteSnapshotInSyncMetadata:
      let id = try fixture.persistence.saveDraft(draft(naming: nil), accountDID: fixture.accountDID)
      let model = try #require(try fixture.persistence.fetchDraftModel(id: id))
      let remote = Data(#"{"posts":[{"embedImages":[{"localRef":{"path":"\#(file.absoluteString)"}}]}]}"#.utf8)
      try fixture.persistence.saveSyncState(DraftSyncState(baselineRemote: remote), for: model)
    }

    #expect(editor.discardEditingDraft())
    #expect(exists(file))
  }

  @Test("A deleted saved draft no longer keeps a photo it shares")
  func tombstonedRowDoesNotKeepFile() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)
    let id = try fixture.persistence.saveDraft(draft(naming: file), accountDID: fixture.accountDID)
    try fixture.persistence.markDeleted(id: id, accountDID: fixture.accountDID)

    #expect(editor.discardEditingDraft())
    #expect(!exists(file), "nothing shows, restores or re-imports a confirmed tombstone")
  }

  // MARK: Posting

  @Test("A posted composition removes the photo files it created")
  func postedCompositionRemovesCreatedFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let bystander = try fixture.writeLeftoverFile()
    defer { removeIfPresent(bystander) }
    let editor = try fixture.newEditor()
    let posted = try uniquePhoto(), removed = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: posted)); removeIfPresent(draftFile(for: removed)) }
    await fixture.pick(posted, into: editor)
    editor.removeMediaItem(withId: await fixture.pick(removed, into: editor))

    #expect(fixture.post(editor))

    #expect(editor.editingSession?.currentDraft == nil, "fixture: the composition ended")
    #expect(!exists(draftFile(for: posted)), "uploads are done and nothing reopens the composition")
    #expect(!exists(draftFile(for: removed)))
    #expect(exists(bystander), "a file the composition did not write is never removed")
  }

  @Test("Posting a restored draft removes the photos it added and keeps the row's own")
  func postedRestoredDraftRemovesAddedFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let saved = try uniquePhoto(), added = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: saved)); removeIfPresent(draftFile(for: added)) }
    let author = try fixture.newEditor()
    await fixture.pick(saved, into: author)
    let rowID = try #require(author.editingSession).stash(try #require(author.captureEditingSnapshot()))
    author.clearAll()
    let row = try #require(try fixture.persistence.fetchDraftModel(id: rowID))

    let reopened = PostComposerViewModel(
      appState: fixture.state, editingSession: fixture.session(persistDelay: .zero)
    )
    try reopened.restoreSavedDraft(DraftPostViewModel(draftPost: row))
    await fixture.pick(added, into: reopened)
    // The autosave writes the added photo into the restored row, so only its tombstone could
    // keep the file once the post succeeds.
    try await waitUntil { names(row, draftFile(for: added)) }
    #expect(names(row, draftFile(for: added)), "fixture: the restored row names the added photo")

    #expect(fixture.post(reopened))

    #expect(try fixture.persistence.syncState(for: row).deletedAt != nil, "fixture: the row is tombstoned")
    #expect(!exists(draftFile(for: added)))
    #expect(exists(draftFile(for: saved)), "the row's own photo is left to the orphan sweep")
  }

  @Test("A submission whose editor changed after capture keeps the files")
  func changedSubmissionKeepsFiles() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = try fixture.newEditor()
    let photo = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: photo)) }
    await fixture.pick(photo, into: editor)
    let snapshot = editor.captureEditingSnapshot()
    let content = editor.editingContent()
    editor.beginSubmission()
    editor.postText = "Typed while posting"

    #expect(!editor.completeEditingSubmission(snapshot, content: content))
    editor.endSubmission()

    #expect(editor.editingSession?.currentDraft != nil, "fixture: the composition is still open")
    #expect(exists(draftFile(for: photo)))
  }

  enum PostedHolder: String, CaseIterable, CustomTestStringConvertible {
    case otherSceneEditor
    case liveSavedRow
    case recoveryEnvelope
    case pendingHandoff
    var testDescription: String { rawValue }
  }

  @Test("A posted composition keeps a photo something else still names", arguments: PostedHolder.allCases)
  func postedCompositionKeepsNamedFiles(holder: PostedHolder) async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)
    var otherEditor: PostComposerViewModel?
    let queue = ComposerAccountSwitchQueue()

    switch holder {
    case .otherSceneEditor:
      otherEditor = try fixture.newEditor()
      await fixture.pick(photo, into: try #require(otherEditor))
    case .liveSavedRow:
      _ = try fixture.persistence.saveDraft(draft(naming: file), accountDID: fixture.accountDID)
    case .recoveryEnvelope:
      fixture.defaults.set(
        Data(#"{"rawImageURLString":"\#(file.absoluteString)"}"#.utf8),
        forKey: SceneComposerEditingSession.persistenceKey(sceneID: UUID(), accountDID: fixture.accountDID)
      )
    case .pendingHandoff:
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
    }

    #expect(fixture.post(editor))
    #expect(exists(file))
    withExtendedLifetime(otherEditor) {}
    withExtendedLifetime(queue) {}
  }

  // MARK: Saving a draft

  @Test("Saving a draft removes the photos it dropped and keeps the ones the row names")
  func stashRemovesDroppedPhotos() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let editor = try fixture.newEditor()
    let kept = try uniquePhoto(), removed = try uniquePhoto()
    defer { removeIfPresent(draftFile(for: kept)); removeIfPresent(draftFile(for: removed)) }
    await fixture.pick(kept, into: editor)
    editor.removeMediaItem(withId: await fixture.pick(removed, into: editor))

    // Save Draft, and the New post and camera stashes.
    let rowID = try #require(editor.editingSession).stash(try #require(editor.captureEditingSnapshot()))
    editor.clearAll()

    let row = try #require(try fixture.persistence.fetchDraftModel(id: rowID))
    #expect(names(row, draftFile(for: kept)), "fixture: the saved row names the kept photo")
    #expect(exists(draftFile(for: kept)))
    #expect(!exists(draftFile(for: removed)))
  }

  @Test("Saving a restored draft again removes the photos it added and dropped")
  func restashRemovesDroppedAdditions() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let saved = try uniquePhoto(), dropped = try uniquePhoto(), added = try uniquePhoto()
    defer { [saved, dropped, added].forEach { removeIfPresent(draftFile(for: $0)) } }
    let author = try fixture.newEditor()
    await fixture.pick(saved, into: author)
    let rowID = try #require(author.editingSession).stash(try #require(author.captureEditingSnapshot()))
    author.clearAll()
    let row = try #require(try fixture.persistence.fetchDraftModel(id: rowID))

    let reopened = PostComposerViewModel(appState: fixture.state, editingSession: fixture.session())
    try reopened.restoreSavedDraft(DraftPostViewModel(draftPost: row))
    reopened.removeMediaItem(withId: await fixture.pick(dropped, into: reopened))
    await fixture.pick(added, into: reopened)
    #expect(try reopened.editingSession?.stash(try #require(reopened.captureEditingSnapshot())) == rowID)
    reopened.clearAll()

    #expect(names(row, draftFile(for: saved)) && names(row, draftFile(for: added)), "fixture: the row's photos")
    #expect(exists(draftFile(for: saved)))
    #expect(exists(draftFile(for: added)))
    #expect(!exists(draftFile(for: dropped)))
  }

  // MARK: Reusing a file

  @Test("Reusing a draft photo file marks it used now")
  func reuseRefreshesModificationDate() throws {
    let photo = try uniquePhoto()
    let first = try #require(CodableMediaItem.writeImageData(photo))
    let url = try #require(URL(string: first.urlString))
    defer { removeIfPresent(url) }
    #expect(first.created)
    let monthAgo = Date().addingTimeInterval(-30 * 86_400)
    try FileManager.default.setAttributes([.modificationDate: monthAgo], ofItemAtPath: url.path)

    let second = try #require(CodableMediaItem.writeImageData(photo))

    #expect(!second.created, "the file was already there")
    let modified = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    #expect(abs(modified.timeIntervalSinceNow) < 60, "the orphan sweep measures time unused from here")
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

  @Test("A handoff a window has claimed but not opened yet keeps a photo it names")
  func claimedHandoffKeepsSharedFile() async throws {
    let fixture = try await Fixture()
    defer { fixture.cleanUp() }
    let photo = try uniquePhoto()
    let file = draftFile(for: photo)
    defer { removeIfPresent(file) }
    let editor = try fixture.newEditor()
    await fixture.pick(photo, into: editor)
    // SceneWindowState holds this between claiming the handoff from the queue and beginning
    // the target account's composition; a failed beginNew leaves it there.
    let claimed = ClaimedComposerReopen()
    claimed.reopen = PendingComposerReopen(
      id: UUID(), sourceSceneID: UUID(), accountDID: fixture.accountDID, draft: draft(naming: file)
    )

    #expect(editor.discardEditingDraft())
    #expect(exists(file))
    withExtendedLifetime(claimed) {}
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
  let handoffSuiteName: String
  let handoffDefaults: UserDefaults
  let outboxQueueURL: URL
  let legacyDraftsDirectory: URL
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
    // The handoff slot, the outbox and the legacy-drafts folder are this fixture's own, not the
    // host app's.
    handoffSuiteName = "\(suiteName).handoff"
    handoffDefaults = try #require(UserDefaults(suiteName: handoffSuiteName))
    outboxQueueURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("draft-photo-cleanup-outbox-\(UUID().uuidString).json")
    legacyDraftsDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("draft-photo-cleanup-legacy-drafts-\(UUID().uuidString)", isDirectory: true)
    manager.useDraftImageStoresForTesting(
      handoffDefaults: handoffDefaults, outboxQueueURL: outboxQueueURL,
      legacyDraftsDirectory: legacyDraftsDirectory
    )
  }

  func session(persistDelay: Duration = .seconds(60)) -> SceneComposerEditingSession {
    SceneComposerEditingSession(
      manager: manager, accountDID: accountDID, sceneID: UUID(), defaults: defaults,
      persistDelay: persistDelay
    )
  }

  /// What createPost and createThread do around a submission that succeeded.
  func post(_ editor: PostComposerViewModel) -> Bool {
    let snapshot = editor.captureEditingSnapshot()
    let content = editor.editingContent()
    editor.beginSubmission()
    defer { editor.endSubmission() }
    return editor.completeEditingSubmission(snapshot, content: content)
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
    handoffDefaults.removePersistentDomain(forName: handoffSuiteName)
    try? FileManager.default.removeItem(at: outboxQueueURL)
    try? FileManager.default.removeItem(at: legacyDraftsDirectory)
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

/// A reply with nothing written yet.
private func replyDraft() -> PostComposerDraft {
  PostComposerDraft(
    postText: "", mediaItems: [], videoItem: nil, selectedGif: nil,
    selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
    isThreadMode: false, currentThreadIndex: 0,
    parentPostURI: "at://did:plc:draftphotocleanup/app.bsky.feed.post/parent", quotedPostURI: nil
  )
}

private func exists(_ url: URL) -> Bool {
  FileManager.default.fileExists(atPath: url.path)
}

private func removeIfPresent(_ url: URL) {
  try? FileManager.default.removeItem(at: url)
}

/// Whether the saved row's draft names `file`.
@MainActor
private func names(_ row: DraftPost, _ file: URL) -> Bool {
  row.draftData.range(of: Data(file.lastPathComponent.utf8)) != nil
}

/// Waits for a debounced autosave, for at most two seconds.
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<200 where !condition() {
    try await Task.sleep(for: .milliseconds(10))
  }
}
#endif
