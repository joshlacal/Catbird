import CryptoKit
import Foundation
import Petrel
import SwiftUI

// MARK: - Tenor API Models (shared with GifPickerView)

struct TenorGif: Codable, Identifiable, Hashable {
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

struct TenorMediaFormats: Codable, Hashable {
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

struct TenorMediaItem: Codable, Hashable {
    let url: String
    let dims: [Int]
    let duration: Double?
    let preview: String
    let size: Int?
}

// MARK: - Thread Models

struct ThreadEntry: Identifiable, Hashable {
    var id = UUID()
    var text: String = ""
    var mediaItems: [PostComposerViewModel.MediaItem] = []
    var videoItem: PostComposerViewModel.MediaItem?
    var selectedGif: TenorGif?
    var detectedURLs: [String] = []
    var urlCards: [String: URLCardResponse] = [:]
    var selectedEmbedURL: String?
    var urlsKeptForEmbed: Set<String> = []
    var facets: [AppBskyRichtextFacet]?
    var hashtags: [String] = []
    var selectedLanguages: [LanguageCodeContainer] = []
    var outlineTags: [String] = []
    var quotedPost: AppBskyFeedDefs.PostView?
    // Keep the strong reference while its display metadata is loading.
    var draftQuotedPostURI: String?
    var draftQuotedPostCID: String?
}

// MARK: - Submit Validation

enum PostComposerAltTextRequirement {
    static func hasMissingAltText(
        imageAltTexts: [String],
        videoAltText: String?
    ) -> Bool {
        let isBlank: (String) -> Bool = {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return imageAltTexts.contains(where: isBlank)
            || videoAltText.map(isBlank) == true
    }
}

struct PostComposerSubmitValidationState: Equatable {
    enum Reason: Equatable {
        case emptyContent
        case overCharacterLimit(current: Int, max: Int)
        case threadPostOverCharacterLimit(postNumber: Int, over: Int)
        case posting
        case videoPreparing
        case mediaPreparing
        case mediaUnavailable
        case videoBlocked(String)
        case missingAltText
        case replyLoading
        case replyUnavailable
        case quoteLoading
        case pendingAudio
    }

    let canSubmit: Bool
    let reason: Reason?

    var message: String? {
        switch reason {
        case .emptyContent:
            return "Add text or media before posting."
        case .overCharacterLimit(let current, let max):
            let over = current - max
            return "\(over) character\(over == 1 ? "" : "s") over the limit."
        case .threadPostOverCharacterLimit(let postNumber, let over):
            return "Post \(postNumber) is \(over) character\(over == 1 ? "" : "s") over the limit."
        case .posting:
            return "Posting…"
        case .mediaPreparing:
            return "Media is still preparing."
        case .mediaUnavailable:
            return "An attachment couldn’t be loaded. Retry it or remove it before posting."
        case .videoPreparing:
            return "Video is still preparing."
        case .videoBlocked(let reason):
            return reason
        case .missingAltText:
            return "Add alt text to every media attachment before posting."
        case .replyLoading:
            return "Loading the original post…"
        case .replyUnavailable:
            return "The post you’re replying to is unavailable."
        case .quoteLoading:
            return "The quoted post must load before this draft can be posted."
        case .pendingAudio:
            return "Finish or remove your audio attachment before posting."
        case nil:
            return nil
        }
    }

    var shouldShowInlineMessage: Bool {
        switch reason {
        case .overCharacterLimit, .threadPostOverCharacterLimit, .mediaPreparing, .mediaUnavailable, .videoPreparing, .videoBlocked, .missingAltText, .replyLoading, .replyUnavailable, .quoteLoading, .pendingAudio:
            return true
        case .emptyContent, .posting, nil:
            return false
        }
    }
}

// MARK: - Platform Compatibility

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(macOS)
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

// MARK: - Draft State Management

struct PostComposerDraft: Codable, Hashable {
  let postText: String
  let mediaItems: [CodableMediaItem]
  let videoItem: CodableMediaItem?
  let selectedGif: TenorGif?
  let selectedLanguages: [LanguageCodeContainer]
  let selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  let outlineTags: [String]
  let threadEntries: [CodableThreadEntry]
  let isThreadMode: Bool
  let currentThreadIndex: Int
  let parentPostURI: String?
  let quotedPostURI: String?
  var quotedPostCID: String? = nil
  var draftPostgateEmbeddingRules: [AppBskyDraftDefs.DraftPostgateEmbeddingRulesUnion]? = nil
  var draftThreadgateAllow: [AppBskyDraftDefs.DraftThreadgateAllowUnion]? = nil
  // Distinguishes an explicitly unrestricted draft from a legacy draft with no settings.
  var hasDraftInteractionSettings: Bool? = nil
  var pendingAudioURLString: String? = nil
  var pendingAudioThreadEntryID: UUID? = nil
}

// MARK: - Codable Wrappers for Draft State

struct CodableMediaItem: Codable, Hashable {
  // Optional for compatibility with drafts saved before attachment IDs were persisted.
  var attachmentID: UUID? = nil
  let altText: String
  let aspectRatio: CGSize?
  let isLoading: Bool
  let isAudioVisualizerVideo: Bool
  let isGifConversion: Bool
  // Optional persisted reference to local files (used for share extension imports)
  let rawVideoURLString: String?
  let rawImageURLString: String?
  let caption: VideoCaption?

  init(from mediaItem: PostComposerViewModel.MediaItem) {
    self.attachmentID = mediaItem.id
    self.altText = mediaItem.altText
    self.aspectRatio = mediaItem.aspectRatio
    self.isLoading = mediaItem.isLoading
    self.isAudioVisualizerVideo = mediaItem.isAudioVisualizerVideo
    self.isGifConversion = mediaItem.isGifConversion
    self.rawVideoURLString = mediaItem.rawVideoURL?.absoluteString
    self.caption = mediaItem.caption
    // Persist image data to a temp file so it survives draft serialization (e.g. account switch)
    if let rawData = mediaItem.rawData {
      self.rawImageURLString = CodableMediaItem.persistImageData(rawData) ?? mediaItem.rawImageURL?.absoluteString
    } else {
      self.rawImageURLString = mediaItem.rawImageURL?.absoluteString
    }
  }

  /// Write image data to a file in the shared drafts directory, returning the file URL string.
  /// Files are named by content, so autosaves and thread copies of the same image reuse one file.
  private static func persistImageData(_ data: Data) -> String? {
    guard let container = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
    ) else { return nil }
    let draftsDir = container.appendingPathComponent("SharedDrafts", isDirectory: true)
    try? FileManager.default.createDirectory(at: draftsDir, withIntermediateDirectories: true)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let filename = "draft_image_\(digest).jpg"
    let fileURL = draftsDir.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: fileURL.path) {
      return fileURL.absoluteString
    }
    do {
      try data.write(to: fileURL, options: .atomic)
      return fileURL.absoluteString
    } catch {
      return nil
    }
  }
  
  func toMediaItem() -> PostComposerViewModel.MediaItem {
    var item = PostComposerViewModel.MediaItem(id: attachmentID ?? UUID())
    item.altText = altText
    item.aspectRatio = aspectRatio
    // A serialized flag does not restore the task that owned it.
    item.isLoading = false
    item.rawImageURL = rawImageURLString.flatMap(URL.init(string:))
    item.isAudioVisualizerVideo = isAudioVisualizerVideo
    item.isGifConversion = isGifConversion
    if let rawVideoURLString, let url = URL(string: rawVideoURLString) {
      item.rawVideoURL = url
    }
    if let rawImageURLString, let url = URL(string: rawImageURLString),
       let data = try? Data(contentsOf: url) {
      if isGifConversion && rawVideoURLString == nil {
        // Failed GIF preparation remains a retryable video source, never a still image post.
        item.rawData = data
      } else if let platformImage = PlatformImage(data: data) {
        item.rawData = data
        #if os(iOS)
        item.image = Image(uiImage: platformImage)
        #elseif os(macOS)
        item.image = Image(nsImage: platformImage)
        #endif
        item.aspectRatio = CGSize(width: platformImage.imageSize.width, height: platformImage.imageSize.height)
        item.isLoading = false
      }
    }
    item.caption = caption
    return item
  }
}

extension CodableMediaItem {
  init(
    altText: String,
    aspectRatio: CGSize?,
    isLoading: Bool,
    isAudioVisualizerVideo: Bool,
    isGifConversion: Bool = false,
    rawVideoURLString: String?,
    rawImageURLString: String?,
    caption: VideoCaption? = nil
  ) {
    self.altText = altText
    self.aspectRatio = aspectRatio
    self.isLoading = isLoading
    self.isAudioVisualizerVideo = isAudioVisualizerVideo
    self.isGifConversion = isGifConversion
    self.rawVideoURLString = rawVideoURLString
    self.rawImageURLString = rawImageURLString
    self.caption = caption
  }
}

struct CodableThreadEntry: Codable, Hashable {
  let text: String
  let mediaItems: [CodableMediaItem]
  let videoItem: CodableMediaItem?
  let selectedGif: TenorGif?
  let detectedURLs: [String]
  let urlCards: [String: URLCardResponse]
  let selectedEmbedURL: String?
  let urlsKeptForEmbed: Set<String>
  let hashtags: [String]
  let parentPostURI: String?
  let quotedPostURI: String?
  var quotedPostCID: String? = nil
  var draftEntryID: UUID? = nil
  
  init(from threadEntry: ThreadEntry, parentPost: AppBskyFeedDefs.PostView?, quotedPost: AppBskyFeedDefs.PostView?, parentPostURI: String? = nil) {
    self.draftEntryID = threadEntry.id
    self.text = threadEntry.text
    self.mediaItems = threadEntry.mediaItems.map(CodableMediaItem.init)
    self.videoItem = threadEntry.videoItem.map(CodableMediaItem.init)
    self.selectedGif = threadEntry.selectedGif
    self.detectedURLs = threadEntry.detectedURLs
    self.urlCards = threadEntry.urlCards
    self.selectedEmbedURL = threadEntry.selectedEmbedURL
    self.urlsKeptForEmbed = threadEntry.urlsKeptForEmbed
    self.hashtags = threadEntry.hashtags
    self.parentPostURI = parentPost?.uri.uriString() ?? parentPostURI
    let quote = threadEntry.quotedPost ?? quotedPost
    self.quotedPostURI = threadEntry.draftQuotedPostURI ?? quote?.uri.uriString()
    self.quotedPostCID = threadEntry.draftQuotedPostCID ?? quote?.cid.string
  }
  
  func toThreadEntry() -> ThreadEntry {
    var entry = ThreadEntry()
    entry.id = draftEntryID ?? UUID()
    entry.text = text
    entry.mediaItems = mediaItems.map { $0.toMediaItem() }
    entry.videoItem = videoItem?.toMediaItem()
    entry.selectedGif = selectedGif
    entry.detectedURLs = detectedURLs
    entry.urlCards = urlCards
    entry.selectedEmbedURL = selectedEmbedURL
    entry.urlsKeptForEmbed = urlsKeptForEmbed
    entry.hashtags = hashtags
    entry.draftQuotedPostURI = quotedPostURI
    entry.draftQuotedPostCID = quotedPostCID
    return entry
  }
}

// MARK: - Language Utilities

import NaturalLanguage

func localeLanguage(from nlLanguage: NLLanguage) -> Locale.Language {
    // NLLanguage uses ISO 639-1 or 639-2 codes, which are compatible with BCP-47
    return Locale.Language(identifier: nlLanguage.rawValue)
}
