import AVFoundation
import NaturalLanguage
import os
import Petrel
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Tenor API Models (shared with GifPickerView)

struct TenorGif: Codable, Identifiable {
    let id: String
    let title: String
    let content_description: String
    let itemurl: String
    let url: String
    let tags: [String]
    let media_formats: TenorMediaFormats
    let created: Double
    let flags: [String]
    let hasaudio: Bool
    let content_description_source: String
}

struct TenorMediaFormats: Codable {
    let gif: TenorMediaItem?
    let mediumgif: TenorMediaItem?
    let tinygif: TenorMediaItem?
    let nanogif: TenorMediaItem?
    let mp4: TenorMediaItem?
    let loopedmp4: TenorMediaItem?
    let tinymp4: TenorMediaItem?
    let nanomp4: TenorMediaItem?
    let webm: TenorMediaItem?
    let tinywebm: TenorMediaItem?
    let nanowebm: TenorMediaItem?
    let webp: TenorMediaItem?
    let gifpreview: TenorMediaItem?
    let tinygifpreview: TenorMediaItem?
    let nanogifpreview: TenorMediaItem?
}

struct TenorMediaItem: Codable {
    let url: String
    let dims: [Int]
    let duration: Double?
    let preview: String
    let size: Int?
}

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

// Define ThreadEntry model to represent each post in a thread
struct ThreadEntry: Identifiable {
  let id = UUID()
  var text: String = ""
  var mediaItems: [PostComposerViewModel.MediaItem] = []
  var videoItem: PostComposerViewModel.MediaItem?
  var detectedURLs: [String] = []
  var urlCards: [String: URLCardResponse] = [:]
  var facets: [AppBskyRichtextFacet]?
  var hashtags: [String] = []
}

#if os(iOS)
  typealias PlatformImage = UIImage
#elseif os(macOS)
  typealias PlatformImage = NSImage
  extension PlatformImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
      guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
      }
      let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
      return bitmapRep.representation(
        using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
  }
#endif

func localeLanguage(from nlLanguage: NLLanguage) -> Locale.Language {
  // NLLanguage uses ISO 639-1 or 639-2 codes, which are compatible with BCP-47
  return Locale.Language(identifier: nlLanguage.rawValue)
}

@MainActor @Observable
final class PostComposerViewModel {
  private let logger = Logger(subsystem: "blue.catbird", category: "PostComposerViewModel")
  
  var postText: String = ""
  var richAttributedText: NSAttributedString = NSAttributedString()
  var selectedLanguages: [LanguageCodeContainer] = []
  var suggestedLanguage: LanguageCodeContainer?
  var selectedLabels: Set<ComAtprotoLabelDefs.LabelValue> = []
  var mentionSuggestions: [AppBskyActorDefs.ProfileViewBasic] = []
  var showLabelSelector = false
  var alertItem: AlertItem?

  let parentPost: AppBskyFeedDefs.PostView?
  var quotedPost: AppBskyFeedDefs.PostView?
  let maxCharacterCount = 300

  // Thread-related properties
  var isThreadMode: Bool = false
  var threadEntries: [ThreadEntry] = []
  var currentThreadEntryIndex: Int = 0

  // Computed properties for thread handling
  var currentThreadEntry: ThreadEntry? {
    guard isThreadMode, !threadEntries.isEmpty, currentThreadEntryIndex < threadEntries.count else {
      return nil
    }
    return threadEntries[currentThreadEntryIndex]
  }

  var characterCount: Int { postText.count }
  var isOverCharacterLimit: Bool { characterCount > maxCharacterCount }
  var isPostButtonDisabled: Bool {
    // Only disable if: no content at all OR over character limit OR currently uploading OR missing required alt text
    let hasNoContent = postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && videoItem == nil
      && mediaItems.isEmpty && selectedGif == nil && detectedURLs.isEmpty
    
    // Check if alt text is required and missing
    let requiresAltText = appState.appSettings.requireAltText
    let missingAltText = requiresAltText && (
      mediaItems.contains { $0.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ||
      (videoItem?.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
    )
    
    return hasNoContent || isOverCharacterLimit || isVideoUploading || missingAltText
  }
    
    // Threadgate properties
    var threadgateSettings = ThreadgateSettings()
    var showThreadgateOptions = false
    
    private var profile: AppBskyActorDefs.ProfileViewDetailed?
    private var isLoadingProfile = false
    private var profileError: Error?
    
  // Media properties
  struct MediaItem: Identifiable, Equatable {
    let id = UUID()
    let pickerItem: PhotosPickerItem?  // Optional for pasted content
    var image: Image?
    var altText: String = ""
    var isLoading: Bool = true
    var aspectRatio: CGSize?
    var rawData: Data?
    var rawVideoURL: URL?
    var rawVideoAsset: AVAsset?
    var videoData: Data?

    // Initializer for PhotosPicker items
    init(pickerItem: PhotosPickerItem) {
      self.pickerItem = pickerItem
    }
    
    // Initializer for pasted content
    init() {
      self.pickerItem = nil
    }

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
      return lhs.id == rhs.id
    }
  }

  // Media properties and state
  var mediaItems: [MediaItem] = []  // For images (up to 4)
  var videoItem: MediaItem?  // For video (only one allowed)
  var currentEditingMediaId: UUID?
  var isAltTextEditorPresented = false
  var isVideoUploading: Bool = false

  // ✅ CLEANED: Removed selectedImageItems - now using direct processing to mediaItems

  // Media upload management
  var mediaUploadManager: MediaUploadManager?

  // Constants
  let maxImagesAllowed = 4
  let maxAltTextLength = 1000

  // Computed properties for media
  var canAddMoreMedia: Bool {
    return videoItem == nil && mediaItems.count < maxImagesAllowed
  }

  var hasVideo: Bool {
    return videoItem != nil
  }

  var detectedURLs: [String] = []
  var urlCards: [String: URLCardResponse] = [:]
  var isLoadingURLCard: Bool = false

  private let appState: AppState
  private var resolvedProfiles: [String: AppBskyActorDefs.ProfileViewBasic] = [:]

  init(parentPost: AppBskyFeedDefs.PostView? = nil, quotedPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
    self.parentPost = parentPost
    self.quotedPost = quotedPost
    self.appState = appState

    // Initialize MediaUploadManager if client is available
    if let client = appState.atProtoClient {
      self.mediaUploadManager = MediaUploadManager(client: client)
    }
    
    // Initialize attributed text
    self.richAttributedText = NSAttributedString(string: postText)
  }

  // MARK: - Separate Photo and Video Selection Methods

  // For processing a single video
  @MainActor
  func processVideoSelection(_ item: PhotosPickerItem) async {
    logger.debug("DEBUG: Processing video selection")

    // Validate content type
    let isVideo = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
    logger.debug("DEBUG: Is selection a video? \(isVideo)")
    logger.debug("DEBUG: Supported content types: \(item.supportedContentTypes)")

    guard isVideo else {
      logger.debug("DEBUG: Selected item is not a video")
      alertItem = AlertItem(title: "Selection Error", message: "The selected file is not a video.")
      return
    }

    // Clear existing media
    logger.debug("DEBUG: Clearing existing media")
    mediaItems.removeAll()

    // Create video media item
    logger.debug("DEBUG: Creating new video media item")
    let newVideoItem = MediaItem(pickerItem: item)
    self.videoItem = newVideoItem

    // Load video thumbnail and metadata
    logger.debug("DEBUG: Loading video thumbnail and metadata")
    await loadVideoThumbnail(for: newVideoItem)
  }

  // For processing photos (no video checks needed)
  @MainActor
  func processPhotoSelection(_ items: [PhotosPickerItem]) async {
    // Clear any existing video
    videoItem = nil

    // If we already have images and are adding more
    if !mediaItems.isEmpty && mediaItems.count + items.count > maxImagesAllowed {
      // Show alert about the limit
      alertItem = AlertItem(
        title: "Image Limit",
        message:
          "You can add up to \(maxImagesAllowed) images. Only the first \(maxImagesAllowed - mediaItems.count) will be used."
      )
    }

    // Add images up to the limit
    await addMediaItems(Array(items.prefix(maxImagesAllowed - mediaItems.count)))
  }

  // MARK: - Legacy Media Selection Processing

  @MainActor
  func processMediaSelection(_ items: [PhotosPickerItem]) async {
    guard !items.isEmpty else { return }

    // Check if any videos are in the selection
    let videoItems = items.filter {
      $0.supportedContentTypes.contains(where: { $0.conforms(to: .movie) })
    }

    if !videoItems.isEmpty {
      // If there's a video, use only the first video
      let videoPickerItem = videoItems[0]

      // Clear existing media
      mediaItems.removeAll()

      // Create video media item
      let newVideoItem = MediaItem(pickerItem: videoPickerItem)
      self.videoItem = newVideoItem

      // Load video thumbnail and metadata
      await loadVideoThumbnail(for: newVideoItem)

      // Show feedback to the user that only the video was used
      if videoItems.count > 1 {
        alertItem = AlertItem(
          title: "Video Selected",
          message: "Only the first video was used. Videos can't be combined with other media."
        )
      }
    } else {
      // If no videos, process as images
      // Clear any existing video
      videoItem = nil

      // If we already have images and are adding more
      if !mediaItems.isEmpty && mediaItems.count + items.count > maxImagesAllowed {
        // Show alert about the limit
        alertItem = AlertItem(
          title: "Image Limit",
          message:
            "You can add up to \(maxImagesAllowed) images. Only the first \(maxImagesAllowed - mediaItems.count) will be used."
        )
      }

      // Add images up to the limit
      await addMediaItems(Array(items.prefix(maxImagesAllowed - mediaItems.count)))
    }
  }

  // MARK: - Video Management Methods

  @MainActor
  private func loadVideoThumbnail(for item: MediaItem) async {
    guard let videoItem = self.videoItem else {
      logger.debug("DEBUG: videoItem is nil in loadVideoThumbnail")
      return
    }

    do {
      logger.debug("DEBUG: Starting video thumbnail generation process")

      // Validate the selection is a video (only for PhotosPicker items)
      logger.debug("DEBUG: Checking content types")
      if let pickerItem = videoItem.pickerItem,
         !pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
        logger.debug("DEBUG: Selected item is not a video (incorrect content type)")
        throw NSError(
          domain: "VideoLoadError",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Selected item is not a video file."]
        )
      }

      // Try multiple approaches to load the video
      logger.debug("DEBUG: Attempting to load video using multiple approaches")

      // Approach 1: Try loading as AVAsset (preferred for videos)
      var asset: AVAsset?
      var videoSize: CGSize?
      var videoDuration: Double = 0.0

      // Check if we can load as AVAsset directly (only for PhotosPicker items)
      logger.debug("DEBUG: Attempting to load as AVAsset")
      if let pickerItem = videoItem.pickerItem,
         let videoURL = try? await pickerItem.loadTransferable(type: URL.self) {
        logger.debug("DEBUG: Loading via URL: \(videoURL)")

        // Create an AVURLAsset from the URL
        let videoAsset = AVURLAsset(url: videoURL)
        asset = videoAsset
        self.videoItem?.rawVideoURL = videoURL

        // Continue with validations and loading properties
        let isPlayable = try await videoAsset.load(.isPlayable)
        guard isPlayable else {
          logger.debug("DEBUG: Video asset from URL is not playable")
          throw NSError(
            domain: "VideoLoadError",
            code: 5,
            userInfo: [
              NSLocalizedDescriptionKey: "The video format is not supported or is corrupted."
            ]
          )
        }

        // Get video track
        logger.debug("DEBUG: Loading video tracks from AVAsset")
        let tracks = try await videoAsset.loadTracks(withMediaType: AVMediaType.video)

        guard let videoTrack = tracks.first else {
          logger.debug("DEBUG: No video tracks found in asset")
          throw NSError(
            domain: "VideoTrackError",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "No video track found in the file."]
          )
        }

        // Get dimensions
        videoSize = try await videoTrack.load(.naturalSize)

        // Get duration
        let duration = try await videoAsset.load(.duration)
        videoDuration = CMTimeGetSeconds(duration)
      }
      // Approach 2: Try loading as Data (only for PhotosPicker items)
      else if let pickerItem = videoItem.pickerItem,
              let videoData = try? await pickerItem.loadTransferable(type: Data.self) {
        logger.debug("DEBUG: Successfully loaded video as Data, size: \(videoData.count) bytes")

        // Store the data for later use
        self.videoItem?.videoData = videoData

        // Create a temporary file from the data
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "temp_video_\(UUID().uuidString).mp4"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)

        logger.debug("DEBUG: Writing video data to temporary file: \(tempFileURL.path)")
        try videoData.write(to: tempFileURL)

        // Create an asset from the temporary file
        logger.debug("DEBUG: Creating AVAsset from temporary file")
        let videoAsset = AVURLAsset(url: tempFileURL)
        asset = videoAsset
        self.videoItem?.rawVideoURL = tempFileURL

        // Validate the asset
        logger.debug("DEBUG: Validating created AVAsset")
        let isPlayable = try await videoAsset.load(.isPlayable)
        if !isPlayable {
          logger.debug("DEBUG: Video asset is not playable")
          throw NSError(
            domain: "VideoLoadError",
            code: 5,
            userInfo: [
              NSLocalizedDescriptionKey: "The video format is not supported or is corrupted."
            ]
          )
        }

        // Get video track
        logger.debug("DEBUG: Loading video tracks from created AVAsset")
        let tracks = try await videoAsset.loadTracks(withMediaType: AVMediaType.video)

        guard let videoTrack = tracks.first else {
          logger.debug("DEBUG: No video tracks found in created asset")
          throw NSError(
            domain: "VideoTrackError",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "No video track found in the file."]
          )
        }

        // Get dimensions
        videoSize = try await videoTrack.load(.naturalSize)

        // Get duration
        let duration = try await videoAsset.load(.duration)
        videoDuration = CMTimeGetSeconds(duration)
      }
      // Approach 3: Use existing video URL if available (for pasted content)
      else if let existingVideoURL = videoItem.rawVideoURL {
        logger.debug("DEBUG: Using existing video URL: \(existingVideoURL)")

        // Use the existing URL
        let videoAsset = AVURLAsset(url: existingVideoURL)
        asset = videoAsset

        // Continue with validations and loading properties
        let isPlayable = try await videoAsset.load(.isPlayable)
        guard isPlayable else {
          logger.debug("DEBUG: Video asset from existing URL is not playable")
          throw NSError(
            domain: "VideoLoadError",
            code: 5,
            userInfo: [
              NSLocalizedDescriptionKey: "The video format is not supported or is corrupted."
            ]
          )
        }

        // Get video track
        logger.debug("DEBUG: Loading video tracks from existing URL AVAsset")
        let tracks = try await videoAsset.loadTracks(withMediaType: AVMediaType.video)

        guard let videoTrack = tracks.first else {
          logger.debug("DEBUG: No video tracks found in existing URL asset")
          throw NSError(
            domain: "VideoTrackError",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "No video track found in the file."]
          )
        }

        // Get dimensions
        videoSize = try await videoTrack.load(.naturalSize)

        // Get duration
        let duration = try await videoAsset.load(.duration)
        videoDuration = CMTimeGetSeconds(duration)
      }
      // Approach 4: Fallback to URL (may not work with PhotosUI security, only for PhotosPicker items)
      else if let pickerItem = videoItem.pickerItem,
              let videoURL = try? await pickerItem.loadTransferable(type: URL.self) {
        logger.debug("DEBUG: Loading via URL: \(videoURL)")

        // Validate file exists
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: videoURL.path) {
          logger.debug("DEBUG: File does not exist at path: \(videoURL.path)")
          throw NSError(
            domain: "VideoLoadError",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Video file not found at expected location."]
          )
        }

        // Create asset from URL
        logger.debug("DEBUG: Creating AVAsset from URL")
        let videoAsset = AVURLAsset(url: videoURL)
        asset = videoAsset
        self.videoItem?.rawVideoURL = videoURL

        // Validate the asset
        logger.debug("DEBUG: Validating URL-based AVAsset")
        let isPlayable = try await videoAsset.load(.isPlayable)
        if !isPlayable {
          logger.debug("DEBUG: Video asset from URL is not playable")
          throw NSError(
            domain: "VideoLoadError",
            code: 5,
            userInfo: [
              NSLocalizedDescriptionKey: "The video format is not supported or is corrupted."
            ]
          )
        }

        // Get video track
        logger.debug("DEBUG: Loading video tracks from URL-based AVAsset")
        let tracks = try await videoAsset.loadTracks(withMediaType: AVMediaType.video)

        guard let videoTrack = tracks.first else {
          logger.debug("DEBUG: No video tracks found in URL-based asset")
          throw NSError(
            domain: "VideoTrackError",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "No video track found in the file."]
          )
        }

        // Get dimensions
        videoSize = try await videoTrack.load(.naturalSize)

        // Get duration
        let duration = try await videoAsset.load(.duration)
        videoDuration = CMTimeGetSeconds(duration)
      }
      // No method worked
      else {
        logger.debug("DEBUG: Failed to load video using any available method")
        throw NSError(
          domain: "VideoLoadError",
          code: 2,
          userInfo: [
            NSLocalizedDescriptionKey: "Could not access video. Please try another video file."
          ]
        )
      }

      // Make sure we have an asset to work with
      guard let asset = asset, let videoSize = videoSize else {
        logger.debug("DEBUG: No valid asset or size information available")
        throw NSError(
          domain: "VideoLoadError",
          code: 7,
          userInfo: [NSLocalizedDescriptionKey: "Failed to extract valid video information."]
        )
      }

      logger.debug("DEBUG: Video dimensions: \(videoSize.width) x \(videoSize.height)")
      logger.debug("DEBUG: Video duration: \(videoDuration) seconds")

      // Check video size (max 100MB - approximate check)
      // This may not be accurate for all video formats
      let estimatedSizeBytes = Int(videoDuration) * 5_000_000  // Very rough estimate
      if estimatedSizeBytes > 100 * 1024 * 1024 {
        logger.debug(
          "DEBUG: Video likely exceeds maximum size (estimated: \(estimatedSizeBytes/1024/1024)MB)")
        throw NSError(
          domain: "VideoLoadError",
          code: 4,
          userInfo: [NSLocalizedDescriptionKey: "Video appears to exceed maximum size of 100MB."]
        )
      }

      // Generate the thumbnail
      logger.debug("DEBUG: Generating thumbnail at time 0.5 seconds")
      let time = CMTime(seconds: min(0.5, videoDuration / 2), preferredTimescale: 600)

      // Use modern async thumbnail generation method
      logger.debug("DEBUG: Calling generateThumbnail method")
      let cgImage = try await generateThumbnail(from: asset, at: time)
      logger.debug("DEBUG: Successfully generated thumbnail")

      let thumbnail = UIImage(cgImage: cgImage)
      logger.debug("DEBUG: Created UIImage from CGImage")

      // Update the video item
      logger.debug("DEBUG: Updating video item properties")
      self.videoItem?.image = Image(uiImage: thumbnail)
      self.videoItem?.aspectRatio = CGSize(width: videoSize.width, height: videoSize.height)
      self.videoItem?.isLoading = false
      logger.debug("DEBUG: Video thumbnail generation complete")
    } catch {
      logger.error("ERROR: Video thumbnail generation failed: \(error)")
      if let nsError = error as NSError? {
        logger.debug(
          "ERROR: Domain: \(nsError.domain), Code: \(nsError.code), Description: \(nsError.localizedDescription)"
        )
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
          logger.debug(
            "ERROR: Underlying error - Domain: \(underlyingError.domain), Code: \(underlyingError.code), Description: \(underlyingError.localizedDescription)"
          )
        }
      }

      // Create a more informative alert based on the error
      let errorMessage: String
      if let nsError = error as NSError? {
        switch nsError.domain {
        case "VideoLoadError":
          errorMessage = nsError.localizedDescription
        case "AVFoundationErrorDomain":
          errorMessage = "Media format issue: \(nsError.localizedDescription)"
        case "VideoThumbnailError":
          errorMessage = "Could not generate video preview: \(nsError.localizedDescription)"
        default:
          errorMessage = "Could not process video: \(nsError.localizedDescription)"
        }
      } else {
        errorMessage = "Could not process video. Please try another video."
      }

      alertItem = AlertItem(title: "Video Error", message: errorMessage)
      self.videoItem = nil
    }
  }

  // Helper function to convert the completion handler-based API to async/await
  private func generateThumbnail(from asset: AVAsset, at time: CMTime) async throws -> CGImage {
    logger.debug("DEBUG: Configuring AVAssetImageGenerator")
    let imageGenerator = AVAssetImageGenerator(asset: asset)
    imageGenerator.appliesPreferredTrackTransform = true
    imageGenerator.maximumSize = CGSize(width: 1920, height: 1080)  // Set max size to avoid memory issues
    imageGenerator.requestedTimeToleranceBefore = .zero
    imageGenerator.requestedTimeToleranceAfter = .zero

    return try await withCheckedThrowingContinuation { continuation in
      logger.debug("DEBUG: Starting async thumbnail generation at time: \(CMTimeGetSeconds(time))")
      let timeValue = NSValue(time: time)

        imageGenerator.generateCGImagesAsynchronously(forTimes: [timeValue]) { [self]
        requestedTime, cgImage, actualTime, result, error in
        logger.debug("DEBUG: Thumbnail generation callback received")
        logger.debug(
          "DEBUG: Requested time: \(CMTimeGetSeconds(requestedTime)), Actual time: \(CMTimeGetSeconds(actualTime))"
        )
        logger.debug("DEBUG: Result: \(result.rawValue)")

        if let error = error {
          logger.error("ERROR: Thumbnail generation failed with error: \(error)")
          let nsError = error as NSError
          let enhancedError = NSError(
            domain: "VideoThumbnailError",
            code: nsError.code,
            userInfo: [
              NSLocalizedDescriptionKey:
                "Failed to generate thumbnail: \(nsError.localizedDescription)",
              NSUnderlyingErrorKey: error
            ]
          )
          continuation.resume(throwing: enhancedError)
        } else if let cgImage = cgImage, result == .succeeded {
          logger.debug(
            "DEBUG: Successfully generated thumbnail with dimensions: \(cgImage.width) x \(cgImage.height)"
          )
          continuation.resume(returning: cgImage)
        } else {
          let resultDescription: String
          switch result {
          case .failed:
            resultDescription = "failed"
          case .cancelled:
            resultDescription = "cancelled"
          case .succeeded:
            resultDescription = "succeeded but no image"
          @unknown default:
            resultDescription = "unknown result \(result.rawValue)"
          }

          logger.error("ERROR: Thumbnail generation \(resultDescription) without an image")
          continuation.resume(
            throwing: NSError(
              domain: "VideoThumbnailError",
              code: Int(result.rawValue),
              userInfo: [
                NSLocalizedDescriptionKey: "Failed to generate thumbnail: \(resultDescription)"
              ]
            ))
        }
      }
    }
  }

  // MARK: - Media Management Methods

  // Method to add new media items from picker selection
  @MainActor
  func addMediaItems(_ items: [PhotosPickerItem]) async {
    // Limit to maximum allowed
    let availableSlots = maxImagesAllowed - mediaItems.count
    guard availableSlots > 0 else { return }

    let itemsToAdd = items.prefix(availableSlots)
    let newMediaItems = itemsToAdd.map { MediaItem(pickerItem: $0) }

    // Add to our array
    mediaItems.append(contentsOf: newMediaItems)

    // Load each image asynchronously
    for i in mediaItems.indices where mediaItems[i].image == nil {
      await loadImageForItem(at: i)
    }
  }

  // Load a single image
  @MainActor
  private func loadImageForItem(at index: Int) async {
    guard index < mediaItems.count else { return }

    // Skip loading if this is pasted content (already has image data)
    guard let pickerItem = mediaItems[index].pickerItem else {
      logger.debug("DEBUG: Skipping load for pasted content item")
      return
    }

    do {
      let (data, uiImage) = try await loadImageData(from: pickerItem)

      if let uiImage = uiImage {
        mediaItems[index].image = Image(uiImage: uiImage)
        mediaItems[index].isLoading = false
        mediaItems[index].aspectRatio = CGSize(
          width: uiImage.size.width, height: uiImage.size.height)
        mediaItems[index].rawData = data
      }
    } catch {
      logger.debug("Error loading image: \(error)")
      // Remove failed item
      mediaItems.remove(at: index)
    }
  }

  // Helper to load image data
  private func loadImageData(from item: PhotosPickerItem) async throws -> (Data, UIImage?) {
    guard let data = try await item.loadTransferable(type: Data.self) else {
      throw NSError(
        domain: "ImageLoadingError", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"])
    }

    let uiImage = UIImage(data: data)
    return (data, uiImage)
  }

  // Remove a media item
  func removeMediaItem(at index: Int) {
    guard index < mediaItems.count else { return }
    mediaItems.remove(at: index)
  }

  func removeMediaItem(withId id: UUID) {
    if videoItem?.id == id {
      videoItem = nil
    } else {
      mediaItems.removeAll(where: { $0.id == id })
    }
  }

  // Update alt text for a media item
  func updateAltText(_ text: String, for id: UUID) {
    if let videoItem = videoItem, videoItem.id == id {
      let truncatedText = String(text.prefix(maxAltTextLength))
      self.videoItem?.altText = truncatedText
    } else if let index = mediaItems.firstIndex(where: { $0.id == id }) {
      // Truncate if over limit
      let truncatedText = String(text.prefix(maxAltTextLength))
      mediaItems[index].altText = truncatedText
    }
  }

  // Begin editing alt text for a specific item
  func beginEditingAltText(for id: UUID) {
    currentEditingMediaId = id
    isAltTextEditorPresented = true
  }

  @MainActor
  func loadUserLanguagePreference() async {
    // Check if we have stored language preferences in UserDefaults
      if let storedLanguages = UserDefaults(suiteName: "group.blue.catbird.shared")?.stringArray(forKey: "userPreferredLanguages"),
      !storedLanguages.isEmpty {
      // Convert stored language strings to LanguageCodeContainer objects
      for langString in storedLanguages {
        let languageCode = Locale.Language(identifier: langString)
        let languageContainer = LanguageCodeContainer(lang: languageCode)

        // Add it to selected languages if not already there
        if !selectedLanguages.contains(languageContainer) {
          selectedLanguages.append(languageContainer)
          logger.debug("Added user's preferred language from UserDefaults: \(langString)")
        }
      }
    } else {
      // Fall back to system language if no preference is stored
      let systemLang = Locale.current.language.languageCode?.identifier
      if let systemLang = systemLang {
        let languageCode = Locale.Language(identifier: systemLang)
        let languageContainer = LanguageCodeContainer(lang: languageCode)

        // Add system language if not already in selected languages
        if !selectedLanguages.contains(languageContainer) {
          selectedLanguages.append(languageContainer)
          logger.debug("Added system language as fallback: \(systemLang)")
        }
      }
    }
  }

  // MARK: - Real-time Text Parsing and Highlighting
  
  var attributedPostText: AttributedString = AttributedString()
  
  func updatePostContent() {
    suggestedLanguage = detectLanguage()

    // Parse the text content to get URLs and update mentions
    let (_, _, facets, urls, _) = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)

    // Update attributed text with highlighting using existing RichText implementation
    updateAttributedText(facets: facets)
    
    // Handle URLs
    handleDetectedURLs(urls)

    Task {
      await updateMentionSuggestions()
    }
  }
  
  func updateFromAttributedText(_ nsAttributedText: NSAttributedString) {
    // Extract plain text from attributed text
    let newText = nsAttributedText.string
    
    // Only update if text actually changed to avoid infinite loops
    if newText != postText {
      postText = newText
      
      // Update the NSAttributedString property
      richAttributedText = nsAttributedText
      
      // Trigger standard post content update
      updatePostContent()
    }
  }
  
  func syncAttributedTextFromPlainText() {
    // Update NSAttributedString when plain text changes
    if postText != richAttributedText.string {
      richAttributedText = NSAttributedString(string: postText)
    }
  }
  
  /// Update the attributed text with real-time highlighting using the existing RichText system
  private func updateAttributedText(facets: [AppBskyRichtextFacet]) {
    // Start with plain attributed text
    var styledAttributedText = AttributedString(postText)
    
    for facet in facets {
      guard let start = postText.index(atUTF8Offset: facet.index.byteStart),
            let end = postText.index(atUTF8Offset: facet.index.byteEnd),
            start < end else {
        continue
      }
      
      let attrStart = AttributedString.Index(start, within: styledAttributedText)
      let attrEnd = AttributedString.Index(end, within: styledAttributedText)
      
      if let attrStart = attrStart, let attrEnd = attrEnd {
        let range = attrStart..<attrEnd
        
        for feature in facet.features {
          switch feature {
          case .appBskyRichtextFacetMention:
            styledAttributedText[range].foregroundColor = .accentColor
            styledAttributedText[range].font = .body.weight(.medium)
            
          case .appBskyRichtextFacetTag:
            styledAttributedText[range].foregroundColor = .accentColor
            styledAttributedText[range].font = .body.weight(.medium)
            
          case .appBskyRichtextFacetLink(let link):
            styledAttributedText[range].foregroundColor = .blue
            styledAttributedText[range].underlineStyle = .single
            
            // Optionally shorten long URLs for display
            if let url = URL(string: link.uri.uriString()) {
              let originalText = String(styledAttributedText[range].characters)
              let displayText = shortenURLForDisplay(url)
              
              // Only replace if shortened version is meaningfully shorter
              if displayText.count < originalText.count - 10 {
                var shortenedAttrString = AttributedString(displayText)
                shortenedAttrString.foregroundColor = .blue
                shortenedAttrString.underlineStyle = .single
                styledAttributedText.replaceSubrange(range, with: shortenedAttrString)
              }
            }
            
          default:
            break
          }
        }
      }
    }
    
    attributedPostText = styledAttributedText
  }
  
  /// Shorten URLs for better display while preserving full URL in facets
  private func shortenURLForDisplay(_ url: URL) -> String {
    let host = url.host ?? ""
    let path = url.path
    
    // For common domains, show just the domain
    if path.isEmpty || path == "/" {
      return host
    }
    
    // For paths, show domain + truncated path
    let maxPathLength = 15
    if path.count > maxPathLength {
      let truncatedPath = String(path.prefix(maxPathLength)) + "..."
      return "\(host)\(truncatedPath)"
    }
    
    return "\(host)\(path)"
  }

  // Add a cache for processed images
  private var processedImageCache: [String: Data] = [:]

  // MARK: - Image Processing and Uploading

  // Create embed for multiple images
  func createImagesEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
    guard !mediaItems.isEmpty, let client = appState.atProtoClient else { return nil }

    // Create array for image embeds
    var imageEmbeds: [AppBskyEmbedImages.Image] = []

    // Process each media item
    for item in mediaItems {
      guard let rawData = item.rawData else { continue }

      // Process and optimize image
      let imageData = try await processImageForUpload(rawData)

      // Upload the blob
      let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
        data: imageData,
        mimeType: "image/jpeg",
        stripMetadata: true
      )

      guard responseCode == 200, let blob = blobOutput?.blob else {
        throw NSError(domain: "BlobUploadError", code: responseCode, userInfo: nil)
      }

      // Create aspect ratio
      let aspectRatio = AppBskyEmbedDefs.AspectRatio(
        width: Int(item.aspectRatio?.width ?? 0),
        height: Int(item.aspectRatio?.height ?? 0)
      )

      // Create the image embed with alt text
      let altText = item.altText
      let imageEmbed = AppBskyEmbedImages.Image(
        image: blob,
        alt: altText,
        aspectRatio: aspectRatio
      )

      imageEmbeds.append(imageEmbed)
    }

    // Return the complete images embed
    return .appBskyEmbedImages(AppBskyEmbedImages(images: imageEmbeds))
  }

  // Create video embed
  func createVideoEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
    guard let videoItem = videoItem, let mediaUploadManager = mediaUploadManager else {
      logger.debug("DEBUG: Missing videoItem or mediaUploadManager")
      return nil
    }

    // Set uploading state
    isVideoUploading = true
    logger.debug("DEBUG: Creating video embed, starting upload process")

    do {
      // Depending on what's available, try different upload approaches
      let blob: Blob

      if let videoURL = videoItem.rawVideoURL {
        logger.debug("DEBUG: Using URL for video upload: \(videoURL)")
        blob = try await mediaUploadManager.uploadVideo(url: videoURL, alt: videoItem.altText)
      } else if let videoAsset = videoItem.rawVideoAsset {
        logger.debug("DEBUG: Using AVAsset for video upload")

        // Export the asset to a temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "export_video_\(UUID().uuidString).mp4"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)

        logger.debug("DEBUG: Exporting asset to temporary file: \(tempFileURL.path)")
        let exported = try await exportAsset(videoAsset, to: tempFileURL)

        // Check export status
          logger.debug("DEBUG: Asset export successful, uploading from: \(tempFileURL.path)")

        // Upload the exported file
        logger.debug("DEBUG: Asset export successful, uploading from: \(tempFileURL.path)")
        blob = try await mediaUploadManager.uploadVideo(url: tempFileURL, alt: videoItem.altText)
      } else if let videoData = videoItem.videoData {
        logger.debug("DEBUG: Using Data for video upload, size: \(videoData.count) bytes")

        // Create a temporary file from the data
        let tempDir = FileManager.default.temporaryDirectory
        let tempFileName = "data_video_\(UUID().uuidString).mp4"
        let tempFileURL = tempDir.appendingPathComponent(tempFileName)

        logger.debug("DEBUG: Writing video data to temporary file: \(tempFileURL.path)")
        try videoData.write(to: tempFileURL)

        // Upload the file
        logger.debug("DEBUG: Uploading from temporary file: \(tempFileURL.path)")
        blob = try await mediaUploadManager.uploadVideo(url: tempFileURL, alt: videoItem.altText)
      } else {
        logger.error("ERROR: No video source available for upload")
        isVideoUploading = false
        throw NSError(
          domain: "VideoUploadError",
          code: 8,
          userInfo: [
            NSLocalizedDescriptionKey: "No video data available for upload. Please try again."
          ]
        )
      }

      // Create video embed
      logger.debug("DEBUG: Video upload successful, creating embed")
      let embed = mediaUploadManager.createVideoEmbed(
        aspectRatio: videoItem.aspectRatio,
        alt: videoItem.altText.isEmpty ? "Video" : videoItem.altText
      )

      isVideoUploading = false
      return embed
    } catch {
      isVideoUploading = false
      logger.error("ERROR: Video upload failed: \(error)")

      // Convert error to user-friendly message
      let errorMessage: String
      switch error {
      case VideoUploadError.processingFailed(let reason):
        errorMessage = reason
      case VideoUploadError.uploadFailed:
        errorMessage = "Video upload failed"
      case VideoUploadError.processingTimeout:
        errorMessage = "Video processing timed out"
      case VideoUploadError.authenticationFailed:
        errorMessage = "Authentication error during upload"
      default:
        errorMessage = error.localizedDescription
      }

      throw NSError(
        domain: "VideoUploadError",
        code: 0,
        userInfo: [NSLocalizedDescriptionKey: errorMessage]
      )
    }
  }

  // Helper method to export AVAsset to file
    private func exportAsset(_ asset: AVAsset, to outputURL: URL) async throws -> AVAssetExportSession {
        logger.debug("DEBUG: Creating export session")
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            logger.error("ERROR: Could not create export session")
            throw NSError(
                domain: "VideoExportError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create export session for video"]
            )
        }

        logger.debug("DEBUG: Starting export operation")
        do {
            // Use the new async/throws export method
            try await exportSession.export(to: outputURL, as: .mp4)
            logger.debug("DEBUG: Export completed successfully")
        } catch {
            logger.debug("DEBUG: Export failed with error: \(error)")
            throw error
        }

        return exportSession
    }
    
  // Process image for upload - compress and optimize
  private func processImageForUpload(_ data: Data) async throws -> Data {
    // Start with original data
    var processedData = data

    // Check if we need to convert format
    if checkImageFormat(data) == "HEIC" {
      if let converted = convertHEICToJPEG(data) {
        processedData = converted
      }
    }

    // Compress if needed
    if let image = UIImage(data: processedData),
      let compressed = compressImage(image, maxSizeInBytes: 900_000) {
      processedData = compressed
    }

    return processedData
  }

  // ✅ CLEANED: Removed loadSelectedImage() - now using direct processing to mediaItems

  // Add cleanup method
  func cleanup() {
    processedImageCache.removeAll()
  }

  // MARK: - Unified Media Handling
  
  /// Enhanced MediaItem with source tracking to prevent duplicates
  enum MediaSource: Equatable {
    case photoPicker(String) // PhotosPickerItem identifier
    case pastedImage(Data)   // Raw image data for comparison
    case pastedVideo(URL)    // Video URL
    case clipboard(String)   // Clipboard content hash
  }
  
  // Track media sources to prevent duplicates
  private var mediaSourceTracker: Set<String> = []
  
  /// Generate unique identifier for media source
  private func generateSourceID(for source: MediaSource) -> String {
    switch source {
    case .photoPicker(let id):
      return "picker:\(id)"
    case .pastedImage(let data):
      return "image:\(data.hashValue)"
    case .pastedVideo(let url):
      return "video:\(url.absoluteString)"
    case .clipboard(let hash):
      return "clipboard:\(hash)"
    }
  }
  
  /// Check if media from this source was already added
  private func isMediaSourceAlreadyAdded(_ source: MediaSource) -> Bool {
    let sourceID = generateSourceID(for: source)
    return mediaSourceTracker.contains(sourceID)
  }
  
  /// Track media source as added
  private func trackMediaSource(_ source: MediaSource) {
    let sourceID = generateSourceID(for: source)
    mediaSourceTracker.insert(sourceID)
  }

  // MARK: - Clipboard/Paste Functionality

  /// Check if clipboard contains supported media or text content
  func hasClipboardMedia() -> Bool {
    #if os(iOS)
      let pasteboard = UIPasteboard.general
      
      // Check direct image/media access first
      if pasteboard.hasImages || pasteboard.hasURLs || pasteboard.hasStrings {
        return true
      }
      
      // Check item providers for various media types
      for itemProvider in pasteboard.itemProviders {
        let mediaTypes = [
          UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, 
          UTType.tiff.identifier, UTType.gif.identifier, UTType.movie.identifier,
          "public.image", "public.movie"
        ]
        
        for mediaType in mediaTypes {
          if itemProvider.hasItemConformingToTypeIdentifier(mediaType) {
            return true
          }
        }
      }
      
      // Check pasteboard items directly for media data
      for item in pasteboard.items {
        let mediaKeys = [
          "public.image", "public.jpeg", "public.png", "public.tiff", 
          "public.gif", "public.movie", "public.url", "public.text"
        ]
        
        for mediaKey in mediaKeys {
          if item[mediaKey] != nil {
            return true
          }
        }
      }
      
      return false
    #elseif os(macOS)
      let pasteboard = NSPasteboard.general
      return pasteboard.canReadItem(withDataConformingToTypes: [UTType.image.identifier, UTType.movie.identifier]) || 
             pasteboard.string(forType: .string) != nil
    #endif
  }

  // ✅ CLEANED: Removed legacy handlePasteFromClipboard() and associated methods
  // All clipboard handling is now unified through handleMediaPaste()
  
  // MARK: - Genmoji Handling
  
  /// Convert genmoji data to MediaItems for upload to Bluesky
  @MainActor
  func convertGenmojiToMediaItems(_ genmojis: [GenmojiData]) async {
    logger.debug("DEBUG: Converting \(genmojis.count) genmoji to media items")
    
    for genmojiData in genmojis {
      guard let uiImage = UIImage(data: genmojiData.imageData) else {
        logger.debug("DEBUG: Failed to create UIImage from genmoji data")
        continue
      }
      
      logger.debug("DEBUG: Creating MediaItem for genmoji with size: \(uiImage.size.width)x\(uiImage.size.height)")
      
      // Create MediaItem for genmoji
      var mediaItem = MediaItem()
      mediaItem.image = Image(uiImage: uiImage)
      mediaItem.isLoading = false
      mediaItem.aspectRatio = CGSize(width: uiImage.size.width, height: uiImage.size.height)
      mediaItem.rawData = genmojiData.imageData
      
      // Use content description as alt text, or default
      mediaItem.altText = genmojiData.contentDescription ?? "Genmoji"
      
      // Check if we have available slots
      guard mediaItems.count < maxImagesAllowed else {
        logger.debug("DEBUG: Hit image limit, cannot add more genmoji")
        alertItem = AlertItem(
          title: "Media Limit",
          message: "Cannot add genmoji. You've reached the \(maxImagesAllowed) media limit."
        )
        break
      }
      
      self.mediaItems.append(mediaItem)
      logger.debug("DEBUG: Added genmoji as media item, total count now: \(self.mediaItems.count)")
    }
  }
  
  /// Handle detected genmoji from the text editor
  @MainActor
  func processDetectedGenmoji(_ genmojis: [GenmojiData]) async {
    logger.debug("DEBUG: Processing \(genmojis.count) detected genmoji")
    
    // Clear existing video if adding genmoji (since they're images)
    if !genmojis.isEmpty && videoItem != nil {
      videoItem = nil
      logger.debug("DEBUG: Cleared video to make room for genmoji")
    }
    
    await convertGenmojiToMediaItems(genmojis)
  }
  
  /// Update post text to remove genmoji characters (for Bluesky)
  func updatePostTextWithoutGenmoji() {
    // This will be called when creating the post to get clean text for Bluesky
    // The rich text editor will still show genmoji inline for user experience
    if #available(iOS 18.1, *) {
      // We'll implement this in the post creation flow
    }
  }

  /// Unified media paste handler - replaces all separate paste methods
  @MainActor
  func handleMediaPaste() async {
    logger.debug("🎯 UNIFIED: handleMediaPaste called")
    
    #if os(iOS)
    let pasteboard = UIPasteboard.general
    
    // Debug: Log what's available
    logger.debug("🎯 Pasteboard state: images=\(pasteboard.hasImages), strings=\(pasteboard.hasStrings), URLs=\(pasteboard.hasURLs)")
    
    // Method 1: Direct image access (Photos app, etc.)
    if pasteboard.hasImages, let image: UIImage = pasteboard.image {
        logger.debug("🎯 Found direct image, size: \(image.size.debugDescription)")
      await processPastedImage(image, from: .clipboard("direct_image"))
      return
    }
    
    // Method 2: Item providers (Safari, memoji, etc.)
    if let itemProvider = pasteboard.itemProviders.first {
      logger.debug("🎯 Found item provider, checking types...")
      
      let imageTypes = [UTType.image.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier]
      
      for imageType in imageTypes {
        if itemProvider.hasItemConformingToTypeIdentifier(imageType) {
          logger.debug("🎯 Found conforming type: \(imageType)")
          
          do {
            let result = try await itemProvider.loadItem(forTypeIdentifier: imageType)
            
            if let imageData = result as? Data, let image: UIImage = UIImage(data: imageData) {
                logger.debug("🎯 Loaded image from data, size: \(image.size.debugDescription)")
              await processPastedImage(image, from: .pastedImage(imageData))
              return
            } else if let image: UIImage = result as? UIImage {
                logger.debug("🎯 Loaded image directly, size: \(image.size.debugDescription)")
              await processPastedImage(image, from: .clipboard("direct_uiimage"))
              return
            }
          } catch {
            logger.error("🎯 Error loading item: \(error)")
            continue
          }
        }
      }
    }
    
    // Method 3: String content (URLs, text)
    if pasteboard.hasStrings, let string = pasteboard.string {
      logger.debug("🎯 Found string content, length: \(string.count)")
      await handlePastedTextString(string)
      return
    }
    
    logger.debug("🎯 No supported content found in pasteboard")
    #endif
  }
  
  /// Process pasted image with duplicate prevention
  @MainActor
  private func processPastedImage(_ uiImage: UIImage, from source: MediaSource) async {
    logger.debug("🎯 Processing pasted image with source tracking")
    
    // Check for duplicates
    if isMediaSourceAlreadyAdded(source) {
      logger.debug("🎯 DUPLICATE: Image from this source already added")
      return
    }
    
    // Clear existing video if pasting images
    videoItem = nil
    
    // Check if we have available slots
    guard mediaItems.count < maxImagesAllowed else {
      logger.debug("🎯 Hit image limit, showing alert")
      alertItem = AlertItem(
        title: "Image Limit",
        message: "Cannot add more images. You've reached the \(maxImagesAllowed) image limit."
      )
      return
    }
    
    // Convert UIImage to data for storage consistency
    guard let imageData = uiImage.jpegData(compressionQuality: 0.8) else {
      logger.debug("🎯 Failed to convert UIImage to data")
      return
    }
    
    // Track this source to prevent duplicates
    trackMediaSource(source)
    
    // Create MediaItem for pasted content
    var mediaItem: MediaItem = MediaItem()
    mediaItem.image = Image(uiImage: uiImage)
    mediaItem.isLoading = false
    mediaItem.aspectRatio = CGSize(width: uiImage.size.width, height: uiImage.size.height)
    mediaItem.rawData = imageData
    
    self.mediaItems.append(mediaItem)
    logger.debug("🎯 SUCCESS: Added pasted image, total count now: \(self.mediaItems.count)")
  }
  
  /// Handle pasted video URL from text editor paste
  @MainActor
  func handlePastedVideoURL(_ url: URL) async {
    logger.debug("DEBUG: handlePastedVideoURL called with URL: \(url)")
    
    // Clear existing media if pasting video
    mediaItems.removeAll()
    
    // Create video media item from URL
    var newVideoItem = MediaItem()
    newVideoItem.rawVideoURL = url
    newVideoItem.isLoading = true
    
    self.videoItem = newVideoItem
    
    // Load video thumbnail and metadata
    await loadVideoThumbnail(for: newVideoItem)
    logger.debug("DEBUG: Added pasted video from URL")
  }

  /// Handle pasted text string and append to current post text
  @MainActor
  private func handlePastedTextString(_ textString: String) async {
    // Insert the pasted text at the current cursor position
    // Since we don't have cursor position tracking, append to the end
    if postText.isEmpty {
      postText = textString
    } else {
      // Add a space if the current text doesn't end with whitespace
      let separator = postText.hasSuffix(" ") || postText.hasSuffix("\n") ? "" : " "
      postText += separator + textString
    }
    
    // Trigger content parsing to generate facets for mentions, hashtags, and links
    updatePostContent()
  }

  /// Check if URL points to a video file
  func isVideoURL(_ url: URL) -> Bool {
    let videoExtensions = ["mp4", "mov", "avi", "mkv", "webm", "m4v"]
    let pathExtension = url.pathExtension.lowercased()
    return videoExtensions.contains(pathExtension)
  }

  #if os(macOS)
  /// Handle pasted image data on macOS
  @MainActor
  private func handlePastedImageData(_ imageData: Data) async {
    guard let nsImage = NSImage(data: imageData) else { return }
    
    // Clear existing video if pasting images
    videoItem = nil
    
    // Check if we can add more images
    guard mediaItems.count < maxImagesAllowed else {
      alertItem = AlertItem(
        title: "Image Limit",
        message: "Cannot paste image. Maximum of \(maxImagesAllowed) images allowed."
      )
      return
    }
    
    // Create MediaItem for pasted content
    var mediaItem: MediaItem = MediaItem()
    mediaItem.image = Image(nsImage: nsImage)
    mediaItem.isLoading = false
    mediaItem.aspectRatio = CGSize(width: nsImage.size.width, height: nsImage.size.height)
    mediaItem.rawData = imageData
    
    mediaItems.append(mediaItem)
  }
  #endif

  private func detectLanguage() -> LanguageCodeContainer? {
    // Skip detection for very short text
    guard postText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 else {
      return getUserPrimaryLanguage()
    }
    
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(postText)
    
    // Get confidence scores for multiple languages
    let languageHypotheses = recognizer.languageHypotheses(withMaximum: 3)
    
    // Find the best language that's also in user's preferred languages
    let userLanguages = appState.appSettings.contentLanguages ?? []
    
    for (nlLanguage, confidence) in languageHypotheses {
      // Only consider languages with reasonable confidence (>0.3)
      guard confidence > 0.3 else { continue }
      
      let detectedLangCode = nlLanguage.rawValue
      
      // Prefer detected languages that match user's preferences
      if userLanguages.contains(detectedLangCode) {
        let detectedLang = localeLanguage(from: nlLanguage)
        return LanguageCodeContainer(lang: detectedLang)
      }
    }
    
    // If no preferred language detected with good confidence, use the top detection
    if let (topLanguage, confidence) = languageHypotheses.first, confidence > 0.5 {
      let detectedLang = localeLanguage(from: topLanguage)
      return LanguageCodeContainer(lang: detectedLang)
    }
    
    // Fallback to user's primary language
    return getUserPrimaryLanguage()
  }
  
  private func getUserPrimaryLanguage() -> LanguageCodeContainer? {
    // appState is always available (not optional)
    
    // Use user's primary language from settings
    let primaryLangCode = appState.appSettings.primaryLanguage
    
    // Convert to LanguageCodeContainer
    if let language = Locale.Language(identifier: primaryLangCode) as? Locale.Language {
      return LanguageCodeContainer(lang: language)
    }
    
    // Fallback to system language
    if let systemLang = Locale.current.language.languageCode?.identifier {
      if let language = Locale.Language(identifier: systemLang) as? Locale.Language {
        return LanguageCodeContainer(lang: language)
      }
    }
    
    return nil
  }

  @MainActor
  private func updateMentionSuggestions() async {
    guard let mentionRange = postText.range(of: "@[^\\s]*$", options: .regularExpression) else {
      mentionSuggestions = []
      return
    }

    let searchTerm = String(postText[mentionRange].dropFirst())

    if searchTerm.isEmpty {
      mentionSuggestions = []
    } else {
      await searchProfiles(term: searchTerm)
    }
  }

  private func searchProfiles(term: String) async {
    guard !term.isEmpty, let client = appState.atProtoClient else {
      mentionSuggestions = []
      return
    }

    do {
      let input = AppBskyActorSearchActorsTypeahead.Parameters(term: term, limit: 5)
      let (responseCode, output) = try await client.app.bsky.actor.searchActorsTypeahead(
        input: input)

      if responseCode == 200, let searchResults = output?.actors {
        mentionSuggestions = searchResults
      } else {
        logger.debug("Failed to load profiles. Please try again.")
      }
    } catch {
      logger.debug("Error searching profiles: \(error.localizedDescription)")
    }
  }

  func insertMention(_ profile: AppBskyActorDefs.ProfileViewBasic) {
    guard let range = postText.range(of: "@[^\\s]*$", options: .regularExpression) else { return }

    let mention = "@\(profile.handle) "
    postText = postText.replacingCharacters(in: range, with: mention)

    // Store the resolved profile
    resolvedProfiles[profile.handle.description] = profile

    mentionSuggestions = []
  }

  func insertEmoji(_ emoji: String) {
    // Update both plain text and attributed text
    postText += emoji
    
    // Create new attributed text with emoji appended
    let mutableAttributedText = NSMutableAttributedString(attributedString: richAttributedText)
    mutableAttributedText.append(NSAttributedString(string: emoji))
    richAttributedText = mutableAttributedText
    
    updatePostContent()
  }

  func toggleLanguage(_ lang: LanguageCodeContainer) {
    if let index = selectedLanguages.firstIndex(of: lang) {
      selectedLanguages.remove(at: index)
    } else {
      selectedLanguages.append(lang)
    }

    // Save the updated language preferences to UserDefaults
    saveLanguagePreferences()
  }

  // New method to save language preferences
  private func saveLanguagePreferences() {
    // Convert LanguageCodeContainer objects to strings for storage
    let languageStrings = selectedLanguages.map { $0.lang.languageCode?.identifier }
    UserDefaults(suiteName: "group.blue.catbird.shared")?.set(languageStrings, forKey: "userPreferredLanguages")
    logger.debug("Saved language preferences: \(languageStrings)")
  }

    func applyProfileLabels() async {
        await loadUserProfile()
        
        // Check for profile-level labels that should be inherited
        if let userProfile = profile,
           let profileLabels = userProfile.labels,
           profileLabels.contains(where: { $0.val == "!no-unauthenticated" }),
           !selectedLabels.contains(.exclamationnodashunauthenticated) {
            
            // Add the !no-unauthenticated label automatically
            selectedLabels.insert(.exclamationnodashunauthenticated)
        }
    }
    
    private func loadUserProfile() async {
        guard let client = appState.atProtoClient else { return }
        
        isLoadingProfile = true
        profileError = nil
        
        do {
            // Get the DID first, before using it
            let did: String
            if let currentUserDID = appState.currentUserDID {
                did = currentUserDID
            } else {
                did = try await client.getDid()
            }
            
            // Now use the did variable to fetch the profile
            let (responseCode, profileData) = try await client.app.bsky.actor.getProfile(
                input: .init(actor: ATIdentifier(string: did))
            )
            
            if responseCode == 200, let profileData = profileData {
                profile = profileData
            } else {
                profileError = NSError(domain: "ProfileError", code: responseCode, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to load profile with code \(responseCode)"
                ])
            }
        } catch {
            profileError = error
        }
        
        isLoadingProfile = false
    }

    @MainActor
    func createPost() async throws {
        await applyProfileLabels()

        // Get clean text for Bluesky (without genmoji, which are handled as media)
        let cleanText = getCleanTextForBluesky()
        let parsedContent = PostParser.parsePostContent(cleanText, resolvedProfiles: resolvedProfiles)
        let selfLabels = ComAtprotoLabelDefs.SelfLabels(
            values: selectedLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) }
        )

        // Use determineBestEmbed to determine the appropriate embed
        let embed = try await determineBestEmbed()
        
        // Get threadgate settings
        let allowRules = threadgateSettings.toAllowUnions()
        let useThreadgate = !threadgateSettings.allowEverybody
        
        try await appState.createNewPost(
            parsedContent.0,
            languages: selectedLanguages,
            metadata: [:],
            hashtags: parsedContent.1,
            facets: parsedContent.2,
            parentPost: parentPost,
            selfLabels: selfLabels,
            embed: embed,
            threadgateAllowRules: useThreadgate ? allowRules : nil
        )
    }
    
    /// Get clean text for Bluesky (without genmoji)
    private func getCleanTextForBluesky() -> String {
        if #available(iOS 18.1, *) {
            // Check if the attributed text contains genmoji
            let fullRange = NSRange(location: 0, length: richAttributedText.length)
            var hasGenmoji = false
            
            richAttributedText.enumerateAttribute(.adaptiveImageGlyph, in: fullRange) { value, _, stop in
                if value is NSAdaptiveImageGlyph {
                    hasGenmoji = true
                    stop.pointee = true
                }
            }
            
            if hasGenmoji {
                // Remove genmoji from text for Bluesky
                let mutableText = NSMutableAttributedString(attributedString: richAttributedText)
                var genmojiRanges: [NSRange] = []
                
                mutableText.enumerateAttribute(.adaptiveImageGlyph, in: fullRange, options: .reverse) { value, range, _ in
                    if value is NSAdaptiveImageGlyph {
                        genmojiRanges.append(range)
                    }
                }
                
                // Remove genmoji ranges
                for range in genmojiRanges {
                    mutableText.deleteCharacters(in: range)
                }
                
                return mutableText.string
            }
        }
        
        // Fallback to regular post text
        return postText
    }
    
    /// Get clean text for a thread entry (without genmoji)
    private func getCleanTextForBlueskyFromEntry(_ entry: ThreadEntry) -> String {
        // For thread entries, we use the stored text directly
        // Genmoji would have been processed when the entry was created
        return entry.text
    }
    
  func checkImageFormat(_ data: Data) -> String {
    let bytes = [UInt8](data.prefix(3))
    switch bytes {
    case [0xFF, 0xD8, 0xFF]:
      return "JPEG"
    case [0x89, 0x50, 0x4E]:
      return "PNG"
    case [0x00, 0x00, 0x01]:
      return "HEIC"
    default:
      return "Unknown"
    }
  }

  func uploadBlob(_ imageData: Data, mimeType: String) async throws
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion {
    logger.debug("Uploading blob with size: \(imageData.count) bytes")

    // Log a sample of the image data to verify it's compressed
    logger.debug("First 100 bytes of image data: \(Array(imageData.prefix(100)))")

    guard let client = appState.atProtoClient else {
      throw NSError(
        domain: "ClientError", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
    }

    let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
      data: imageData,
      mimeType: mimeType,
      stripMetadata: true
    )
    logger.debug("Upload response code: \(responseCode)")
    logger.debug("Server response: \(String(describing: blobOutput))")

    guard responseCode == 200, let blob = blobOutput?.blob else {
      throw NSError(
        domain: "BlobUploadError", code: responseCode,
        userInfo: [NSLocalizedDescriptionKey: "Failed to upload image"])
    }

    logger.debug("Server reported blob size: \(blob.size) bytes")

    // Create the image embed
    #if os(iOS)
      let aspectRatio = AppBskyEmbedDefs.AspectRatio(
        width: Int(UIImage(data: imageData)?.size.width ?? 0),
        height: Int(UIImage(data: imageData)?.size.height ?? 0))
    #elseif os(macOS)
      let aspectRatio = AppBskyEmbedImages.AspectRatio(
        width: Int(NSImage(data: imageData)?.size.width ?? 0),
        height: Int(NSImage(data: imageData)?.size.height ?? 0))
    #endif
    let image = AppBskyEmbedImages.Image(
      image: blob, alt: "Image description", aspectRatio: aspectRatio)
    let images = AppBskyEmbedImages(images: [image])

    return .appBskyEmbedImages(images)
  }

  func createImageEmbed(_ item: PhotosPickerItem) async throws
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion {
    logger.debug("Starting image embed creation")

    // Load image data
    logger.debug("Loading image data")
    guard let imageData = try await item.loadTransferable(type: Data.self) else {
      throw NSError(
        domain: "ImageLoadError", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Failed to load image data"])
    }
    logger.debug("Image data loaded, size: \(imageData.count) bytes")

    // Convert to JPEG if necessary
    logger.debug("Converting to JPEG if needed")
    let jpegData: Data
    if checkImageFormat(imageData) == "HEIC" {
      guard let converted = convertHEICToJPEG(imageData) else {
        throw NSError(
          domain: "ImageConversionError", code: 0,
          userInfo: [NSLocalizedDescriptionKey: "Failed to convert HEIC to JPEG"])
      }
      jpegData = converted
    } else if let image = PlatformImage(data: imageData) {
      guard let converted = image.jpegData(compressionQuality: 1.0) else {
        throw NSError(
          domain: "ImageConversionError", code: 0,
          userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to JPEG"])
      }
      jpegData = converted
    } else {
      throw NSError(
        domain: "ImageConversionError", code: 0,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create UIImage from data"])
    }
    logger.debug("JPEG conversion complete, new size: \(jpegData.count) bytes")

    // Compress image
    logger.debug("Compressing image")
    let finalImageData: Data
    if let image = PlatformImage(data: jpegData),
      let compressedImageData = compressImage(image) {
      finalImageData = compressedImageData
      logger.debug("Compression successful, final size: \(finalImageData.count) bytes")
    } else {
      logger.debug("Compression failed, using original JPEG data")
      finalImageData = jpegData
    }

    // Upload blob
    logger.debug("Uploading blob")
    let embed = try await uploadBlob(finalImageData, mimeType: "image/jpeg")
    logger.debug("Blob upload complete")

    return embed
  }

  func stripMetadata(from image: PlatformImage) -> Data? {
    #if os(iOS)
      guard let cgImage = image.cgImage else { return nil }
      let newImage = PlatformImage(cgImage: cgImage)
      return newImage.jpegData(compressionQuality: 1.0)
    #elseif os(macOS)
      guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        return nil
      }
      let newImage = PlatformImage(cgImage: cgImage, size: image.size)
      return newImage.jpegData(compressionQuality: 1.0)
    #endif
  }

  func convertHEICToJPEG(_ heicData: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(heicData as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return nil
    }
    #if os(iOS)
      let image = PlatformImage(cgImage: cgImage)
    #elseif os(macOS)
      let image = PlatformImage(cgImage: cgImage, size: .zero)
    #endif
    return image.jpegData(compressionQuality: 1.0)
  }

  func compressImage(_ image: PlatformImage, maxSizeInBytes: Int = 900_000) -> Data? {
    var compression: CGFloat = 1.0
    var imageData = image.jpegData(compressionQuality: compression)

    while let data = imageData, data.count > maxSizeInBytes && compression > 0.01 {
      compression -= 0.1
      imageData = image.jpegData(compressionQuality: compression)
    }

    if let bestData = imageData, bestData.count > maxSizeInBytes {
      let scale = sqrt(CGFloat(maxSizeInBytes) / CGFloat(bestData.count))
      #if os(iOS)
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        UIGraphicsBeginImageContextWithOptions(newSize, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resizedImage?.jpegData(compressionQuality: 0.7)
      #elseif os(macOS)
        let newSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let resizedImage = NSImage(size: newSize)
        resizedImage.lockFocus()
        image.draw(
          in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1.0)
        resizedImage.unlockFocus()
        return resizedImage.jpegData(compressionQuality: 0.7)
      #endif
    }

    return imageData
  }

  private func handleDetectedURLs(_ urls: [String]) {
    // Find new URLs that we haven't seen before
    let newURLs = urls.filter { !detectedURLs.contains($0) }

    if !newURLs.isEmpty {
      for url in newURLs {
        detectedURLs.append(url)

        // Fetch URL card
        Task {
          do {
            isLoadingURLCard = true
            let card = try await URLCardService.fetchURLCard(for: url)
            await MainActor.run {
              self.urlCards[url] = card
              self.isLoadingURLCard = false
            }
          } catch {
            logger.debug("Error fetching URL card: \(error)")
            await MainActor.run {
              self.isLoadingURLCard = false
            }
          }
        }
      }
    }

    // Remove URLs that are no longer in the post
    detectedURLs = detectedURLs.filter { urls.contains($0) }
  }

  func removeURLCard(for url: String) {
    urlCards.removeValue(forKey: url)
    detectedURLs.removeAll { $0 == url }

    // Optionally remove the URL from the post text
    if let range = postText.range(of: url) {
      postText.removeSubrange(range)
      updatePostContent()
    }
  }
  func createExternalEmbed(from card: URLCardResponse, originalURL: String) async throws
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion {
    // Always use the original URL if the card URL is empty or invalid
    let urlToUse = card.url.isEmpty ? originalURL : card.url

    guard let uri = URI(urlToUse) else {
      throw NSError(
        domain: "EmbedError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
    }

    var thumb: Blob?

    // If we have an image URL, try to fetch and upload it as a blob
    if let imageURL = URL(string: card.image), !card.image.isEmpty {
      do {
        let (imageData, _) = try await URLSession.shared.data(from: imageURL)

        // Upload the image as a blob
        guard let client = appState.atProtoClient else {
          throw NSError(
            domain: "ClientError", code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Client not initialized"])
        }

        let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
          data: imageData,
          mimeType: imageData.mimeType(),
          stripMetadata: true
        )

        if responseCode == 200, let blob = blobOutput?.blob {
          thumb = blob
        }
      } catch {
        logger.debug("Failed to get thumb image, continuing without it: \(error)")
        // Continue without the thumbnail
      }
    }

    // Create the external object with validation and fallbacks
    let external = AppBskyEmbedExternal.External(
      uri: uri,
      title: card.title.isEmpty ? "" : card.title,
      description: card.description.isEmpty ? originalURL : card.description,
      thumb: thumb
    )

    return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
  }

  @MainActor
  func determineBestEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
    // If we have a quoted post, create a quote embed
    if let quotedPost = quotedPost {
      // Create a quote embed
      return .appBskyEmbedRecord(AppBskyEmbedRecord(record: ComAtprotoRepoStrongRef(uri: quotedPost.uri, cid: quotedPost.cid)))

    }

    // Check for GIF first (highest priority for rich media)
    if selectedGif != nil {
      return try await createGifEmbed()
    }

    // Check for video (second priority)
    if videoItem != nil {
      return try await createVideoEmbed()
    }

    // If there are media items, prioritize them
    if !mediaItems.isEmpty {
      return try await createImagesEmbed()
    }

    // ✅ CLEANED: Removed legacy single image handling - now all images in mediaItems

    // Otherwise, use the first URL card if available
    if let firstURL = detectedURLs.first, let card = urlCards[firstURL] {
      return try await createExternalEmbed(from: card, originalURL: firstURL)
    }

    // No embed
    return nil
  }

  // Add method to check if a URL will be used as embed
  func willBeUsedAsEmbed(for url: String) -> Bool {
    // If there's a GIF, video or image selected, no URL will be used as embed
    if selectedGif != nil || videoItem != nil || !mediaItems.isEmpty {
      return false
    }

    // Otherwise, only the first URL with a card will be used as embed
    return url == detectedURLs.first && urlCards[url] != nil
  }

  // MARK: - GIF Support
  var selectedGif: TenorGif?
  var showingGifPicker = false
  
  func selectGif(_ gif: TenorGif) {
    selectedGif = gif
    showingGifPicker = false
  }
  
  func removeSelectedGif() {
    selectedGif = nil
  }
  
  func createGifEmbed() async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
    guard let gif = selectedGif else { return nil }
    
    // Create external embed like Bluesky does - prioritize GIF format for proper animation
    let gifURL: String
    let description = gif.content_description.isEmpty ? "Animated GIF" : gif.content_description
    
    // Use GIF format with sizing parameters like Bluesky does
    // Priority: gif > mediumgif > tinygif (avoid MP4 for external embeds)
    if let gifFormat = gif.media_formats.gif {
      // Add sizing parameters if available from dims
      var url = gifFormat.url
      if gifFormat.dims.count >= 2 {
        let width = gifFormat.dims[0]
        let height = gifFormat.dims[1]
        // Add Bluesky-style sizing parameters
        if url.contains("?") {
          url += "&hh=\(height)&ww=\(width)"
        } else {
          url += "?hh=\(height)&ww=\(width)"
        }
      }
      gifURL = url
    } else if let mediumgif = gif.media_formats.mediumgif {
      var url = mediumgif.url
      if mediumgif.dims.count >= 2 {
        let width = mediumgif.dims[0]
        let height = mediumgif.dims[1]
        if url.contains("?") {
          url += "&hh=\(height)&ww=\(width)"
        } else {
          url += "?hh=\(height)&ww=\(width)"
        }
      }
      gifURL = url
    } else if let tinygif = gif.media_formats.tinygif {
      var url = tinygif.url
      if tinygif.dims.count >= 2 {
        let width = tinygif.dims[0]
        let height = tinygif.dims[1]
        if url.contains("?") {
          url += "&hh=\(height)&ww=\(width)"
        } else {
          url += "?hh=\(height)&ww=\(width)"
        }
      }
      gifURL = url
    } else {
      throw NSError(domain: "GifEmbedError", code: 0, userInfo: [NSLocalizedDescriptionKey: "No suitable GIF format found"])
    }
    
    guard let uri = URI(gifURL) else {
      throw NSError(domain: "GifEmbedError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid GIF URL"])
    }
    
    // Try to get a thumbnail for the external embed
    var thumb: Blob?
    if let previewFormat = gif.media_formats.gifpreview ?? gif.media_formats.tinygifpreview {
      do {
        guard let client = appState.atProtoClient,
              let thumbURL = URL(string: previewFormat.url) else {
          throw NSError(domain: "ThumbError", code: 0, userInfo: nil)
        }
        
        let (thumbData, _) = try await URLSession.shared.data(from: thumbURL)
        
        let (responseCode, blobOutput) = try await client.com.atproto.repo.uploadBlob(
          data: thumbData,
          mimeType: "image/jpeg",
          stripMetadata: true
        )
        
        if responseCode == 200, let blob = blobOutput?.blob {
          thumb = blob
        }
      } catch {
        logger.debug("Failed to upload GIF thumbnail: \(error)")
        // Continue without thumbnail
      }
    }
    
    // Create external embed like Bluesky does
    let external = AppBskyEmbedExternal.External(
      uri: uri,
      title: gif.title.isEmpty ? "GIF" : gif.title,
      description: description,
      thumb: thumb
    )
    
    return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
  }

  // ✅ CLEANED: Removed legacy properties selectedImageItem and selectedImage
  // All media now unified in mediaItems array
}

extension PostComposerViewModel {
  // MARK: - Thread Management

  // Enable thread mode and initialize with a single entry
  func enableThreadMode() {
    // Save the current post state before enabling thread mode
    let currentPostState = ThreadEntry(
      text: postText,
      mediaItems: mediaItems,
      videoItem: videoItem,
      detectedURLs: detectedURLs,
      urlCards: urlCards
    )

    isThreadMode = true

    // Initialize with the current post as the first entry
    threadEntries = [currentPostState]
    currentThreadEntryIndex = 0
  }

  // Disable thread mode
  func disableThreadMode() {
    isThreadMode = false
    // Save the current post state for when we exit thread mode
    let currentPostState = ThreadEntry(
      text: postText,
      mediaItems: mediaItems,
      videoItem: videoItem,
      detectedURLs: detectedURLs,
      urlCards: urlCards
    )
    threadEntries = [currentPostState]
    currentThreadEntryIndex = 0
  }

  // Add a new thread entry
  func addThreadEntry() {
    // Save current state first if we're in thread mode
    if isThreadMode {
      saveCurrentEntryState()
    }

    let newEntry = ThreadEntry()
    threadEntries.append(newEntry)
    currentThreadEntryIndex = threadEntries.count - 1

    // Load the new (empty) entry
    loadEntryState()
  }

  // Remove a thread entry
  func removeThreadEntry(at index: Int) {
    guard index < threadEntries.count, threadEntries.count > 1 else { return }

    threadEntries.remove(at: index)

    // Adjust current index if needed
    if currentThreadEntryIndex >= threadEntries.count {
      currentThreadEntryIndex = threadEntries.count - 1
    }

    // Load the entry at the new current index
    loadEntryState()
  }

  // Navigate to next thread entry
  func nextThreadEntry() {
    if currentThreadEntryIndex < threadEntries.count - 1 {
      saveCurrentEntryState()
      currentThreadEntryIndex += 1
      loadEntryState()
    } else {
      addThreadEntry()
    }
  }

  // Navigate to previous thread entry
  func previousThreadEntry() {
    if currentThreadEntryIndex > 0 {
      saveCurrentEntryState()
      currentThreadEntryIndex -= 1
      loadEntryState()
    }
  }

  // Save current UI state to the current thread entry
  func saveCurrentEntryState() {
    guard isThreadMode, currentThreadEntryIndex < threadEntries.count else { return }

    // Get the parsed content with facets and hashtags
    let parsedContent = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)

    threadEntries[currentThreadEntryIndex].text = postText
    threadEntries[currentThreadEntryIndex].mediaItems = mediaItems
    threadEntries[currentThreadEntryIndex].videoItem = videoItem
    threadEntries[currentThreadEntryIndex].detectedURLs = detectedURLs
    threadEntries[currentThreadEntryIndex].urlCards = urlCards
    threadEntries[currentThreadEntryIndex].facets = parsedContent.2
    threadEntries[currentThreadEntryIndex].hashtags = parsedContent.1
    
    logger.debug("Saved thread entry \\(currentThreadEntryIndex): text='\\(postText.prefix(50))...', mediaCount=\\(mediaItems.count)")
  }

  // Load state from current thread entry into UI
  func loadEntryState() {
    guard isThreadMode, let entry = currentThreadEntry else { return }

    postText = entry.text
    mediaItems = entry.mediaItems
    videoItem = entry.videoItem
    detectedURLs = entry.detectedURLs
    urlCards = entry.urlCards

    // Sync the rich attributed text to match the loaded text
    syncAttributedTextFromPlainText()

    // Update any UI that depends on the text
    updatePostContent()
    
    logger.debug("Loaded thread entry \\(currentThreadEntryIndex): text='\\(entry.text.prefix(50))...', mediaCount=\\(entry.mediaItems.count)")
  }

  // MARK: - Helper Methods for PostComposerView
  
  // Alias methods for PostComposerView compatibility
  func updateCurrentThreadEntry() {
    saveCurrentEntryState()
  }
  
  func addNewThreadEntry() {
    addThreadEntry()
  }

  // Create and publish a thread
  @MainActor
  func createThread() async throws {
    // First save the current state
    saveCurrentEntryState()

    // Setup arrays to hold processed content for each post
    var postTexts: [String] = []
    var embeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?] = []
    var facets: [[AppBskyRichtextFacet]?] = []
    var hashtags: [[String]] = []

    // Process each entry
    for entry in threadEntries {
      // Add the post text (clean for Bluesky)
      let cleanText = getCleanTextForBlueskyFromEntry(entry)
      postTexts.append(cleanText)

      // Add facets if available, or calculate them if not
      if let existingFacets = entry.facets {
        facets.append(existingFacets)
      } else {
        let parsedContent = PostParser.parsePostContent(
          entry.text, resolvedProfiles: resolvedProfiles)
        facets.append(parsedContent.2)
      }

      // Add hashtags
      hashtags.append(entry.hashtags)

      // Determine embed for this entry
      if let videoItem = entry.videoItem {
        // Set the current videoItem to the entry's videoItem for processing
        self.videoItem = videoItem
        let videoEmbed = try await createVideoEmbed()
        embeds.append(videoEmbed)
      } else if !entry.mediaItems.isEmpty {
        // Set the current mediaItems to the entry's mediaItems for processing
        self.mediaItems = entry.mediaItems
        let imagesEmbed = try await createImagesEmbed()
        embeds.append(imagesEmbed)
      } else if let firstURL = entry.detectedURLs.first, let card = entry.urlCards[firstURL] {
        let urlEmbed = try await createExternalEmbed(from: card, originalURL: firstURL)
        embeds.append(urlEmbed)
      } else {
        embeds.append(nil)
      }
    }

    await applyProfileLabels()

    let selfLabels = ComAtprotoLabelDefs.SelfLabels(
      values: selectedLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) }
    )

    // Get threadgate settings for the thread
    let allowRules = threadgateSettings.toAllowUnions()
    let useThreadgate = !threadgateSettings.allowEverybody

    // Post the thread
    try await appState.createThread(
      posts: postTexts,
      languages: selectedLanguages,
      selfLabels: selfLabels,
      hashtags: hashtags.first ?? [],
      facets: facets,
      embeds: embeds,
      threadgateAllowRules: useThreadgate ? allowRules : nil
    )
  }
}

extension Data {
  func mimeType() -> String {
    var b: UInt8 = 0
    self.copyBytes(to: &b, count: 1)
    switch b {
    case 0xFF:
      return "image/jpeg"
    case 0x89:
      return "image/png"
    case 0x47:
      return "image/gif"
    case 0x49, 0x4D:
      return "image/tiff"
    default:
      return "application/octet-stream"
    }
  }
}
