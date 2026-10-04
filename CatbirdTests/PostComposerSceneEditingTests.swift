import Foundation
import Petrel
import SwiftData
import Testing
@testable import Catbird

@Suite("Composer scene editing call sites")
@MainActor
struct PostComposerSceneEditingTests {
  private func makeModel(
    sceneID: UUID = UUID(),
    appState: AppState? = nil
  ) async throws -> (PostComposerViewModel, SceneComposerEditingSession, UserDefaults, DraftPersistence) {
    let state: AppState
    if let appState {
      state = appState
    } else {
      let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
      state = AppState(userDID: "did:plc:composerclaims", client: client)
    }
    let defaults = UserDefaults(suiteName: "PostComposerSceneEditingTests.\(UUID().uuidString)")!
    let container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let persistence = DraftPersistence(modelContext: container.mainContext)
    let manager = ComposerDraftManager(
      accountDID: state.userDID, modelContext: container.mainContext, defaults: defaults
    )
    let session = SceneComposerEditingSession(
      manager: manager, accountDID: state.userDID,
      sceneID: sceneID, defaults: defaults
    )
    return (PostComposerViewModel(appState: state, editingSession: session), session, defaults, persistence)
  }

  @Test("Minimizing an empty reply clears its live reference and resets the composer")
  func emptyReplyMinimizeResetsModel() async throws {
    let (model, session, _, _) = try await makeModel()
    let draft = PostComposerDraft(postText: " \n", mediaItems: [], videoItem: nil,
      selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: [], isThreadMode: false, currentThreadIndex: 0,
      parentPostURI: "at://did:plc:source/app.bsky.feed.post/reply", quotedPostURI: nil)
    try model.startEditing(restoring: draft)
    #expect(model.isReply)
    #expect(!model.hasMeaningfulDraftContent)
    #expect(model.minimizeEditingDraft())
    #expect(!model.isReply)
    #expect(model.postText.isEmpty)
    #expect(session.currentDraft == nil)
    #expect(!session.isMinimized)
    #expect(model.mediaItems.isEmpty)
  }

  @Test("Thread draft dismissal preserves earlier posts after clearing the active post")
  func threadDismissalKeepsInactiveContent() async throws {
    let (model, session, _, _) = try await makeModel()
    try model.startEditing()
    model.postText = "First meaningful thread post"
    model.enterThreadMode()
    model.addNewThreadEntry()
    model.postText = "Active post to clear"
    model.updateCurrentThreadEntry()
    model.postText = ""
    #expect(model.hasMeaningfulDraftContent)
    #expect(model.minimizeEditingDraft())
    #expect(session.isMinimized)
    #expect(session.currentDraft?.threadEntries.first?.text == "First meaningful thread post")
    #expect(session.currentDraft?.threadEntries.last?.text.isEmpty == true)
  }

  @Test("Capturing a live thread twice retains serialized photo references and revision")
  func threadSnapshotsRetainMediaReferences() async throws {
    let (model, session, _, _) = try await makeModel()
    var photo = PostComposerViewModel.MediaItem()
    photo.rawData = Data("synthetic thread photo".utf8)
    photo.isLoading = false
    model.mediaItems = [photo]
    model.postText = "Thread photo"
    model.isThreadMode = true
    try model.startEditing()
    let first = try #require(model.captureEditingSnapshot())
    #expect(model.hasMeaningfulDraftContent)
    let second = try #require(model.captureEditingSnapshot())
    #expect(first.draft == second.draft)
    #expect(first.revision == second.revision)
    #expect(session.currentDraft == first.draft)
  }

  @Test("Inspecting meaningful content does not serialize or revive cleared active thread text")
  func contentInspectionIsPure() async throws {
    let (model, session, _, _) = try await makeModel()
    let draft = PostComposerDraft(postText: "", mediaItems: [], videoItem: nil,
      selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: [], isThreadMode: false, currentThreadIndex: 0,
      parentPostURI: "at://did:plc:source/app.bsky.feed.post/reply", quotedPostURI: nil)
    try model.startEditing(restoring: draft)
    model.enterThreadMode()
    model.addNewThreadEntry()
    model.postText = "Text cleared before dismissal"
    let before = try #require(model.captureEditingSnapshot())
    model.postText = ""
    let entriesBeforeInspection = model.threadEntries

    #expect(!model.hasMeaningfulDraftContent)
    #expect(model.threadEntries == entriesBeforeInspection)
    #expect(session.currentDraft == before.draft)
    #expect(session.snapshot()?.revision == before.revision)
    #expect(model.minimizeEditingDraft())
    #expect(session.currentDraft == nil)
    #expect(!model.isReply)
  }

  @Test("Pending audio survives minimize and explicit removal does not delete its file")
  func pendingAudioIsPreservedUntilRemoved() async throws {
    let (model, session, _, _) = try await makeModel()
    try model.startEditing()
    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("pending-audio-\(UUID()).m4a")
    try Data("recording fixture".utf8).write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL); session.invalidate() }
    let claim = try #require(model.editingClaim)
    let origin = model.threadEntries[0].id
    #expect(model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: origin))
    #expect(model.minimizeEditingDraft())
    #expect(session.currentDraft?.pendingAudioURLString == audioURL.absoluteString)
    let resumed = PostComposerViewModel(appState: model.appState, editingSession: session)
    try resumed.startEditing(claim: claim)
    #expect(resumed.pendingAudioURL == audioURL)
    #expect(resumed.pendingAudioThreadEntryID == origin)
    #expect(resumed.submitValidationState.reason == .pendingAudio)
    #expect(!model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: model.threadEntries[0].id))
    resumed.removePendingAudio()
    #expect(resumed.pendingAudioURL == nil)
    #expect(resumed.pendingAudioThreadEntryID == nil)
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
  }

  @Test("A single-post reply containing only a kept link survives minimize and restoration")
  func keptLinkReplySurvivesMinimize() async throws {
    let (model, session, _, _) = try await makeModel()
    let draft = PostComposerDraft(postText: "", mediaItems: [], videoItem: nil,
      selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: [], isThreadMode: false, currentThreadIndex: 0,
      parentPostURI: "at://did:plc:source/app.bsky.feed.post/reply", quotedPostURI: nil)
    try model.startEditing(restoring: draft)
    let before = try #require(model.captureEditingSnapshot())
    let url = "https://example.com/kept-link"
    let card = URLCardResponse(error: "", likelyType: "html", url: url,
                              title: "Kept link", description: "Saved card", image: "")
    model.selectedEmbedURL = url
    model.urlsKeptForEmbed = [url]
    model.urlCards[url] = card
    #expect(model.postText.isEmpty)
    #expect(model.hasMeaningfulDraftContent)
    let updated = try #require(model.captureEditingSnapshot())
    #expect(updated.revision > before.revision)
    #expect(updated.draft.threadEntries.first?.selectedEmbedURL == url)
    #expect(model.minimizeEditingDraft())
    #expect(session.isMinimized)
    let resumed = PostComposerViewModel(appState: model.appState, editingSession: session)
    try resumed.startEditing(claim: updated.claim)
    #expect(resumed.selectedEmbedURL == url)
    #expect(resumed.urlsKeptForEmbed == [url])
    #expect(resumed.urlCards[url] == card)
    #expect(resumed.hasMeaningfulDraftContent)
    #expect(resumed.isReply)
    session.invalidate()
  }

  @Test("Stale single-post entry text cannot retain an otherwise empty reply")
  func clearedSinglePostReplyDropsStaleEntryText() async throws {
    let (model, session, _, _) = try await makeModel()
    let draft = PostComposerDraft(postText: "", mediaItems: [], videoItem: nil,
      selectedGif: nil, selectedLanguages: [], selectedLabels: [], outlineTags: [],
      threadEntries: [], isThreadMode: false, currentThreadIndex: 0,
      parentPostURI: "at://did:plc:source/app.bsky.feed.post/reply", quotedPostURI: nil)
    try model.startEditing(restoring: draft)
    model.postText = "Previous single-post text"
    _ = try #require(model.captureEditingSnapshot())
    model.postText = ""
    #expect(model.threadEntries.first?.text == "Previous single-post text")
    #expect(!model.hasMeaningfulDraftContent)
    #expect(model.minimizeEditingDraft())
    #expect(session.currentDraft == nil)
    #expect(!model.isReply)
    #expect(!session.isMinimized)
  }

  @Test("Finishing after save and restore attaches to the recording's original post")
  func pendingAudioRetainsOriginAcrossThreadSelectionAndRestore() async throws {
    let (model, session, _, _) = try await makeModel()
    defer { session.invalidate() }
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let audioURL = URL(fileURLWithPath: "/Documents/original-recording.m4a")
    let origin = model.threadEntries[0].id
    #expect(model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: origin))
    model.postText = "Recording belongs here"
    model.enterThreadMode()
    model.addNewThreadEntry()
    model.postText = "Keep selected post unchanged"
    let selectedEntry = model.threadEntries[model.currentThreadIndex].id
    // Cancel/reopen visualizer retains pending data; persistence must retain the same origin.
    let encoded = try JSONEncoder().encode(model.saveDraftState())
    let decoded = try JSONDecoder().decode(PostComposerDraft.self, from: encoded)
    #expect(decoded.pendingAudioThreadEntryID == origin)
    #expect(model.minimizeEditingDraft())
    let resumed = PostComposerViewModel(appState: model.appState, editingSession: session)
    try resumed.startEditing(claim: claim)
    #expect(resumed.pendingAudioThreadEntryID == origin)
    #expect(resumed.threadEntries[resumed.currentThreadIndex].id == selectedEntry)
    let prepared = try preparedAudioVideo()
    defer { prepared.discard() }
    let attached = try await resumed.finishPendingAudio(
      withVideoAt: prepared.item.rawVideoURL!, audioURL: audioURL, claim: claim,
      threadEntryID: origin, prepareVideo: { _ in prepared }
    )
    #expect(attached)
    #expect(resumed.threadEntries.first(where: { $0.id == origin })?.videoItem?.id == prepared.item.id)
    #expect(resumed.videoItem == nil)
    #expect(resumed.postText == "Keep selected post unchanged")
    #expect(resumed.pendingAudioURL == nil)
    #expect(resumed.pendingAudioThreadEntryID == nil)
    #expect(session.currentDraft?.threadEntries.first?.videoItem != nil)
    #expect(FileManager.default.fileExists(atPath: prepared.item.rawVideoURL!.path))
  }

  @Test("Removed original post retains audio for explicit recovery without retargeting it")
  func removedAudioOriginCannotAttachElsewhere() async throws {
    let (model, session, _, _) = try await makeModel()
    defer { session.invalidate() }
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let origin = model.threadEntries[0].id
    let audioURL = URL(fileURLWithPath: "/Documents/orphaned-recording.m4a")
    #expect(model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: origin))
    model.enterThreadMode()
    model.addNewThreadEntry()
    model.removeThreadEntry(at: 0)
    var preparations = 0
    let attached = try await model.finishPendingAudio(
      withVideoAt: audioURL, audioURL: audioURL, claim: claim, threadEntryID: origin,
      prepareVideo: { _ in preparations += 1; return try preparedAudioVideo() }
    )
    #expect(!attached)
    #expect(preparations == 0)
    #expect(model.pendingAudioURL == audioURL)
    #expect(model.pendingAudioThreadEntryID == origin)
    #expect(model.videoItem == nil)
  }

  @Test("An already canceled audio finish cannot begin preparation or mutate the draft")
  func canceledAudioFinishNeverPrepares() async throws {
    let (model, session, _, _) = try await makeModel()
    defer { session.invalidate() }
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let origin = model.threadEntries[0].id
    let audioURL = URL(fileURLWithPath: "/Documents/kept-recording.m4a")
    #expect(model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: origin))
    let originalContent = model.editingContent()
    let originalSnapshot = try #require(session.snapshot())
    var preparations = 0
    let task = Task { @MainActor in
      try await model.finishPendingAudio(
        withVideoAt: audioURL, audioURL: audioURL, claim: claim, threadEntryID: origin,
        prepareVideo: { _ in preparations += 1; return try preparedAudioVideo() }
      )
    }
    task.cancel()
    #expect(try await task.value == false)
    #expect(preparations == 0)
    #expect(model.editingContent() == originalContent)
    #expect(session.snapshot()?.revision == originalSnapshot.revision)
    #expect(session.currentDraft == originalSnapshot.draft)
  }

  @Test("Suspended audio preparation cannot overwrite cancellation, replacement claim, media, or thread selection",
        arguments: ["cancel", "claim", "media", "thread"])
  func suspendedAudioFinishPreservesChangedDraft(_ change: String) async throws {
    let (model, session, _, _) = try await makeModel()
    defer { session.invalidate() }
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let origin = model.threadEntries[0].id
    let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("kept-recording-\(UUID()).m4a")
    let recordingBytes = Data("recording retained through stale preparation".utf8)
    try recordingBytes.write(to: audioURL)
    defer { try? FileManager.default.removeItem(at: audioURL) }
    #expect(model.preserveRecordedAudio(at: audioURL, claim: claim, threadEntryID: origin))
    let original = model.editingContent()
    let originalSnapshot = try #require(session.snapshot())
    let preparation = SuspendedAudioPreparation()
    let task = Task { @MainActor in
      try await model.finishPendingAudio(
        withVideoAt: audioURL, audioURL: audioURL, claim: claim, threadEntryID: origin,
        prepareVideo: { _ in await preparation.prepare() }
      )
    }
    for _ in 0..<100 {
      if preparation.continuation != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(preparation.continuation != nil)
    #expect(model.isPreparingPendingAudio)
    #expect(model.editingContent() == original)
    #expect(session.currentDraft == originalSnapshot.draft)
    #expect(session.snapshot()?.revision == originalSnapshot.revision)
    switch change {
    case "cancel": task.cancel()
    case "claim":
      model.clearAll()
      model.postText = "Replacement editor on the same model"
      try model.startEditing()
      #expect(model.editingClaim != claim)
    case "media":
      var photo = PostComposerViewModel.MediaItem()
      photo.rawData = Data("new attachment".utf8)
      photo.isLoading = false
      model.mediaItems = [photo]
    default:
      model.enterThreadMode()
      model.addNewThreadEntry()
      model.postText = "Selected a new thread post during preparation"
    }
    let expectedSnapshot = try #require(model.captureEditingSnapshot())
    let expected = model.editingContent()
    let prepared = try preparedAudioVideo()
    preparation.continuation?.resume(returning: prepared)
    preparation.continuation = nil
    #expect(try await task.value == false)
    #expect(!model.isPreparingPendingAudio)
    #expect(model.editingContent() == expected)
    #expect(session.currentDraft == expectedSnapshot.draft)
    #expect(session.snapshot()?.revision == expectedSnapshot.revision)
    #expect(!FileManager.default.fileExists(atPath: prepared.item.rawVideoURL!.path))
    #expect(try Data(contentsOf: audioURL) == recordingBytes)
  }

  private func preparedAudioVideo() throws -> PostComposerViewModel.PreparedPendingAudioVideo {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("staged-visualizer-\(UUID()).mp4")
    try Data("staged video bytes".utf8).write(to: url)
    var item = PostComposerViewModel.MediaItem(url: url, isAudioVisualizerVideo: true)
    item.isLoading = false
    return PostComposerViewModel.PreparedPendingAudioVideo(item: item)
  }

  @MainActor
  private final class SuspendedAudioPreparation {
    var continuation: CheckedContinuation<PostComposerViewModel.PreparedPendingAudioVideo, Never>?
    func prepare() async -> PostComposerViewModel.PreparedPendingAudioVideo {
      await withCheckedContinuation { continuation = $0 }
    }
  }

  @Test("A dismissed model cannot minimize or reset the replacement editor")
  func staleMinimizeKeepsReplacement() async throws {
    let (old, session, _, _) = try await makeModel()
    try old.startEditing()
    let replacement = PostComposerViewModel(appState: old.appState, editingSession: session)
    replacement.postText = "Replacement text"
    try replacement.startEditing()
    #expect(!old.minimizeEditingDraft())
    #expect(session.currentDraft?.postText == "Replacement text")
    #expect(replacement.ownsEditingDraft)
    #expect(!session.isMinimized)
  }

  @Test("A request without a claim starts fresh instead of implicitly restoring another editor")
  func newRequestDoesNotResumePreviousEditor() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Previous editor"
    try model.startEditing()
    let previousClaim = try #require(model.editingClaim)
    let replacement = PostComposerViewModel(appState: model.appState, editingSession: session)
    try replacement.startEditing()
    #expect(replacement.postText.isEmpty)
    #expect(replacement.editingClaim != previousClaim)
    #expect(session.currentDraft?.postText.isEmpty == true)
  }

  @Test("An exact claim resumes only its originating window and account")
  func explicitResumeRejectsAnotherWindow() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Origin body"
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let (other, otherSession, _, _) = try await makeModel(appState: model.appState)
    #expect(throws: NSError.self) { try other.startEditing(claim: claim) }
    #expect(otherSession.currentDraft == nil)
    let resumed = PostComposerViewModel(appState: model.appState, editingSession: session)
    try resumed.startEditing(claim: claim)
    #expect(resumed.postText == "Origin body")
    #expect(resumed.editingClaim == claim)
    #expect(!model.ownsEditingDraft)
    #expect(resumed.ownsEditingDraft)
  }

  @Test("Late autosave from a replaced model cannot overwrite the new editor")
  func staleAutosaveCannotWriteReplacement() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Old editor"
    try model.startEditing()
    let oldClaim = try #require(model.editingClaim)
    let replacement = PostComposerViewModel(appState: model.appState, editingSession: session)
    replacement.postText = "New editor"
    try replacement.startEditing()
    model.postText = "Late old callback"
    model.saveDraftIfNeeded(claim: oldClaim)
    #expect(session.currentDraft?.postText == "New editor")
  }

  @Test("Selecting a saved draft preserves typing since the last autosave")
  func savedSelectionPreservesUnflushedTyping() async throws {
    let (model, session, _, persistence) = try await makeModel()
    try model.startEditing()
    model.postText = "Typed just before opening Drafts"
    let savedModel = PostComposerViewModel(appState: model.appState)
    savedModel.postText = "Previously saved target"
    let savedID = try persistence.saveDraft(savedModel.saveDraftState(), accountDID: model.appState.userDID)
    let fetched = try persistence.fetchDraftModel(id: savedID)
    let savedRow = try #require(fetched)

    let replacement = try model.replacementForSavedDraft(DraftPostViewModel(draftPost: savedRow))
    let rows = try persistence.fetchDrafts(for: model.appState.userDID)
    let bodies = try rows.map { try $0.decodeDraft().postText }
    #expect(bodies.contains("Typed just before opening Drafts"))
    #expect(replacement.postText == "Previously saved target")
    #expect(session.savedDraftID == savedID)
    #expect(!model.ownsEditingDraft)
  }

  @Test("A late media callback cannot overwrite a resumed presentation sharing its saved-row claim")
  func resumedPresentationRevokesOldModel() async throws {
    let (oldModel, session, _, _) = try await makeModel()
    oldModel.postText = "Before minimize"
    try oldModel.startEditing()
    let captured = try #require(oldModel.captureEditingSnapshot())
    let submittedContent = oldModel.editingContent()
    #expect(session.minimize(claim: captured.claim))

    let resumed = PostComposerViewModel(appState: oldModel.appState, editingSession: session)
    try resumed.startEditing(claim: captured.claim)
    resumed.postText = "Typing in the resumed editor"
    // Represents an old photo task reaching saveDraftIfNeeded after its await.
    oldModel.mediaItems = [PostComposerViewModel.MediaItem()]
    oldModel.postText = "Old media callback body"
    oldModel.saveDraftIfNeeded(claim: captured.claim)
    #expect(session.currentDraft?.postText == "Before minimize")
    #expect(!oldModel.completeEditingSubmission(captured, content: submittedContent))
    #expect(session.activeClaim == captured.claim)
    #expect(!oldModel.discardEditingDraft())
    #expect(!oldModel.detachEditingDraftForTransfer(captured))
    resumed.saveDraftIfNeeded()
    #expect(session.currentDraft?.postText == "Typing in the resumed editor")
    #expect(resumed.mediaItems.isEmpty)
  }

  @Test("An unchanged old submission cannot clear unsaved typing in a resumed presentation")
  func resumedEditorRejectsUnchangedOldSubmission() async throws {
    let (oldModel, session, _, _) = try await makeModel()
    oldModel.postText = "Submitted before minimize"
    try oldModel.startEditing()
    let captured = try #require(oldModel.captureEditingSnapshot())
    let content = oldModel.editingContent()
    #expect(session.minimize(claim: captured.claim))
    let resumed = PostComposerViewModel(appState: oldModel.appState, editingSession: session)
    try resumed.startEditing(claim: captured.claim)
    resumed.postText = "Unsaved resumed typing"

    #expect(!oldModel.completeEditingSubmission(captured, content: content))
    #expect(session.activeClaim == captured.claim)
    resumed.saveDraftIfNeeded()
    #expect(session.currentDraft?.postText == "Unsaved resumed typing")
  }

  @Test("A canceled save task cannot write even when its ownership is still current")
  func canceledAutosaveDoesNotWrite() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Before cancellation"
    try model.startEditing()
    let claim = try #require(model.editingClaim)
    let task = Task { @MainActor in
      // Yield guarantees the caller cancels before this write is attempted.
      await Task.yield()
      model.postText = "Canceled callback"
      model.saveDraftIfNeeded(claim: claim)
    }
    task.cancel()
    await task.value
    #expect(session.currentDraft?.postText == "Before cancellation")
  }

  @Test("Autosave does not rotate persisted photo revisions during submission")
  func autosavePausesDuringSubmission() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Posting body"
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    model.beginSubmission()
    model.postText = "Newer body"
    model.saveDraftIfNeeded(claim: captured.claim)
    #expect(session.snapshot()?.revision == captured.revision)
    #expect(session.currentDraft?.postText == "Posting body")
    model.endSubmission()
    model.saveDraftIfNeeded(claim: captured.claim)
    #expect(session.currentDraft?.postText == "Newer body")
  }

  @Test("Successful unchanged submission clears its captured editor")
  func unchangedSubmissionCompletes() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Submitted body"
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    #expect(model.completeEditingSubmission(captured, content: content))
    #expect(session.currentDraft == nil)
  }

  @Test("An unchanged photo submission does not create a new serialized media revision")
  func unchangedPhotoCompletesWithoutReserialization() async throws {
    let (model, session, _, _) = try await makeModel()
    var image = PostComposerViewModel.MediaItem()
    image.rawData = Data("owned photo bytes".utf8)
    image.isLoading = false
    model.mediaItems = [image]
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    #expect(model.completeEditingSubmission(captured, content: content))
    #expect(session.activeClaim == nil)
  }

  @Test("Thread video embed preparation restores the selected editor video before completion")
  func unchangedVideoThreadCompletes() async throws {
    let (model, session, _, _) = try await makeModel()
    var selectedVideo = PostComposerViewModel.MediaItem()
    selectedVideo.isLoading = false
    selectedVideo.altText = "Selected entry video"
    model.videoItem = selectedVideo
    model.postText = "Selected entry"
    model.isThreadMode = true
    model.updateCurrentThreadEntry()
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    var earlierEntry = ThreadEntry()
    earlierEntry.videoItem = PostComposerViewModel.MediaItem()
    // No transport is required to exercise the scratch-state ownership boundary.
    model.mediaUploadManager = nil
    _ = try await model.createVideoEmbedForEntry(earlierEntry)
    #expect(model.videoItem?.id == selectedVideo.id)
    #expect(model.completeEditingSubmission(captured, content: content))
    #expect(session.currentDraft == nil)
  }

  @Test("Failed thread video preparation also restores the active editor video")
  func failedVideoPreparationPreservesActiveVideo() async throws {
    let (model, _, _, _) = try await makeModel()
    let selectedVideo = PostComposerViewModel.MediaItem()
    model.videoItem = selectedVideo
    var incompleteEntry = ThreadEntry()
    incompleteEntry.videoItem = PostComposerViewModel.MediaItem()
    do {
      _ = try await model.createVideoEmbedForEntry(incompleteEntry)
      Issue.record("An entry without a video source must reject upload")
    } catch {
      #expect(model.videoItem?.id == selectedVideo.id)
    }
  }

  @Test("Submission completion preserves newer unsaved typing")
  func completionPreservesNewerTyping() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Submitted body"
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    model.postText = "Typed while request awaited"
    #expect(!model.completeEditingSubmission(captured, content: content))
    model.saveDraftIfNeeded()
    #expect(session.currentDraft?.postText == "Typed while request awaited")
  }

  @Test("A media edit with the same media identity invalidates submission cleanup")
  func completionPreservesNewerAltText() async throws {
    let (model, session, _, _) = try await makeModel()
    var media = PostComposerViewModel.MediaItem()
    media.altText = "Original description"
    media.isLoading = false
    model.mediaItems = [media]
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    model.mediaItems[0].altText = "Revised description"
    #expect(!model.completeEditingSubmission(captured, content: content))
    #expect(session.activeClaim == captured.claim)
  }

  @Test("Submission from one window cannot clear a second window editor")
  func completionIsSceneLocal() async throws {
    let (first, firstSession, _, _) = try await makeModel()
    first.postText = "First window"
    try first.startEditing()
    let (second, secondSession, _, _) = try await makeModel(appState: first.appState)
    second.postText = "Second window"
    try second.startEditing()
    let captured = try #require(first.captureEditingSnapshot())
    #expect(first.completeEditingSubmission(captured, content: first.editingContent()))
    #expect(firstSession.currentDraft == nil)
    #expect(secondSession.currentDraft?.postText == "Second window")
  }

  @Test("Late successful submission cannot clear a replacement in the same window")
  func completionRejectsReplacedClaim() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Old request"
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    let content = model.editingContent()
    let replacement = PostComposerViewModel(appState: model.appState, editingSession: session)
    replacement.postText = "Replacement"
    try replacement.startEditing()
    #expect(!model.completeEditingSubmission(captured, content: content))
    #expect(session.currentDraft?.postText == "Replacement")
  }
  @Test("Scene invalidation captures last typing before the editor disappears")
  func invalidationFlushesOtherWindowTyping() async throws {
    let (first, firstSession, _, firstStore) = try await makeModel()
    first.postText = "First initial body"
    try first.startEditing()
    let (other, otherSession, _, otherStore) = try await makeModel(appState: first.appState)
    other.postText = "Other initial body"
    try other.startEditing()
    first.postText = "First last unsaved typing"
    other.postText = "Other window last unsaved typing"
    #expect(otherSession.currentDraft?.postText == "Other initial body")

    // Account/window invalidation may precede either view's onDisappear.
    firstSession.invalidate()
    otherSession.invalidate()
    let firstBodies = try firstStore.fetchDrafts(for: first.appState.userDID).map { try $0.decodeDraft().postText }
    let otherBodies = try otherStore.fetchDrafts(for: other.appState.userDID).map { try $0.decodeDraft().postText }
    #expect(firstBodies.contains("First last unsaved typing"))
    #expect(otherBodies.contains("Other window last unsaved typing"))
  }

  @Test("Resume restores the outgoing editor's latest body before autosave")
  func resumeReadsFlushedLiveProvider() async throws {
    let (oldModel, session, _, _) = try await makeModel()
    oldModel.postText = "Initial body"
    try oldModel.startEditing()
    let claim = try #require(oldModel.editingClaim)
    oldModel.postText = "Latest unsaved body"
    let resumed = PostComposerViewModel(appState: oldModel.appState, editingSession: session)
    try resumed.startEditing(claim: claim)
    #expect(resumed.postText == "Latest unsaved body")
    #expect(session.currentDraft?.postText == "Latest unsaved body")
    #expect(!oldModel.ownsEditingDraft)
    #expect(resumed.ownsEditingDraft)
  }

  @Test("An old model's unregister and deinit cannot remove the replacement provider")
  func oldModelCannotUnregisterReplacementProvider() async throws {
    var fixture = Optional(try await makeModel())
    let session = try #require(fixture?.1)
    let store = try #require(fixture?.3)
    let appState = try #require(fixture?.0.appState)
    try fixture?.0.startEditing()
    let claim = try #require(session.activeClaim)
    weak var retiredModel = fixture?.0
    let replacement = PostComposerViewModel(appState: appState, editingSession: session)
    try replacement.startEditing(claim: claim)
    replacement.postText = "Replacement's unsaved body"
    #expect(fixture?.0.unregisterLiveDraftProvider() == false)
    fixture = nil
    #expect(retiredModel == nil)

    session.invalidate()
    let bodies = try store.fetchDrafts(for: appState.userDID).map { try $0.decodeDraft().postText }
    #expect(bodies.contains("Replacement's unsaved body"))
  }

  @Test("Unchanged live photo snapshots retain media references and revision")
  func unchangedLiveProviderDoesNotRotateRevision() async throws {
    let (model, session, _, _) = try await makeModel()
    var image = PostComposerViewModel.MediaItem()
    image.rawData = Data("unchanged live photo".utf8)
    image.isLoading = false
    model.mediaItems = [image]
    try model.startEditing()
    let initial = try #require(session.snapshot())
    #expect(session.minimize(claim: initial.claim))
    #expect(session.resume(claim: initial.claim))
    let captured = try #require(model.captureEditingSnapshot())
    #expect(captured.revision == initial.revision)
    #expect(captured.draft == initial.draft)
  }

  @Test("Transfer refuses a stale snapshot after capturing newer live typing")
  func transferPreservesNewerLiveTyping() async throws {
    let (model, session, _, _) = try await makeModel()
    model.postText = "Captured transfer"
    try model.startEditing()
    let captured = try #require(model.captureEditingSnapshot())
    model.postText = "Newer source typing"
    #expect(!model.detachEditingDraftForTransfer(captured))
    #expect(session.currentDraft?.postText == "Newer source typing")
    #expect(session.activeClaim == captured.claim)
  }

  @Test("Invalidation during submission persists preflight content, not upload scratch state")
  func submissionProviderUsesFrozenEditorBody() async throws {
    let (model, session, _, store) = try await makeModel()
    model.postText = "Body before submission"
    try model.startEditing()
    model.beginSubmission()
    model.postText = "Temporary per-entry upload text"
    session.invalidate()
    let bodies = try store.fetchDrafts(for: model.appState.userDID).map { try $0.decodeDraft().postText }
    #expect(bodies.contains("Body before submission"))
    #expect(!bodies.contains("Temporary per-entry upload text"))
  }

  @Test("Cancelled source teardown preserves typing after a target account editor is created")
  func cancelledSourceTeardownStillFlushesOwnedBody() async throws {
    let (source, sourceSession, _, sourceStore) = try await makeModel()
    source.postText = "Source initial body"
    try source.startEditing()
    source.postText = "Source unsaved body at account replacement"
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let targetState = AppState(userDID: "did:plc:composer-target", client: client)
    let (target, targetSession, _, _) = try await makeModel(appState: targetState)
    target.postText = "Target account editor"
    try target.startEditing()

    // Model account identities replace authentication in this isolated fixture.
    // The source provider must not consult the active account or cancellation.
    let teardown = Task { @MainActor in
      await Task.yield()
      sourceSession.invalidate()
    }
    teardown.cancel()
    await teardown.value
    let bodies = try sourceStore.fetchDrafts(for: source.appState.userDID).map { try $0.decodeDraft().postText }
    #expect(bodies.contains("Source unsaved body at account replacement"))
    #expect(targetSession.currentDraft?.postText == "Target account editor")
  }

}
