import AVFoundation
import NaturalLanguage
import Petrel
import PhotosUI
import SwiftUI

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
  var videoItem: PostComposerViewModel.MediaItem? = nil
  var detectedURLs: [String] = []
  var urlCards: [String: URLCardResponse] = [:]
  var facets: [AppBskyRichtextFacet]? = nil
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
  var postText: String = ""
  var selectedLanguages: [LanguageCodeContainer] = []
  var suggestedLanguage: LanguageCodeContainer?
  var selectedLabels: Set<ComAtprotoLabelDefs.LabelValue> = []
  var mentionSuggestions: [AppBskyActorDefs.ProfileViewBasic] = []
  var showLabelSelector = false
  var alertItem: AlertItem?

  let parentPost: AppBskyFeedDefs.PostView?
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
    // Only disable if: no content at all OR over character limit OR currently uploading
    (postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && videoItem == nil
      && mediaItems.isEmpty && selectedImageItem == nil && detectedURLs.isEmpty)
      || isOverCharacterLimit || isVideoUploading
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
    let pickerItem: PhotosPickerItem
    var image: Image?
    var altText: String = ""
    var isLoading: Bool = true
    var aspectRatio: CGSize?
    var rawData: Data?
    var rawVideoURL: URL?
    var rawVideoAsset: AVAsset?
    var videoData: Data?

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

  // Multiple images selection
  var selectedImageItems: [PhotosPickerItem] = []

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

  init(parentPost: AppBskyFeedDefs.PostView? = nil, appState: AppState) {
    self.parentPost = parentPost
    self.appState = appState

    // Initialize MediaUploadManager if client is available
    if let client = appState.atProtoClient {
      self.mediaUploadManager = MediaUploadManager(client: client)
    }
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
    selectedImageItem = nil
    selectedImage = nil

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
      selectedImageItem = nil
      selectedImage = nil

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

      // Validate the selection is a video
      logger.debug("DEBUG: Checking content types")
      if !videoItem.pickerItem.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
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
      var asset: AVAsset? = nil
      var videoSize: CGSize? = nil
      var videoDuration: Double = 0.0

      // Check if we can load as AVAsset directly
      logger.debug("DEBUG: Attempting to load as AVAsset")
      if let videoURL = try? await videoItem.pickerItem.loadTransferable(type: URL.self) {
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
      // Approach 2: Try loading as Data
      else if let videoData = try? await videoItem.pickerItem.loadTransferable(type: Data.self) {
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
      // Approach 3: Fallback to URL (may not work with PhotosUI security)
      else if let videoURL = try? await videoItem.pickerItem.loadTransferable(type: URL.self) {
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

      imageGenerator.generateCGImagesAsynchronously(forTimes: [timeValue]) {
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
              NSUnderlyingErrorKey: error,
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

    let item = mediaItems[index].pickerItem

    do {
      let (data, uiImage) = try await loadImageData(from: item)

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
    if let storedLanguages = UserDefaults.standard.stringArray(forKey: "userPreferredLanguages"),
      !storedLanguages.isEmpty
    {
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

  func updatePostContent() {
    suggestedLanguage = detectLanguage()

    // Parse the text content to get URLs and update mentions
    let (_, _, _, urls) = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)

    // Handle URLs
    handleDetectedURLs(urls)

    Task {
      await updateMentionSuggestions()
    }
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
      let altText = item.altText.isEmpty ? "Image" : item.altText
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
      let compressed = compressImage(image, maxSizeInBytes: 900_000)
    {
      processedData = compressed
    }

    return processedData
  }

  @MainActor
  func loadSelectedImage() async {
    guard let item = selectedImageItem else { return }

    // Check if we've already processed this image
    if let identifier = item.itemIdentifier,
      let cachedData = processedImageCache[identifier]
    {
      #if os(iOS)
        if let uiImage = UIImage(data: cachedData) {
          selectedImage = Image(uiImage: uiImage)
        }
      #elseif os(macOS)
        if let nsImage = NSImage(data: cachedData) {
          selectedImage = Image(nsImage: nsImage)
        }
      #endif
      return
    }

    // Load and process the image asynchronously
    Task {
      guard let data = try? await item.loadTransferable(type: Data.self) else { return }

      // Store in cache if possible
      if let identifier = item.itemIdentifier {
        processedImageCache[identifier] = data
      }

      #if os(iOS)
        if let uiImage = UIImage(data: data) {
          selectedImage = Image(uiImage: uiImage)
        }
      #elseif os(macOS)
        if let nsImage = NSImage(data: data) {
          selectedImage = Image(nsImage: nsImage)
        }
      #endif
    }
  }

  // Add cleanup method
  func cleanup() {
    processedImageCache.removeAll()
  }

  private func detectLanguage() -> LanguageCodeContainer? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(postText)
    if let detectedNLLang = recognizer.dominantLanguage {
      let detectedLang = localeLanguage(from: detectedNLLang)
      return LanguageCodeContainer(lang: detectedLang)
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
    UserDefaults.standard.set(languageStrings, forKey: "userPreferredLanguages")
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

        let parsedContent = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)
        let selfLabels = ComAtprotoLabelDefs.SelfLabels(
            values: selectedLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) }
        )

        // Use determineBestEmbed to determine the appropriate embed
        let embed = try await determineBestEmbed()
        
        // Get threadgate settings
        let allowRules = threadgateSettings.toAllowUnions()
        let useThreadgate = !threadgateSettings.allowEverybody
        
        try await appState.createNewPost(
            parsedContent.text,
            languages: selectedLanguages,
            metadata: [:],
            hashtags: parsedContent.hashtags,
            facets: parsedContent.facets,
            parentPost: parentPost,
            selfLabels: selfLabels,
            embed: embed,
            threadgateAllowRules: useThreadgate ? allowRules : nil
        )
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
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion
  {
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
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion
  {
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
      let compressedImageData = compressImage(image)
    {
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
    -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion
  {
    // Always use the original URL if the card URL is empty or invalid
    let urlToUse = card.url.isEmpty ? originalURL : card.url

    guard let uri = URI(urlToUse) else {
      throw NSError(
        domain: "EmbedError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
    }

    var thumb: Blob? = nil

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
    // Check for video first (highest priority)
      if videoItem != nil {
      return try await createVideoEmbed()
    }

    // If there are media items, prioritize them
    if !mediaItems.isEmpty {
      return try await createImagesEmbed()
    }

    // Handle legacy single image if it exists
    if let selectedImageItem = selectedImageItem {
      return try await createImageEmbed(selectedImageItem)
    }

    // Otherwise, use the first URL card if available
    if let firstURL = detectedURLs.first, let card = urlCards[firstURL] {
      return try await createExternalEmbed(from: card, originalURL: firstURL)
    }

    // No embed
    return nil
  }

  // Add method to check if a URL will be used as embed
  func willBeUsedAsEmbed(for url: String) -> Bool {
    // If there's a video or image selected, no URL will be used as embed
    if videoItem != nil || !mediaItems.isEmpty || selectedImageItem != nil {
      return false
    }

    // Otherwise, only the first URL with a card will be used as embed
    return url == detectedURLs.first && urlCards[url] != nil
  }

  // MARK: - Legacy Properties (keeping for compatibility)
  var selectedImageItem: PhotosPickerItem?
  var selectedImage: Image?
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
    threadEntries[currentThreadEntryIndex].facets = parsedContent.facets
    threadEntries[currentThreadEntryIndex].hashtags = parsedContent.hashtags
  }

  // Load state from current thread entry into UI
  func loadEntryState() {
    guard isThreadMode, let entry = currentThreadEntry else { return }

    postText = entry.text
    mediaItems = entry.mediaItems
    videoItem = entry.videoItem
    detectedURLs = entry.detectedURLs
    urlCards = entry.urlCards

    // Update any UI that depends on the text
    updatePostContent()
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
      // Add the post text
      postTexts.append(entry.text)

      // Add facets if available, or calculate them if not
      if let existingFacets = entry.facets {
        facets.append(existingFacets)
      } else {
        let parsedContent = PostParser.parsePostContent(
          entry.text, resolvedProfiles: resolvedProfiles)
        facets.append(parsedContent.facets)
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
