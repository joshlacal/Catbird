import Foundation
import Petrel
import SwiftUI

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

// MARK: - Thread Models

struct ThreadEntry: Identifiable {
    let id = UUID()
    var text: String = ""
    var mediaItems: [PostComposerViewModel.MediaItem] = []
    var videoItem: PostComposerViewModel.MediaItem?
    var selectedGif: TenorGif?
    var detectedURLs: [String] = []
    var urlCards: [String: URLCardResponse] = [:]
    var facets: [AppBskyRichtextFacet]?
    var hashtags: [String] = []
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

struct PostComposerDraft {
  let postText: String
  let mediaItems: [PostComposerViewModel.MediaItem]
  let videoItem: PostComposerViewModel.MediaItem?
  let selectedGif: TenorGif?
  let selectedLanguages: [LanguageCodeContainer]
  let selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
  let outlineTags: [String]
  let threadEntries: [ThreadEntry]
  let isThreadMode: Bool
  let currentThreadIndex: Int
}

// MARK: - Language Utilities

import NaturalLanguage

func localeLanguage(from nlLanguage: NLLanguage) -> Locale.Language {
    // NLLanguage uses ISO 639-1 or 639-2 codes, which are compatible with BCP-47
    return Locale.Language(identifier: nlLanguage.rawValue)
}