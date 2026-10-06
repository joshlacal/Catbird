import Foundation
import os
import Petrel
import SwiftUI
import Observation
import PhotosUI

@MainActor @Observable
final class PostComposerViewModel {
  private let logger = Logger(subsystem: "blue.catbird", category: "PostComposerViewModel")
  
  // MARK: - State Management Control
  
   var isUpdatingText: Bool = false
  private var isDraftMode: Bool = false
  
  // MARK: - Post Content Properties
  
  var postText: String = "" {
    didSet {
      if !isUpdatingText {
        syncAttributedTextFromPlainText()
        if !isDraftMode {
          updatePostContent()
          // Avoid saving the transient draft on every keystroke; rely on
          // periodic autosave and onDisappear/minimize instead.
          if autosaveOnEdit { saveDraftIfNeeded() }
        }
      }
    }
  }
  var richAttributedText: NSAttributedString = NSAttributedString()
  var attributedPostText: AttributedString = AttributedString()
  var selectedLanguages: [LanguageCodeContainer] = []
  var suggestedLanguage: LanguageCodeContainer?
  var selectedLabels: Set<ComAtprotoLabelDefs.LabelValue> = []
  var outlineTags: [String] = []
  
  // MARK: - Thread Properties
  
  var threadEntries: [ThreadEntry] = [ThreadEntry()]
  var currentThreadIndex: Int = 0
  var isThread: Bool = false
  var isThreadMode: Bool = false
  
  // MARK: - Reply and Quote Properties
  
  var parentPost: AppBskyFeedDefs.PostView? {
    didSet {
      if !isUpdatingText {
        pendingParentPostURI = parentPost?.uri.uriString()
        parentRestorationTask?.cancel()
      }
    }
  }
  var quotedPost: AppBskyFeedDefs.PostView? {
    didSet {
      // Entry switching temporarily clears this property while loading a different entry.
      guard !isUpdatingText, threadEntries.indices.contains(currentThreadIndex) else { return }
      let entryID = threadEntries[currentThreadIndex].id
      quoteRestorationTasks[entryID]?.cancel()
      quoteRestorationTasks[entryID] = nil
      threadEntries[currentThreadIndex].quotedPost = quotedPost
      threadEntries[currentThreadIndex].draftQuotedPostURI = quotedPost?.uri.uriString()
      threadEntries[currentThreadIndex].draftQuotedPostCID = quotedPost?.cid.string
    }
  }
  var replyTo: AppBskyFeedDefs.PostView?
  
  // MARK: - Media Properties
  
  @ObservationIgnored let mediaPreviewLoads = MediaPreviewLoadRegistry()
  var mediaItems: [MediaItem] = []
  var videoItem: MediaItem?
  private(set) var pendingAudioURL: URL?
  private(set) var pendingAudioThreadEntryID: UUID?
  private(set) var isPreparingPendingAudio = false
  var currentEditingMediaId: UUID?
  var isAltTextEditorPresented = false
  var isPhotoEditorPresented = false
  var currentEditingImageIndex: Int?
  var isVideoUploading: Bool = false
  var mediaUploadManager: MediaUploadManager?
  // If non-nil, posting is blocked due to server policy
  var videoUploadBlockedReason: String?
  // Optional machine-readable code for blocked state (e.g., "unconfirmed_email")
  var videoUploadBlockedCode: String?
  
  // MARK: - GIF Properties
  
  var selectedGif: TenorGif?
  var isGifSelectionPresented = false
  var showingGifPicker = false
  var searchText: String = ""
  var gifSearchResults: [TenorGif] = []
  var isSearching: Bool = false
  var hasSearched: Bool = false
  
  // MARK: - URL Properties
  
  var detectedURLs: [String] = []
  var urlCards: [String: URLCardResponse] = [:]
  var isLoadingURLCard: Bool = false
  
  // MARK: - URL Embed Selection
  /// The first URL pasted/detected will be used as the embed (if no other embed type is set)
  /// This tracks which URL should be featured as the embed card
  var selectedEmbedURL: String?
  
  /// URLs that should be kept as embeds even when removed from text
  /// This allows users to paste a URL, generate preview, then delete the URL text
  var urlsKeptForEmbed: Set<String> = []
  
  // MARK: - Thumbnail Cache
  
  /// Cache for uploaded thumbnail blobs by URL
  var thumbnailCache: [String: Blob] = [:]
  
  // MARK: - Mention Properties
  
  var mentionSuggestions: [AppBskyActorDefs.ProfileViewBasic] = []
  
  /// Cached mention suggestions mapped to MentionSuggestion model
  var mappedMentionSuggestions: [MentionSuggestion] {
    mentionSuggestions.map { MentionSuggestion(profile: $0) }
  }
  var resolvedProfiles: [String: AppBskyActorDefs.ProfileViewBasic] = [:]
  var cursorPosition: Int = 0
  // Cancelable mention search task to avoid stale results flashing after selection
  var mentionSearchTask: Task<Void, Never>? = nil
  // Cancelable URL embed selection task to debounce link card generation
  var urlEmbedSelectionTask: Task<Void, Never>? = nil
  
  // MARK: - Manual Link Facets (legacy inline links)
  /// Facets derived from inline link attributes when using legacy NSAttributedString path.
  /// These are merged into the facets used for posting so inline links survive even when
  /// the visible text does not contain the raw URL.
  var manualLinkFacets: [AppBskyRichtextFacet] = []

  // Controls whether to autosave the transient draft on each edit.
  // Default: false. We autosave via periodic timer and onDisappear.
  var autosaveOnEdit: Bool = false

  // MARK: - Active RichTextView Reference
  #if os(iOS)
  /// Weak reference to the active UITextView for resetting typing attributes
  /// This is set by the UIKit bridge when the view is created/updated
  /// Can be either RichTextView or LinkEditableTextView depending on composer mode
  weak var activeRichTextView: UITextView?
  #endif

  // MARK: - State Properties
  
  var isPosting: Bool = false
  var alertItem: AlertItem?
  var mediaSourceTracker: Set<String> = []
  var showLabelSelector = false
  var showThreadgateOptions = false
  var interactionSettings: PostInteractionSettingsState = PostInteractionSettingsState() {
    didSet { interactionSettingsRevision += 1 }
  }
  var threadgateSettings: ThreadgateSettings {
    get { interactionSettings.threadgate }
    set { interactionSettings.threadgate = newValue }
  }
  // MARK: - Private Properties
  
  let appState: AppState
  let editingSession: SceneComposerEditingSession?
  private(set) var editingClaim: ComposerDraftClaim?
  private let editingPresentationID = UUID()
  private var serializedEditingContent: EditingContent?
  private var serializedEditingDraft: PostComposerDraft?
  private var submissionRecoveryDraft: PostComposerDraft?

  private var draftRestorationGeneration = UUID()
  private var pendingParentPostURI: String?
  /// True when a restored reply's original post couldn't be loaded.
  private(set) var parentRestoreFailed = false
  private var parentRestorationTask: Task<Void, Never>?
  private var quoteRestorationTasks: [UUID: Task<Void, Never>] = [:]
  private var interactionDefaultsTask: Task<Void, Never>?
  private var interactionSettingsRevision = 0
  private struct DraftInteractionSnapshot {
    let settings: PostInteractionSettingsState
    let threadgateAllow: [AppBskyDraftDefs.DraftThreadgateAllowUnion]?
    let postgateEmbeddingRules: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]?
  }
  private var restoredInteractionSnapshot: DraftInteractionSnapshot?
  
  // MARK: - Performance Optimization
  
  @available(iOS 16.0, macOS 13.0, *)
  private var _performanceOptimizer: PostComposerPerformanceOptimizer?
  
  @available(iOS 16.0, macOS 13.0, *)
  var performanceOptimizer: PostComposerPerformanceOptimizer? {
    if _performanceOptimizer == nil {
      _performanceOptimizer = PostComposerPerformanceOptimizer()
    }
    return _performanceOptimizer
  }
  
  // MARK: - Constants

  let maxImagesAllowed = 10
  /// Posts with more than this many images promote from app.bsky.embed.images
  /// to app.bsky.embed.gallery; at or below it the legacy images embed is kept
  /// so older clients can still render the post.
  let legacyImagesEmbedMax = 4
  let maxAltTextLength = 1000
  let maxCharacterCount = 300
  
  // MARK: - Computed Properties
  
  var canAddMoreMedia: Bool {
    return videoItem == nil && mediaItems.count < maxImagesAllowed
  }
  
  var hasVideo: Bool {
    return videoItem != nil
  }
  
  var currentThreadEntry: ThreadEntry {
    get {
      guard threadEntries.indices.contains(currentThreadIndex) else {
        return ThreadEntry()
      }
      return threadEntries[currentThreadIndex]
    }
    set {
      guard threadEntries.indices.contains(currentThreadIndex) else {
        return
      }
      threadEntries[currentThreadIndex] = newValue
    }
  }
  
  var canPost: Bool {
    return !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || 
           !mediaItems.isEmpty || 
           videoItem != nil || 
           selectedGif != nil
  }
  
  var remainingCharacters: Int {
    return maxCharacterCount - postText.count
  }
  
  var isOverCharacterLimit: Bool {
    return postText.count > maxCharacterCount
  }
  
  // MARK: - Submission State

  /// True while a post submission is in flight; guards against duplicate submits.
  private(set) var isSubmissionActive = false

  func beginSubmission() {
    submissionRecoveryDraft = ownsEditingDraft ? serializedDraftForCurrentContent() : nil
    self.isSubmissionActive = true
  }

  func endSubmission() {
    self.isSubmissionActive = false
    submissionRecoveryDraft = nil
  }

  // MARK: - Initialization
  
  init(
    parentPost: AppBskyFeedDefs.PostView? = nil,
    quotedPost: AppBskyFeedDefs.PostView? = nil,
    appState: AppState,
    editingSession: SceneComposerEditingSession? = nil
  ) {
    logger.info("PostComposerViewModel: Initializing - parentPost: \(parentPost != nil), quotedPost: \(quotedPost != nil)")
    self.parentPost = parentPost
    self.quotedPost = quotedPost
    self.appState = appState
    self.editingSession = editingSession

    loadDefaultInteractionSettings()
    if let client = appState.atProtoClient {
      self.mediaUploadManager = MediaUploadManager(client: client)
      logger.debug("PostComposerViewModel: MediaUploadManager initialized")
    } else {
      logger.warning("PostComposerViewModel: No atProtoClient available, MediaUploadManager not initialized")
    }
    
    self.richAttributedText = NSAttributedString(string: postText)
    
    // Initialize thread mode properly
    setupInitialState()
    
    // Initialize performance optimization
    if #available(iOS 16.0, macOS 13.0, *) {
      _ = performanceOptimizer // Initialize lazily
      logger.debug("PostComposerViewModel: Performance optimizer initialized")
    }
    
    logger.info("PostComposerViewModel: Initialization complete")
  }
  
  // MARK: - Auto-save Management
  
  /// Starts only the request explicitly supplied by the originating scene.
  /// A missing claim means a new editor, never an implicit resume.
  func startEditing(restoring draft: PostComposerDraft? = nil, claim: ComposerDraftClaim? = nil) throws {
    guard !Task.isCancelled, let editingSession, editingSession.accountDID == appState.userDID else {
      throw editingOwnershipError()
    }
    if let claim {
      guard claim.sceneID == editingSession.sceneID,
            claim.accountDID == editingSession.accountDID,
            editingSession.resume(claim: claim),
            editingSession.claimEditor(editingPresentationID, claim: claim),
            let snapshot = editingSession.snapshot(), snapshot.claim == claim else {
        throw editingOwnershipError()
      }
      // Lease takeover flushes the previous live editor before this read.
      editingClaim = claim
      restoreDraftState(snapshot.draft)
      cacheSerializedDraft(snapshot.draft)
    } else {
      if let draft { restoreDraftState(draft) }
      let body = serializedDraftForCurrentContent()
      let claim = try editingSession.beginNew(draft: body)
      guard editingSession.claimEditor(editingPresentationID, claim: claim) else { throw editingOwnershipError() }
      editingClaim = claim
      cacheSerializedDraft(body)
    }
    try registerLiveDraftProvider()
  }

  func restoreSavedDraft(_ draft: DraftPostViewModel) throws {
    guard let editingSession else { throw editingOwnershipError() }
    let claim = try editingSession.restoreSaved(draft)
    guard editingSession.claimEditor(editingPresentationID, claim: claim) else { throw editingOwnershipError() }
    editingClaim = claim
    guard let snapshot = editingSession.snapshot(), snapshot.claim == editingClaim else {
      throw editingOwnershipError()
    }
    restoreDraftState(snapshot.draft)
    cacheSerializedDraft(snapshot.draft)
    try registerLiveDraftProvider()
  }

  func replacementForSavedDraft(_ draft: DraftPostViewModel) throws -> PostComposerViewModel {
    guard captureEditingSnapshot() != nil else { throw editingOwnershipError() }
    let replacement = PostComposerViewModel(appState: appState, editingSession: editingSession)
    try replacement.restoreSavedDraft(draft)
    return replacement
  }

  @discardableResult
  func detachEditingDraftForTransfer(_ snapshot: ComposerEditingSnapshot) -> Bool {
    guard ownsEditingDraft, let editingSession, snapshot.claim == editingClaim else { return false }
    return editingSession.detachForTransfer(snapshot)
  }

  var ownsEditingDraft: Bool {
    guard let editingSession, let editingClaim else { return false }
    return editingSession.ownsEditor(editingPresentationID, claim: editingClaim)
      && editingClaim.accountDID == appState.userDID
  }

  /// Flushes the body and captures its ownership before any asynchronous work.
  func captureEditingSnapshot() -> ComposerEditingSnapshot? {
    guard !Task.isCancelled, let editingSession, let editingClaim, ownsEditingDraft,
          editingSession.update(serializedDraftForCurrentContent(), claim: editingClaim) else { return nil }
    return editingSession.snapshot()
  }

  private func cacheSerializedDraft(_ draft: PostComposerDraft) {
    serializedEditingContent = editingContent()
    serializedEditingDraft = draft
  }

  /// Keep identical media references when the editor body has not changed.
  private func serializedDraftForCurrentContent() -> PostComposerDraft {
    let content = editingContent()
    if content == serializedEditingContent, let draft = serializedEditingDraft { return draft }
    let draft = saveDraftState()
    serializedEditingContent = editingContent()
    serializedEditingDraft = draft
    return draft
  }

  private func registerLiveDraftProvider() throws {
    guard let editingSession, let claim = editingClaim,
          editingSession.registerLiveDraftProvider(
            editorID: editingPresentationID, claim: claim,
            provider: { [weak self] in
              // The session validates the exact lease before and after this
              // callback, including teardown from a cancelled lifecycle task.
              guard let self, self.editingClaim == claim else { return nil }
              if self.isSubmissionActive, let frozen = self.submissionRecoveryDraft {
                return frozen
              }
              return self.serializedDraftForCurrentContent()
            }
          ) else { throw editingOwnershipError() }
  }

  @discardableResult
  func unregisterLiveDraftProvider() -> Bool {
    guard let editingSession, let editingClaim else { return false }
    return editingSession.unregisterLiveDraftProvider(editorID: editingPresentationID, claim: editingClaim)
  }

  func saveDraftIfNeeded(claim expectedClaim: ComposerDraftClaim? = nil) {
    guard !Task.isCancelled, !isSubmissionActive,
          expectedClaim == nil || expectedClaim == editingClaim,
          ownsEditingDraft else { return }
    _ = captureEditingSnapshot()
  }

  var hasMeaningfulDraftContent: Bool {
    // SwiftUI reads this during layout. Inspect live state without serializing
    // media or writing the active thread entry back into observable state.
    if !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !mediaItems.isEmpty || videoItem != nil || selectedGif != nil
      || quotedPost != nil || !outlineTags.isEmpty || !selectedLabels.isEmpty
      || selectedEmbedURL != nil || !urlsKeptForEmbed.isEmpty || pendingAudioURL != nil {
      return true
    }
    return threadEntries.enumerated().contains { index, entry in
      if entry.draftQuotedPostURI != nil { return true }
      guard isThreadMode, index != currentThreadIndex else { return false }
      return !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !entry.mediaItems.isEmpty || entry.videoItem != nil || entry.selectedGif != nil
        || entry.quotedPost != nil || !entry.hashtags.isEmpty || !entry.outlineTags.isEmpty
        || entry.selectedEmbedURL != nil || !entry.urlsKeptForEmbed.isEmpty
    }
  }

  @discardableResult
  func minimizeEditingDraft() -> Bool {
    guard !isSubmissionActive, ownsEditingDraft, let editingSession,
          let editingClaim, captureEditingSnapshot() != nil,
          editingSession.minimize(claim: editingClaim) else { return false }
    if !ownsEditingDraft { clearAll() }
    return true
  }

  @discardableResult
  func discardEditingDraft() -> Bool {
    guard ownsEditingDraft, let editingSession, let editingClaim,
          editingSession.discard(claim: editingClaim) else { return false }
    clearAll()
    return true
  }

  @discardableResult
  func preserveRecordedAudio(at url: URL, claim: ComposerDraftClaim?, threadEntryID: UUID) -> Bool {
    guard ownsEditingDraft, editingClaim == claim, pendingAudioURL == nil,
          threadEntries.contains(where: { $0.id == threadEntryID }) else { return false }
    pendingAudioURL = url
    pendingAudioThreadEntryID = threadEntryID
    saveDraftIfNeeded()
    return true
  }

  func removePendingAudio() {
    guard ownsEditingDraft, !isPreparingPendingAudio else { return }
    // A saved row or another recovery envelope may still reference this file.
    pendingAudioURL = nil
    pendingAudioThreadEntryID = nil
    saveDraftIfNeeded()
  }

  @discardableResult
  func finishPendingAudio(
    withVideoAt videoURL: URL,
    audioURL: URL,
    claim: ComposerDraftClaim?,
    threadEntryID: UUID,
    prepareVideo: (@MainActor (URL) async throws -> PreparedPendingAudioVideo)? = nil
  ) async throws -> Bool {
    guard !Task.isCancelled, !isPreparingPendingAudio, ownsEditingDraft, editingClaim == claim,
          pendingAudioURL == audioURL, pendingAudioThreadEntryID == threadEntryID,
          threadEntries.contains(where: { $0.id == threadEntryID }) else { return false }
    // Includes live media identities and the active entry. No draft writes occur while staging.
    let originalContent = editingContent()
    isPreparingPendingAudio = true
    defer { isPreparingPendingAudio = false }

    let prepared: PreparedPendingAudioVideo
    if let prepareVideo {
      prepared = try await prepareVideo(videoURL)
    } else {
      prepared = try await preparePendingAudioVideo(videoURL)
    }
    var committed = false
    defer { if !committed { prepared.discard() } }
    guard !Task.isCancelled, ownsEditingDraft, editingClaim == claim,
          pendingAudioURL == audioURL, pendingAudioThreadEntryID == threadEntryID,
          editingContent() == originalContent,
          let index = threadEntries.firstIndex(where: { $0.id == threadEntryID }) else { return false }

    // One synchronous publication to the recording's original post, even when another is selected.
    threadEntries[index].mediaItems = []
    threadEntries[index].selectedGif = nil
    threadEntries[index].videoItem = prepared.item
    if index == currentThreadIndex {
      mediaItems = []
      selectedGif = nil
      videoItem = prepared.item
      videoUploadBlockedReason = prepared.blockedReason
      videoUploadBlockedCode = prepared.blockedCode
    }
    pendingAudioURL = nil
    pendingAudioThreadEntryID = nil
    saveDraftIfNeeded()
    committed = true
    return true
  }

  /// This comparison has no file writes, unlike the persisted media wrappers.
  struct EditingContent: Equatable {
    struct Media: Equatable {
      let id: UUID
      let data: Data?
      let videoData: Data?
      let videoURL: URL?
      let imageURL: URL?
      let altText: String
      let aspectRatio: CGSize?
      let isLoading: Bool
      let isAudioVisualizerVideo: Bool
      let isGifConversion: Bool
      let caption: VideoCaption?

      init(_ item: MediaItem) {
        id = item.id
        data = item.rawData
        videoData = item.videoData
        videoURL = item.rawVideoURL
        imageURL = item.rawImageURL
        altText = item.altText
        aspectRatio = item.aspectRatio
        isLoading = item.isLoading
        isAudioVisualizerVideo = item.isAudioVisualizerVideo
        isGifConversion = item.isGifConversion
        caption = item.caption
      }
    }

    let text: String
    let media: [Media]
    let video: Media?
    let gif: TenorGif?
    let languages: [LanguageCodeContainer]
    let labels: Set<ComAtprotoLabelDefs.LabelValue>
    let tags: [String]
    let threadEntries: [ThreadEntry]
    let threadMedia: [[Media]]
    let threadVideos: [Media?]
    let isThreadMode: Bool
    let currentThreadIndex: Int
    let parentURI: String?
    let quotedURI: String?
    let interactionSettings: PostInteractionSettingsState
    let pendingAudioURL: URL?
    let pendingAudioThreadEntryID: UUID?
    let detectedURLs: [String]
    let urlCards: [String: URLCardResponse]
    let selectedEmbedURL: String?
    let urlsKeptForEmbed: Set<String>
  }

  func editingContent() -> EditingContent {
    EditingContent(
      text: postText, media: mediaItems.map(EditingContent.Media.init),
      video: videoItem.map(EditingContent.Media.init), gif: selectedGif,
      languages: selectedLanguages, labels: selectedLabels, tags: outlineTags,
      threadEntries: threadEntries,
      threadMedia: threadEntries.map { $0.mediaItems.map(EditingContent.Media.init) },
      threadVideos: threadEntries.map { $0.videoItem.map(EditingContent.Media.init) },
      isThreadMode: isThreadMode, currentThreadIndex: currentThreadIndex,
      parentURI: parentPost?.uri.uriString() ?? pendingParentPostURI,
      quotedURI: quotedPost?.uri.uriString(), interactionSettings: interactionSettings,
      pendingAudioURL: pendingAudioURL, pendingAudioThreadEntryID: pendingAudioThreadEntryID,
      detectedURLs: detectedURLs, urlCards: urlCards,
      selectedEmbedURL: selectedEmbedURL, urlsKeptForEmbed: urlsKeptForEmbed
    )
  }

  @discardableResult
  func completeEditingSubmission(_ snapshot: ComposerEditingSnapshot?, content: EditingContent) -> Bool {
    guard let editingSession else { return true }
    guard ownsEditingDraft, let snapshot, snapshot.claim == editingClaim,
          content == editingContent() else { return false }
    return editingSession.completeSubmission(snapshot)
  }

  func editingOwnershipError() -> NSError {
    NSError(domain: "ComposerEditingSession", code: 1, userInfo: [
      NSLocalizedDescriptionKey: "This draft is no longer open in this window."
    ])
  }

  struct MediaLoadContext: Sendable {
    let generation: UUID
    let claim: ComposerDraftClaim?
    let accountDID: String?
    let entryID: UUID?
  }

  func mediaLoadContext() -> MediaLoadContext {
    MediaLoadContext(
      generation: draftRestorationGeneration, claim: editingClaim, accountDID: appState.userDID,
      entryID: threadEntries.indices.contains(currentThreadIndex) ? threadEntries[currentThreadIndex].id : nil
    )
  }

  private func ownsMediaLoadDraft(_ context: MediaLoadContext) -> Bool {
    context.generation == draftRestorationGeneration && context.claim == editingClaim
      && context.accountDID == appState.userDID
      && (editingSession == nil || ownsEditingDraft)
  }

  func ownsMediaLoad(_ context: MediaLoadContext) -> Bool {
    ownsMediaLoadDraft(context)
      && context.entryID == (threadEntries.indices.contains(currentThreadIndex) ? threadEntries[currentThreadIndex].id : nil)
  }

  /// A task that finishes offscreen must not leave a stored thread attachment spinning.
  func finishMediaLoad(withId id: UUID, context: MediaLoadContext) {
    guard ownsMediaLoadDraft(context) else { return }
    if ownsMediaLoad(context) {
      if videoItem?.id == id { videoItem?.isLoading = false }
      if let index = mediaItems.firstIndex(where: { $0.id == id }) {
        mediaItems[index].isLoading = false
      }
      syncMediaStateToCurrentThread()
    }
    if let index = threadEntries.firstIndex(where: { $0.id == context.entryID }) {
      if threadEntries[index].videoItem?.id == id { threadEntries[index].videoItem?.isLoading = false }
      if let mediaIndex = threadEntries[index].mediaItems.firstIndex(where: { $0.id == id }) {
        threadEntries[index].mediaItems[mediaIndex].isLoading = false
      }
    }
  }

  // MARK: - Video Upload Eligibility
  func checkVideoUploadEligibility(force: Bool = false) async {
    guard let videoID = videoItem?.id, let manager = mediaUploadManager else { 
      logger.trace("PostComposerViewModel: checkVideoUploadEligibility - no video or manager")
      return 
    }
    logger.info("PostComposerViewModel: Checking video upload eligibility - force: \(force)")
    let context = mediaLoadContext()
    if let owner = videoUploadOwner(for: videoID),
       let store = try? VideoUploadCheckpointStore.shared.get(),
       let saved = try? await store.load(owner: owner),
       [.uploading, .finishing, .processing, .complete].contains(saved.phase)
         || (saved.phase == .abandoned && saved.uploadJobID != nil) {
      guard !Task.isCancelled, videoItem?.id == videoID, ownsMediaLoad(context) else { return }
      // An existing reservation/job can be resumed even when no new upload allowance remains.
      // Submission still verifies the exact owner/file and asks the server for authoritative state.
      videoUploadBlockedReason = nil
      videoUploadBlockedCode = nil
      return
    }
    let result = await manager.preflightUploadPermission(force: force)
    guard !Task.isCancelled, videoItem?.id == videoID, ownsMediaLoad(context) else { return }
    if result.allowed {
      logger.info("PostComposerViewModel: Video upload allowed")
      self.videoUploadBlockedReason = nil
      self.videoUploadBlockedCode = nil
    } else {
      logger.warning("PostComposerViewModel: Video upload blocked - code: \(result.code ?? "none"), message: \(result.message ?? "none")")
      self.videoUploadBlockedReason = result.message ?? "Video uploads are currently unavailable"
      self.videoUploadBlockedCode = result.code
    }
  }

  // MARK: - Email Verification
  func resendVerificationEmail() async {
    guard let manager = mediaUploadManager else { 
      logger.warning("PostComposerViewModel: resendVerificationEmail - no mediaUploadManager")
      return 
    }
    logger.info("PostComposerViewModel: Requesting email verification")
    do {
      try await manager.requestEmailConfirmation()
      logger.info("PostComposerViewModel: Email verification request successful")
      await MainActor.run {
        self.videoUploadBlockedReason = "Verification email sent. Check your inbox."
        self.videoUploadBlockedCode = nil
      }
      // Optionally trigger a forced re-check after a short delay (user may confirm quickly)
      try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
      logger.debug("PostComposerViewModel: Re-checking video upload permission after email sent")
      _ = await manager.preflightUploadPermission(force: true)
    } catch {
      logger.error("PostComposerViewModel: Failed to send verification email - error: \(error.localizedDescription)")
      await MainActor.run {
        self.videoUploadBlockedReason = "Failed to send verification email. Please try again."
      }
    }
  }

  // MARK: - Manual Link Facets Update
  func updateManualLinkFacets(from linkFacets: [RichTextFacetUtils.LinkFacet]) {
    manualLinkFacets = RichTextFacetUtils.createFacets(from: linkFacets, in: postText)
    logger.debug("PostComposerVM: Updated manualLinkFacets to \(self.manualLinkFacets.count) facets from \(linkFacets.count) linkFacets, postText length: \(self.postText.count)")
  }
  
  // MARK: - Initialization and State Management
  
  private func setupInitialState() {
    logger.debug("PostComposerViewModel: Setting up initial state")
    // Ensure thread entries are properly initialized
    if threadEntries.isEmpty {
      threadEntries = [ThreadEntry()]
      logger.debug("PostComposerViewModel: Initialized thread entries array")
    }
    currentThreadIndex = 0
    
    // Set up reply context if this is a reply
    if parentPost != nil {
      replyTo = parentPost
      logger.debug("PostComposerViewModel: Set up reply context")
    }
  }
  
  func enterDraftMode() {
    logger.debug("PostComposerViewModel: Entering draft mode")
    isDraftMode = true
  }
  
  func exitDraftMode() {
    logger.debug("PostComposerViewModel: Exiting draft mode")
    isDraftMode = false
    updatePostContent()
  }
  
  func saveDraftState() -> PostComposerDraft {
    updateCurrentThreadEntry()
    let rootQuote = isThreadMode && currentThreadIndex != 0 ? threadEntries.first?.quotedPost : quotedPost
    let rootQuoteURI = threadEntries.first?.draftQuotedPostURI ?? rootQuote?.uri.uriString()
    let rootQuoteCID = threadEntries.first?.draftQuotedPostCID ?? rootQuote?.cid.string
    let rules = effectiveDraftInteractionRules()
    return PostComposerDraft(
      postText: postText,
      mediaItems: mediaItems.map(CodableMediaItem.init),
      videoItem: videoItem.map(CodableMediaItem.init),
      selectedGif: selectedGif,
      selectedLanguages: selectedLanguages,
      selectedLabels: selectedLabels,
      outlineTags: outlineTags,
      threadEntries: threadEntries.enumerated().map { index, entry in
        CodableThreadEntry(from: entry, parentPost: index == 0 ? parentPost : nil,
                           quotedPost: index == 0 ? rootQuote : nil,
                           parentPostURI: index == 0 ? pendingParentPostURI : nil)
      },
      isThreadMode: isThreadMode,
      currentThreadIndex: currentThreadIndex,
      parentPostURI: parentPost?.uri.uriString() ?? pendingParentPostURI,
      quotedPostURI: rootQuoteURI,
      quotedPostCID: rootQuoteCID,
      draftPostgateEmbeddingRules: rules.postgate,
      draftThreadgateAllow: rules.threadgate,
      hasDraftInteractionSettings: true,
      pendingAudioURLString: pendingAudioURL?.absoluteString,
      pendingAudioThreadEntryID: pendingAudioThreadEntryID
    )
  }
  
  func clearAll() {
    logger.info("PostComposerViewModel: Clearing all composer state")
    isUpdatingText = true
    defer { isUpdatingText = false }
    invalidateDraftRestoration()
    parentPost = nil
    replyTo = nil
    quotedPost = nil
    pendingParentPostURI = nil
    restoredInteractionSnapshot = nil
    
    postText = ""
    richAttributedText = NSAttributedString()
    attributedPostText = AttributedString()
    mediaItems = []
    videoItem = nil
    pendingAudioURL = nil
    pendingAudioThreadEntryID = nil
    selectedGif = nil
    selectedLanguages = []
    selectedLabels = []
    outlineTags = []
    threadEntries = [ThreadEntry()]
    currentThreadIndex = 0
    isThreadMode = false
    detectedURLs = []
    urlCards = [:]
    selectedEmbedURL = nil
    urlsKeptForEmbed = []
    mentionSuggestions = []
    loadDefaultInteractionSettings()
    
    logger.debug("PostComposerViewModel: All state cleared")
  }
  
  func restoreDraftState(_ draft: PostComposerDraft) {
    logger.info("PostComposerViewModel: Restoring draft state - text length: \(draft.postText.count), media: \(draft.mediaItems.count), video: \(draft.videoItem != nil), gif: \(draft.selectedGif != nil)")
    isUpdatingText = true
    isDraftMode = true
    invalidateDraftRestoration()

    defer {
      isUpdatingText = false
      isDraftMode = false
      logger.debug("PostComposerViewModel: Draft restoration complete")
    }

    postText = draft.postText
    mediaItems = draft.mediaItems.map { $0.toMediaItem() }
    videoItem = draft.videoItem?.toMediaItem()
    pendingAudioURL = draft.pendingAudioURLString.flatMap(URL.init(string:))
    pendingAudioThreadEntryID = pendingAudioURL == nil ? nil : draft.pendingAudioThreadEntryID
    selectedGif = draft.selectedGif
    selectedLanguages = draft.selectedLanguages
    selectedLabels = draft.selectedLabels
    outlineTags = draft.outlineTags
    threadEntries = draft.threadEntries.map { $0.toThreadEntry() }
    if threadEntries.isEmpty { threadEntries = [ThreadEntry()] }
    isThreadMode = draft.isThreadMode
    currentThreadIndex = min(max(0, draft.currentThreadIndex), threadEntries.count - 1)
    detectedURLs = threadEntries[currentThreadIndex].detectedURLs
    urlCards = threadEntries[currentThreadIndex].urlCards
    selectedEmbedURL = threadEntries[currentThreadIndex].selectedEmbedURL
    urlsKeptForEmbed = threadEntries[currentThreadIndex].urlsKeptForEmbed
    parentPost = nil
    replyTo = nil
    quotedPost = nil
    pendingParentPostURI = draft.parentPostURI
    if threadEntries[0].draftQuotedPostURI == nil {
      threadEntries[0].draftQuotedPostURI = draft.quotedPostURI
      threadEntries[0].draftQuotedPostCID = draft.quotedPostCID
    }
    restoredInteractionSnapshot = nil
    if draft.hasDraftInteractionSettings == true || draft.draftThreadgateAllow != nil || draft.draftPostgateEmbeddingRules != nil {
      interactionSettings = Self.interactionSettings(fromDraft: draft)
      restoredInteractionSnapshot = DraftInteractionSnapshot(
        settings: interactionSettings,
        threadgateAllow: draft.draftThreadgateAllow,
        postgateEmbeddingRules: draft.draftPostgateEmbeddingRules
      )
    } else {
      loadDefaultInteractionSettings()
    }
    
      logger.debug("PostComposerViewModel: Draft state restored - isThreadMode: \(self.isThreadMode), threadEntries: \(self.threadEntries.count), currentIndex: \(self.currentThreadIndex)")

    richAttributedText = NSAttributedString(string: postText)
    updatePostContent()

    // Retain strong refs before fetching display metadata, so autosave is lossless.
    if let parentURI = draft.parentPostURI {
      parentRestorationTask = restorePostFromURI(parentURI, entryID: nil)
      parentRestoreFailed = parentRestorationTask == nil
    }
    for entry in threadEntries {
      if let quotedURI = entry.draftQuotedPostURI {
        quoteRestorationTasks[entry.id] = restorePostFromURI(quotedURI, entryID: entry.id)
      }
    }

    // If the restored draft contains a video URL but no thumbnail yet, generate it now
    if let restoredVideo = videoItem, restoredVideo.image == nil, restoredVideo.rawVideoURL != nil {
      logger.debug("PostComposerViewModel: Loading video thumbnail for restored draft")
      var loadingVideo = restoredVideo
      loadingVideo.isLoading = true
      videoItem = loadingVideo
      Task { await loadVideoThumbnail(for: loadingVideo) }
    }
    // Also preflight eligibility when restoring draft with a video
    if videoItem != nil {
      logger.debug("PostComposerViewModel: Checking video upload eligibility for restored draft")
      Task { await checkVideoUploadEligibility() }
    }
  }

  private func invalidateDraftRestoration() {
    draftRestorationGeneration = UUID()
    parentRestoreFailed = false
    parentRestorationTask?.cancel()
    parentRestorationTask = nil
    quoteRestorationTasks.values.forEach { $0.cancel() }
    quoteRestorationTasks.removeAll()
    interactionDefaultsTask?.cancel()
    interactionDefaultsTask = nil
  }

  private func loadDefaultInteractionSettings() {
    interactionDefaultsTask?.cancel()
    let preferences = appState.preferencesManager
    if let pref = preferences.cachedPostInteractionSettingsPref() {
      interactionSettings = Self.interactionSettings(from: pref)
      return
    }
    interactionSettings = PostInteractionSettingsState()
    let generation = draftRestorationGeneration
    let revision = interactionSettingsRevision
    let accountDID = appState.userDID
    let activeAccountDID = AppStateManager.shared.lifecycle.userDID
    interactionDefaultsTask = Task { [weak self] in
      guard let pref = try? await preferences.getPostInteractionSettingsPref(),
            !Task.isCancelled, let self,
            self.appState.userDID == accountDID,
            AppStateManager.shared.lifecycle.userDID == activeAccountDID,
            self.draftRestorationGeneration == generation,
            self.interactionSettingsRevision == revision,
            self.restoredInteractionSnapshot == nil else { return }
      self.interactionSettings = Self.interactionSettings(from: pref)
    }
  }

  /// Fetch display metadata without replacing a removed or superseded strong reference.
  private func restorePostFromURI(_ uriString: String, entryID: UUID?) -> Task<Void, Never>? {
    guard let client = appState.atProtoClient else { return nil }
    let generation = draftRestorationGeneration
    let accountDID = appState.userDID
    let activeAccountDID = AppStateManager.shared.lifecycle.userDID
    guard activeAccountDID == nil || activeAccountDID == accountDID else { return nil }
    return Task { [weak self] in
      do {
        let uri = try ATProtocolURI(uriString: uriString)
        let params = AppBskyFeedGetPosts.Parameters(uris: [uri])
        let (responseCode, response) = try await client.app.bsky.feed.getPosts(input: params)
        guard !Task.isCancelled, let self,
              self.draftRestorationGeneration == generation,
              self.appState.userDID == accountDID,
              AppStateManager.shared.lifecycle.userDID == activeAccountDID,
              self.appState.atProtoClient === client else { return }
        guard (200..<300).contains(responseCode),
              let post = response?.posts.first(where: { $0.uri.uriString() == uriString }) else {
          self.logger.error("Draft post unavailable - response code: \(responseCode)")
          self.markParentRestoreFailed(uriString, entryID: entryID)
          return
        }
        if let entryID {
          guard let index = self.threadEntries.firstIndex(where: { $0.id == entryID }),
                self.threadEntries[index].draftQuotedPostURI == uriString else { return }
          self.threadEntries[index].quotedPost = post
          // Keep the saved CID stable; hydration is only for display metadata.
          if self.threadEntries[index].draftQuotedPostCID.flatMap({ try? CID.parse($0) }) == nil {
            self.threadEntries[index].draftQuotedPostCID = post.cid.string
          }
          self.quoteRestorationTasks[entryID] = nil
          if index == self.currentThreadIndex {
            let wasUpdatingText = self.isUpdatingText
            self.isUpdatingText = true
            self.quotedPost = post
            self.isUpdatingText = wasUpdatingText
          }
        } else {
          guard self.pendingParentPostURI == uriString else { return }
          self.parentRestorationTask = nil
          self.parentPost = post
          self.replyTo = post
        }
      } catch {
        guard !Task.isCancelled, let self else { return }
        self.logger.error("Failed to restore draft post: \(error.localizedDescription)")
        guard self.draftRestorationGeneration == generation else { return }
        self.markParentRestoreFailed(uriString, entryID: entryID)
      }
    }
  }

  private func markParentRestoreFailed(_ uriString: String, entryID: UUID?) {
    guard entryID == nil, pendingParentPostURI == uriString, parentPost == nil else { return }
    parentRestorationTask = nil
    parentRestoreFailed = true
  }

  /// Tries again to load the original post of a restored reply draft.
  func retryParentRestore() {
    guard let uriString = pendingParentPostURI, parentPost == nil else { return }
    parentRestorationTask?.cancel()
    parentRestoreFailed = false
    parentRestorationTask = restorePostFromURI(uriString, entryID: nil)
    parentRestoreFailed = parentRestorationTask == nil
  }

  /// Turns a reply draft whose original post is unavailable into a new top-level post.
  func detachUnavailableParent() {
    guard parentPost == nil, pendingParentPostURI != nil else { return }
    parentRestorationTask?.cancel()
    parentRestorationTask = nil
    pendingParentPostURI = nil
    parentRestoreFailed = false
    saveDraftIfNeeded()
  }

  isolated deinit {
    if let editingClaim {
      _ = editingSession?.unregisterLiveDraftProvider(editorID: editingPresentationID, claim: editingClaim)
      _ = editingSession?.releaseEditor(editingPresentationID, claim: editingClaim)
    }
    parentRestorationTask?.cancel()
    quoteRestorationTasks.values.forEach { $0.cancel() }
    interactionDefaultsTask?.cancel()
  }

  // MARK: - Post Interaction Settings Helper (G40)

  /// A quote can be published from its strong reference even if its preview is unavailable.
  func postingQuoteReference(for entry: ThreadEntry? = nil) -> ComAtprotoRepoStrongRef? {
    let source = entry ?? (threadEntries.indices.contains(currentThreadIndex) ? threadEntries[currentThreadIndex] : nil)
    if let uriString = source?.draftQuotedPostURI,
       let cidString = source?.draftQuotedPostCID,
       let uri = try? ATProtocolURI(uriString: uriString),
       let cid = try? CID.parse(cidString) {
      return .init(uri: uri, cid: cid)
    }
    let post = entry == nil ? quotedPost : entry?.quotedPost
    return post.map { .init(uri: $0.uri, cid: $0.cid) }
  }

  var draftReferenceLoadingReason: PostComposerSubmitValidationState.Reason? {
    if pendingAudioURL != nil { return .pendingAudio }
    if pendingParentPostURI != nil && parentPost == nil { return parentRestoreFailed ? .replyUnavailable : .replyLoading }
    let entries = isThreadMode ? threadEntries : Array(threadEntries.prefix(1))
    if entries.contains(where: { $0.draftQuotedPostURI != nil && postingQuoteReference(for: $0) == nil }) {
      return .quoteLoading
    }
    return nil
  }

  var isReply: Bool {
    parentPost != nil || pendingParentPostURI != nil
  }

  func ensureDraftReferencesReadyForPosting() throws {
    guard let reason = draftReferenceLoadingReason else { return }
    let validation = PostComposerSubmitValidationState(canSubmit: false, reason: reason)
    throw NSError(domain: "PostError", code: 0, userInfo: [NSLocalizedDescriptionKey: validation.message ?? "The saved post must load before posting."])
  }

  private func effectiveDraftInteractionRules() -> (
    threadgate: [AppBskyDraftDefs.DraftThreadgateAllowUnion]?,
    postgate: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]?
  ) {
    let current = Self.draftInteractionRules(from: interactionSettings)
    guard let restored = restoredInteractionSnapshot else { return current }
    // Preserve unsupported rules, and nil versus [], until that control is edited.
    return (
      restored.settings.threadgate == interactionSettings.threadgate ? restored.threadgateAllow : current.threadgate,
      restored.settings.allowQuotes == interactionSettings.allowQuotes ? restored.postgateEmbeddingRules : current.postgate
    )
  }

  func postingThreadgateRules() -> [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]? {
    // Bluesky only honors reply settings on the thread's root post.
    guard !isReply else { return nil }
    return effectiveDraftInteractionRules().threadgate?.map { rule in
      switch rule {
      case .appBskyFeedThreadgateMentionRule(let value): return .appBskyFeedThreadgateMentionRule(value)
      case .appBskyFeedThreadgateFollowerRule(let value): return .appBskyFeedThreadgateFollowerRule(value)
      case .appBskyFeedThreadgateFollowingRule(let value): return .appBskyFeedThreadgateFollowingRule(value)
      case .appBskyFeedThreadgateListRule(let value): return .appBskyFeedThreadgateListRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
  }

  func postingPostgateRules() -> [AppBskyFeedPostgate.AppBskyFeedPostgateEmbeddingRulesUnion]? {
    effectiveDraftInteractionRules().postgate?.map { rule in
      switch rule {
      case .appBskyFeedPostgateDisableRule(let value): return .appBskyFeedPostgateDisableRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
  }

  private static func draftInteractionRules(from settings: PostInteractionSettingsState) -> (
    threadgate: [AppBskyDraftDefs.DraftThreadgateAllowUnion]?,
    postgate: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]?
  ) {
    let threadgate = settings.toThreadgateAllowRules()?.map { rule -> AppBskyDraftDefs.DraftThreadgateAllowUnion in
      switch rule {
      case .appBskyFeedThreadgateMentionRule(let value): return .appBskyFeedThreadgateMentionRule(value)
      case .appBskyFeedThreadgateFollowerRule(let value): return .appBskyFeedThreadgateFollowerRule(value)
      case .appBskyFeedThreadgateFollowingRule(let value): return .appBskyFeedThreadgateFollowingRule(value)
      case .appBskyFeedThreadgateListRule(let value): return .appBskyFeedThreadgateListRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
    let postgate = settings.toPostgateEmbeddingRules()?.map { rule -> AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion in
      switch rule {
      case .appBskyFeedPostgateDisableRule(let value): return .appBskyFeedPostgateDisableRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
    return (threadgate, postgate)
  }

  static func interactionSettings(fromDraft draft: PostComposerDraft) -> PostInteractionSettingsState {
    let threadgate = draft.draftThreadgateAllow?.map { rule -> AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion in
      switch rule {
      case .appBskyFeedThreadgateMentionRule(let value): return .appBskyFeedThreadgateMentionRule(value)
      case .appBskyFeedThreadgateFollowerRule(let value): return .appBskyFeedThreadgateFollowerRule(value)
      case .appBskyFeedThreadgateFollowingRule(let value): return .appBskyFeedThreadgateFollowingRule(value)
      case .appBskyFeedThreadgateListRule(let value): return .appBskyFeedThreadgateListRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
    let postgate = draft.draftPostgateEmbeddingRules?.map { rule -> AppBskyActorDefs.PostInteractionSettingsPrefPostgateEmbeddingRulesUnion in
      switch rule {
      case .appBskyFeedPostgateDisableRule(let value): return .appBskyFeedPostgateDisableRule(value)
      case .unexpected(let value): return .unexpected(value)
      }
    }
    return interactionSettings(from: .init(threadgateAllowRules: threadgate, postgateEmbeddingRules: postgate))
  }

  static func interactionSettings(from pref: AppBskyActorDefs.PostInteractionSettingsPref?) -> PostInteractionSettingsState {
    guard let pref = pref else {
      return PostInteractionSettingsState()
    }
    
    var threadgate = ThreadgateSettings()
    if let rules = pref.threadgateAllowRules {
      if rules.isEmpty {
        threadgate.allowEverybody = false
        threadgate.allowNobody = true
        threadgate.allowMentioned = false
        threadgate.allowFollowing = false
        threadgate.allowFollowers = false
        threadgate.allowLists = false
        threadgate.selectedLists = []
      } else {
        threadgate.allowEverybody = false
        threadgate.allowNobody = false
        var allowMentioned = false
        var allowFollowing = false
        var allowFollowers = false
        var allowLists = false
        var selectedLists: [String] = []
        
        for rule in rules {
          switch rule {
          case .appBskyFeedThreadgateMentionRule:
            allowMentioned = true
          case .appBskyFeedThreadgateFollowingRule:
            allowFollowing = true
          case .appBskyFeedThreadgateFollowerRule:
            allowFollowers = true
          case .appBskyFeedThreadgateListRule(let listRule):
            allowLists = true
            selectedLists.append(listRule.list.uriString())
          case .unexpected:
            break
          }
        }
        threadgate.allowMentioned = allowMentioned
        threadgate.allowFollowing = allowFollowing
        threadgate.allowFollowers = allowFollowers
        threadgate.allowLists = allowLists
        threadgate.selectedLists = selectedLists
      }
    } else {
      threadgate.allowEverybody = true
    }
    
    var allowQuotes = true
    if let postgateRules = pref.postgateEmbeddingRules,
       postgateRules.contains(where: {
         if case .appBskyFeedPostgateDisableRule = $0 { return true }
         return false
       }) {
      allowQuotes = false
    }
    
    return PostInteractionSettingsState(threadgate: threadgate, allowQuotes: allowQuotes)
  }
  
  // MARK: - Media Item Model
  
  struct MediaItem: Identifiable {
    let id: UUID
    var pickerItem: PhotosPickerItem?
    var image: Image?
    var isLoading: Bool = true
    var altText: String = ""
    var aspectRatio: CGSize?
    var rawData: Data?
    var rawImageURL: URL?
    var videoData: Data?
    var rawVideoURL: URL?
    var rawVideoAsset: AVAsset?
    var isAudioVisualizerVideo: Bool = false
    var isGifConversion: Bool = false
    var caption: VideoCaption? = nil

    var canRetryLoading: Bool {
      rawData != nil || pickerItem != nil || rawImageURL != nil || rawVideoURL != nil
    }
    
    init(pickerItem: PhotosPickerItem) {
      self.id = UUID()
      self.pickerItem = pickerItem
    }
    
    init(id: UUID = UUID()) {
      self.id = id
      self.pickerItem = nil
    }
    
    init(url: URL, isAudioVisualizerVideo: Bool = false) {
      self.id = UUID()
      self.pickerItem = nil
      self.rawVideoURL = url
      self.isAudioVisualizerVideo = isAudioVisualizerVideo
      self.rawVideoAsset = AVURLAsset(url: url)
    }
  }
}

// MARK: - MediaItem Hashable Conformance

extension PostComposerViewModel.MediaItem: Hashable {
    static func == (lhs: PostComposerViewModel.MediaItem, rhs: PostComposerViewModel.MediaItem) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

  // MARK: - Media Source Tracking
  
  enum MediaSource {
    case photoPicker(String)
    case pastedImage(Data)
    case gifConversion(String)
    case genmojiConversion(Data)
  }
