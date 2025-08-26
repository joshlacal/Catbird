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
  
  // MARK: - Thumbnail Cache
  
  /// Cache for uploaded thumbnail blobs by URL
  var thumbnailCache: [String: Blob] = [:]
  
  // MARK: - Mention Properties
  
  var mentionSuggestions: [AppBskyActorDefs.ProfileViewBasic] = []
  var resolvedProfiles: [String: AppBskyActorDefs.ProfileViewBasic] = [:]
  
  // MARK: - State Properties
  
  var isPosting: Bool = false
  var alertItem: AlertItem?
  var mediaSourceTracker: Set<String> = []
  var showLabelSelector = false
  var showThreadgateOptions = false
  var threadgateSettings: ThreadgateSettings = ThreadgateSettings()
  
  // MARK: - Private Properties
  
  let appState: AppState
  
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
      mediaItems: mediaItems,
      videoItem: videoItem,
      selectedGif: selectedGif,
      selectedLanguages: selectedLanguages,
      selectedLabels: selectedLabels,
      outlineTags: outlineTags,
      threadEntries: threadEntries,
      isThreadMode: isThreadMode,
      currentThreadIndex: currentThreadIndex
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
    mediaItems = draft.mediaItems
    videoItem = draft.videoItem
    selectedGif = draft.selectedGif
    selectedLanguages = draft.selectedLanguages
    selectedLabels = draft.selectedLabels
    outlineTags = draft.outlineTags
    threadEntries = draft.threadEntries
    isThreadMode = draft.isThreadMode
    currentThreadIndex = draft.currentThreadIndex
    
    richAttributedText = NSAttributedString(string: postText)
    updatePostContent()
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
