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
  
  var parentPost: AppBskyFeedDefs.PostView?
  var quotedPost: AppBskyFeedDefs.PostView?
  var replyTo: AppBskyFeedDefs.PostView?
  
  // MARK: - Media Properties
  
  var mediaItems: [MediaItem] = []
  var videoItem: MediaItem?
  var currentEditingMediaId: UUID?
  var isAltTextEditorPresented = false
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
  var resolvedProfiles: [String: AppBskyActorDefs.ProfileViewBasic] = [:]
  var cursorPosition: Int = 0
  
  // MARK: - Manual Link Facets (legacy inline links)
  /// Facets derived from inline link attributes when using legacy NSAttributedString path.
  /// These are merged into the facets used for posting so inline links survive even when
  /// the visible text does not contain the raw URL.
  var manualLinkFacets: [AppBskyRichtextFacet] = []

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
  var threadgateSettings: ThreadgateSettings = ThreadgateSettings()
  
  // MARK: - Private Properties
  
  let appState: AppState
  
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
  
  let maxImagesAllowed = 4
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
    return 300 - postText.count
  }
  
  var isOverCharacterLimit: Bool {
    return postText.count > 300
  }
  
  // MARK: - Initialization
  
  init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
    self.parentPost = parentPost
    self.quotedPost = quotedPost
    self.appState = appState
    
    if let client = appState.atProtoClient {
      self.mediaUploadManager = MediaUploadManager(client: client)
    }
    
    self.richAttributedText = NSAttributedString(string: postText)
    
    // Initialize thread mode properly
    setupInitialState()
    
    // Initialize performance optimization
    if #available(iOS 16.0, macOS 13.0, *) {
      _ = performanceOptimizer // Initialize lazily
    }
  }

  // MARK: - Video Upload Eligibility
  func checkVideoUploadEligibility(force: Bool = false) async {
    guard videoItem != nil, let manager = mediaUploadManager else { return }
    let result = await manager.preflightUploadPermission(force: force)
    await MainActor.run {
      if result.allowed {
        self.videoUploadBlockedReason = nil
        self.videoUploadBlockedCode = nil
      } else {
        self.videoUploadBlockedReason = result.message ?? "Video uploads are currently unavailable"
        self.videoUploadBlockedCode = result.code
      }
    }
  }

  // MARK: - Email Verification
  func resendVerificationEmail() async {
    guard let manager = mediaUploadManager else { return }
    do {
      try await manager.requestEmailConfirmation()
      await MainActor.run {
        self.videoUploadBlockedReason = "Verification email sent. Check your inbox."
        self.videoUploadBlockedCode = nil
      }
      // Optionally trigger a forced re-check after a short delay (user may confirm quickly)
      try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
      _ = await manager.preflightUploadPermission(force: true)
    } catch {
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
    // Ensure thread entries are properly initialized
    if threadEntries.isEmpty {
      threadEntries = [ThreadEntry()]
    }
    currentThreadIndex = 0
    
    // Set up reply context if this is a reply
    if parentPost != nil {
      replyTo = parentPost
    }
  }
  
  func enterDraftMode() {
    isDraftMode = true
  }
  
  func exitDraftMode() {
    isDraftMode = false
    updatePostContent()
  }
  
  func saveDraftState() -> PostComposerDraft {
    return PostComposerDraft(
      postText: postText,
      mediaItems: mediaItems.map(CodableMediaItem.init),
      videoItem: videoItem.map(CodableMediaItem.init),
      selectedGif: selectedGif,
      selectedLanguages: selectedLanguages,
      selectedLabels: selectedLabels,
      outlineTags: outlineTags,
      threadEntries: threadEntries.map { CodableThreadEntry(from: $0, parentPost: parentPost, quotedPost: quotedPost) },
      isThreadMode: isThreadMode,
      currentThreadIndex: currentThreadIndex,
      parentPostURI: parentPost?.uri.uriString(),
      quotedPostURI: quotedPost?.uri.uriString()
    )
  }
  
  func restoreDraftState(_ draft: PostComposerDraft) {
    isUpdatingText = true
    isDraftMode = true

    defer {
      isUpdatingText = false
      isDraftMode = false
    }

    postText = draft.postText
    mediaItems = draft.mediaItems.map { $0.toMediaItem() }
    videoItem = draft.videoItem?.toMediaItem()
    selectedGif = draft.selectedGif
    selectedLanguages = draft.selectedLanguages
    selectedLabels = draft.selectedLabels
    outlineTags = draft.outlineTags
    threadEntries = draft.threadEntries.map { $0.toThreadEntry() }
    isThreadMode = draft.isThreadMode
    currentThreadIndex = draft.currentThreadIndex

    richAttributedText = NSAttributedString(string: postText)
    updatePostContent()

    // Restore parent and quoted post references from URIs
    if let parentURI = draft.parentPostURI {
      Task {
        await restorePostFromURI(parentURI, isParent: true)
      }
    }
    if let quotedURI = draft.quotedPostURI {
      Task {
        await restorePostFromURI(quotedURI, isParent: false)
      }
    }

    // If the restored draft contains a video URL but no thumbnail yet, generate it now
    if let restoredVideo = videoItem, restoredVideo.image == nil, restoredVideo.rawVideoURL != nil {
      var loadingVideo = restoredVideo
      loadingVideo.isLoading = true
      videoItem = loadingVideo
      Task { await loadVideoThumbnail(for: loadingVideo) }
    }
    // Also preflight eligibility when restoring draft with a video
    Task { await checkVideoUploadEligibility() }
  }

  /// Fetch and restore a post from its URI
  private func restorePostFromURI(_ uriString: String, isParent: Bool) async {
    guard let client = appState.atProtoClient else { return }

    do {
        let uri = try ATProtocolURI(uriString: uriString)
      let params = AppBskyFeedGetPosts.Parameters(uris: [uri])
      let (responseCode, response) = try await client.app.bsky.feed.getPosts(input: params)

      if responseCode >= 200 && responseCode < 300,
         let posts = response?.posts,
         let post = posts.first {
        await MainActor.run {
          if isParent {
            self.parentPost = post
          } else {
            self.quotedPost = post
          }
        }
      }
    } catch {
      logger.error("Failed to restore post from URI \(uriString): \(error)")
    }
  }
  
  // MARK: - Media Item Model
  
  struct MediaItem: Identifiable {
    let id = UUID()
    var pickerItem: PhotosPickerItem?
    var image: Image?
    var isLoading: Bool = true
    var altText: String = ""
    var aspectRatio: CGSize?
    var rawData: Data?
    var videoData: Data?
    var rawVideoURL: URL?
    var rawVideoAsset: AVAsset?
    var isAudioVisualizerVideo: Bool = false
    
    init(pickerItem: PhotosPickerItem) {
      self.pickerItem = pickerItem
    }
    
    init() {
      self.pickerItem = nil
    }
    
    init(url: URL, isAudioVisualizerVideo: Bool = false) {
      self.pickerItem = nil
      self.rawVideoURL = url
      self.isAudioVisualizerVideo = isAudioVisualizerVideo
      self.rawVideoAsset = AVAsset(url: url)
    }
  }
  
  // MARK: - Alert Model
  
  struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }
  
  // MARK: - Media Source Tracking
  
  enum MediaSource {
    case photoPicker(String)
    case pastedImage(Data)
    case gifConversion(String)
    case genmojiConversion(Data)
  }
}
