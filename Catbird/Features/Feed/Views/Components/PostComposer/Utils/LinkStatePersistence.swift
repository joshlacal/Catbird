//
//  LinkStatePersistence.swift
//  Catbird
//
//  Enhanced link state persistence for drafts and thread mode compatibility
//

import Foundation
import SwiftUI
import os
import Petrel

// MARK: - Link State Persistence

@available(iOS 16.0, macOS 13.0, *)
struct LinkStatePersistence {
    static let logger = Logger(subsystem: "blue.catbird", category: "LinkState.Persistence")
    
    // MARK: - Codable Link Facet
    
    /// Codable version of RichTextFacetUtils.LinkFacet for persistence
    struct CodableLinkFacet: Codable, Identifiable {
        let id: UUID
        let range: CodableNSRange
        let urlString: String
        let displayText: String
        
        init(from linkFacet: RichTextFacetUtils.LinkFacet) {
            self.id = linkFacet.id
            self.range = CodableNSRange(from: linkFacet.range)
            self.urlString = linkFacet.url.absoluteString
            self.displayText = linkFacet.displayText
        }
        
        func toLinkFacet() -> RichTextFacetUtils.LinkFacet? {
            guard let url = URL(string: urlString) else {
                logger.error("Failed to convert codable link facet: invalid URL \(urlString)")
                return nil
            }
            
            return RichTextFacetUtils.LinkFacet(
                range: range.toNSRange(),
                url: url,
                displayText: displayText
            )
        }
    }
    
    // MARK: - Codable NSRange
    
    struct CodableNSRange: Codable {
        let location: Int
        let length: Int
        
        init(from nsRange: NSRange) {
            self.location = nsRange.location
            self.length = nsRange.length
        }
        
        func toNSRange() -> NSRange {
            return NSRange(location: location, length: length)
        }
    }
    
    // MARK: - Enhanced Thread Entry with Links
    
    /// Enhanced ThreadEntry that includes link facets
    struct EnhancedThreadEntry: Codable {
        let text: String
        let mediaItems: [CodableMediaItem]
        let videoItem: CodableMediaItem?
        let selectedGif: TenorGif?
        let detectedURLs: [String]
        let urlCards: [String: CodableURLCard]
        let hashtags: [String]
        let linkFacets: [CodableLinkFacet]
        let richTextFacets: [CodableRichTextFacet]?
        
        init(from threadEntry: ThreadEntry, linkFacets: [RichTextFacetUtils.LinkFacet] = [], richTextFacets: [AppBskyRichtextFacet] = []) {
            self.text = threadEntry.text
            self.mediaItems = threadEntry.mediaItems.map(CodableMediaItem.init)
            self.videoItem = threadEntry.videoItem.map(CodableMediaItem.init)
            self.selectedGif = threadEntry.selectedGif
            self.detectedURLs = threadEntry.detectedURLs
            self.urlCards = threadEntry.urlCards.mapValues(CodableURLCard.init)
            self.hashtags = threadEntry.hashtags
            self.linkFacets = linkFacets.map(CodableLinkFacet.init)
            self.richTextFacets = richTextFacets.isEmpty ? nil : richTextFacets.map(CodableRichTextFacet.init)
        }
        
        func toThreadEntry() -> ThreadEntry {
            var threadEntry = ThreadEntry()
            threadEntry.text = text
            threadEntry.mediaItems = mediaItems.map { $0.toMediaItem() }
            threadEntry.videoItem = videoItem?.toMediaItem()
            threadEntry.selectedGif = selectedGif
            threadEntry.detectedURLs = detectedURLs
            threadEntry.urlCards = urlCards.mapValues { $0.toURLCard() }
            threadEntry.hashtags = hashtags
            return threadEntry
        }
        
        func getLinkFacets() -> [RichTextFacetUtils.LinkFacet] {
            return linkFacets.compactMap { $0.toLinkFacet() }
        }
        
        func getRichTextFacets() -> [AppBskyRichtextFacet] {
            return richTextFacets?.compactMap { $0.toRichTextFacet() } ?? []
        }
    }
    
    // MARK: - Codable Rich Text Facet
    
    struct CodableRichTextFacet: Codable {
        let byteStart: Int
        let byteEnd: Int
        let features: [CodableFacetFeature]
        
        init(from facet: AppBskyRichtextFacet) {
            self.byteStart = facet.index.byteStart
            self.byteEnd = facet.index.byteEnd
            self.features = facet.features.map(CodableFacetFeature.init)
        }
        
        func toRichTextFacet() -> AppBskyRichtextFacet? {
            let byteSlice = AppBskyRichtextFacet.ByteSlice(byteStart: byteStart, byteEnd: byteEnd)
            let richTextFeatures = features.compactMap { $0.toFacetFeature() }
            
            guard !richTextFeatures.isEmpty else { return nil }
            
            return AppBskyRichtextFacet(index: byteSlice, features: richTextFeatures)
        }
    }
    
    // MARK: - Codable Facet Feature
    
    struct CodableFacetFeature: Codable {
        let type: String
        let data: Data
        
        init(from feature: AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion) {
            switch feature {
            case .appBskyRichtextFacetLink(let link):
                self.type = "link"
                self.data = try! JSONEncoder().encode(link.uri.uriString())
            case .appBskyRichtextFacetMention(let mention):
                self.type = "mention"
                self.data = try! JSONEncoder().encode(mention.did.didString())
            case .appBskyRichtextFacetTag(let tag):
                self.type = "tag"
                self.data = try! JSONEncoder().encode(tag.tag)
            @unknown default:
                self.type = "unknown"
                self.data = Data()
            }
        }
        
        func toFacetFeature() -> AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion? {
            switch type {
            case "link":
                guard let uriString = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                let uri = URI(uriString: uriString)
                let link = AppBskyRichtextFacet.Link(uri: uri)
                return .appBskyRichtextFacetLink(link)
                
            case "mention":
                guard let didString = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                let did: DID
                do {
                    did = try DID(didString: didString)
                } catch {
                    return nil
                }
                let mention = AppBskyRichtextFacet.Mention(did: did)
                return .appBskyRichtextFacetMention(mention)
                
            case "tag":
                guard let tag = try? JSONDecoder().decode(String.self, from: data) else { return nil }
                let tagFeature = AppBskyRichtextFacet.Tag(tag: tag)
                return .appBskyRichtextFacetTag(tagFeature)
                
            default:
                return nil
            }
        }
    }
    
    // MARK: - Codable URL Card
    
    struct CodableURLCard: Codable {
        let url: String
        let sourceURL: String?
        let title: String
        let description: String
        let image: String
        let thumbnailBlobData: Data?
        
        init(from urlCard: URLCardResponse) {
            self.url = urlCard.url
            self.sourceURL = urlCard.sourceURL
            self.title = urlCard.title
            self.description = urlCard.description
            self.image = urlCard.image
            
            // Serialize thumbnail blob if available
            if let blob = urlCard.thumbnailBlob {
                self.thumbnailBlobData = try? JSONEncoder().encode(blob)
            } else {
                self.thumbnailBlobData = nil
            }
        }
        
        func toURLCard() -> URLCardResponse {
            var urlCard = URLCardResponse(
                error: "",
                likelyType: "text/html",
                url: url,
                title: title,
                description: description,
                image: image
            )
            urlCard.sourceURL = sourceURL
            
            // Deserialize thumbnail blob if available
            if let blobData = thumbnailBlobData,
               let blob = try? JSONDecoder().decode(Blob.self, from: blobData) {
                urlCard.thumbnailBlob = blob
            }
            
            return urlCard
        }
    }
}

// MARK: - Enhanced Draft State

@available(iOS 16.0, macOS 13.0, *)
extension PostComposerViewModel {
    
    // MARK: - Enhanced Draft Persistence
    
    /// Enhanced draft state that includes link facets and rich text
    struct EnhancedPostComposerDraft: Codable {
        let postText: String
        let mediaItems: [CodableMediaItem]
        let videoItem: CodableMediaItem?
        let selectedGif: TenorGif?
        let selectedLanguages: [LanguageCodeContainer]
        let selectedLabels: Set<ComAtprotoLabelDefs.LabelValue>
        let outlineTags: [String]
        let threadEntries: [LinkStatePersistence.EnhancedThreadEntry]
        let isThreadMode: Bool
        let currentThreadIndex: Int
        let linkFacets: [LinkStatePersistence.CodableLinkFacet]
        let richTextFacets: [LinkStatePersistence.CodableRichTextFacet]?
        let urlCards: [String: LinkStatePersistence.CodableURLCard]
        let detectedURLs: [String]
        
        @MainActor
        init(from viewModel: PostComposerViewModel) {
            // Prepare all values using locals to avoid capturing self before init completes
            let localPostText = viewModel.postText
            let localMediaItems = viewModel.mediaItems.map(CodableMediaItem.init)
            let localVideoItem = viewModel.videoItem.map(CodableMediaItem.init)
            let localSelectedGif = viewModel.selectedGif
            let localSelectedLanguages = viewModel.selectedLanguages
            let localSelectedLabels = viewModel.selectedLabels
            let localOutlineTags = viewModel.outlineTags
            let localIsThreadMode = viewModel.isThreadMode
            let localCurrentThreadIndex = viewModel.currentThreadIndex
            let localDetectedURLs = viewModel.detectedURLs
            let localURLCards = viewModel.urlCards.mapValues(LinkStatePersistence.CodableURLCard.init)
            
            // Extract link facets from attributed text
            let localLinkFacets = EnhancedPostComposerDraft.extractLinkFacetsStatic(from: viewModel.richAttributedText)
            
            // Extract rich text facets if available
            let localRichTextFacets: [LinkStatePersistence.CodableRichTextFacet]?
            if #available(iOS 26.0, macOS 15.0, *) {
                do {
                    let facets = try viewModel.attributedPostText.toFacets()
                    localRichTextFacets = facets?.map(LinkStatePersistence.CodableRichTextFacet.init)
                } catch {
                    LinkStatePersistence.logger.error("Failed to extract rich text facets for draft: \(error.localizedDescription)")
                    localRichTextFacets = nil
                }
            } else {
                localRichTextFacets = nil
            }
            
            // Enhanced thread entries with link state (no capture of self)
            let localThreadEntries: [LinkStatePersistence.EnhancedThreadEntry] = viewModel.threadEntries.enumerated().map { _, entry in
                let entryLinkFacets: [RichTextFacetUtils.LinkFacet] = EnhancedPostComposerDraft.extractLinkFacetsForThreadEntryStatic(entry)
                return LinkStatePersistence.EnhancedThreadEntry(
                    from: entry,
                    linkFacets: entryLinkFacets,
                    richTextFacets: []
                )
            }
            
            // Assign stored properties after all locals computed
            self.postText = localPostText
            self.mediaItems = localMediaItems
            self.videoItem = localVideoItem
            self.selectedGif = localSelectedGif
            self.selectedLanguages = localSelectedLanguages
            self.selectedLabels = localSelectedLabels
            self.outlineTags = localOutlineTags
            self.threadEntries = localThreadEntries
            self.isThreadMode = localIsThreadMode
            self.currentThreadIndex = localCurrentThreadIndex
            self.linkFacets = localLinkFacets
            self.richTextFacets = localRichTextFacets
            self.urlCards = localURLCards
            self.detectedURLs = localDetectedURLs
        }
        
        // Static helper to avoid capturing self before initialization
        private static func extractLinkFacetsStatic(from nsAttributedString: NSAttributedString) -> [LinkStatePersistence.CodableLinkFacet] {
            var linkFacets: [LinkStatePersistence.CodableLinkFacet] = []
            nsAttributedString.enumerateAttribute(.link, in: NSRange(location: 0, length: nsAttributedString.length)) { value, range, _ in
                if let url = value as? URL {
                    let displayText = nsAttributedString.attributedSubstring(from: range).string
                    let linkFacet = RichTextFacetUtils.LinkFacet(
                        range: range,
                        url: url,
                        displayText: displayText
                    )
                    linkFacets.append(LinkStatePersistence.CodableLinkFacet(from: linkFacet))
                }
            }
            return linkFacets
        }
        
        // Static placeholder for per-thread-entry link facets
        private static func extractLinkFacetsForThreadEntryStatic(_ entry: ThreadEntry) -> [RichTextFacetUtils.LinkFacet] {
            // Thread entries currently don't have attributed text; return empty.
            return []
        }
    }
    
    /// Save enhanced draft state with link preservation
    func saveEnhancedDraftState() -> EnhancedPostComposerDraft {
        // logger is private, so we'll skip debug logging here
        return EnhancedPostComposerDraft(from: self)
    }
    
    /// Restore enhanced draft state with link preservation
    func restoreEnhancedDraftState(_ draft: EnhancedPostComposerDraft) {
        // logger is private, so we'll skip debug logging here
        
        enterDraftMode()
        
        defer {
            exitDraftMode()
        }
        
        // Restore basic state
        postText = draft.postText
        mediaItems = draft.mediaItems.map { $0.toMediaItem() }
        videoItem = draft.videoItem?.toMediaItem()
        selectedGif = draft.selectedGif
        selectedLanguages = draft.selectedLanguages
        selectedLabels = draft.selectedLabels
        outlineTags = draft.outlineTags
        isThreadMode = draft.isThreadMode
        currentThreadIndex = draft.currentThreadIndex
        detectedURLs = draft.detectedURLs
        urlCards = draft.urlCards.mapValues { $0.toURLCard() }
        
        // Restore thread entries with link state
        threadEntries = draft.threadEntries.map { $0.toThreadEntry() }
        
        // Restore attributed text with links
        restoreAttributedTextWithLinks(
            text: draft.postText,
            linkFacets: draft.linkFacets.compactMap { $0.toLinkFacet() },
            richTextFacets: draft.richTextFacets?.compactMap { $0.toRichTextFacet() }
        )
        
        // Update content after restoration
        updatePostContent()
    }
    
    private func restoreAttributedTextWithLinks(
        text: String,
        linkFacets: [RichTextFacetUtils.LinkFacet],
        richTextFacets: [AppBskyRichtextFacet]?
    ) {
        // Create base attributed string
        richAttributedText = NSAttributedString(string: text)
        
        // Apply link facets using RichTextFacetUtils
        if !linkFacets.isEmpty {
            #if os(iOS)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
            ]
            #else
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ]
            #endif
            
            richAttributedText = RichTextFacetUtils.createAttributedString(
                from: text,
                linkFacets: linkFacets,
                baseAttributes: baseAttributes
            )
        }
        
        // Update AttributedString for iOS 26+ compatibility
        if #available(iOS 26.0, macOS 15.0, *) {
            if let richTextFacets = richTextFacets, !richTextFacets.isEmpty {
                // Use rich text facets if available
                let mockPost = AppBskyFeedPost(
                    text: text,
                    entities: nil,
                    facets: richTextFacets,
                    reply: nil,
                    embed: nil,
                    langs: nil,
                    labels: nil,
                    tags: nil,
                    createdAt: ATProtocolDate(date: Date())
                )
                attributedPostText = mockPost.facetsAsAttributedString
                richAttributedText = NSAttributedString(attributedPostText)
            } else {
                // Convert from NSAttributedString
                attributedPostText = AttributedString(richAttributedText)
            }
        }
    }
    
    // MARK: - Thread Mode Link State Management
    
    /// Update current thread entry with link state preservation
    func updateCurrentThreadEntryWithLinkState() {
        guard threadEntries.indices.contains(currentThreadIndex) else { return }
        
        // Save current post content to the current thread entry
        threadEntries[currentThreadIndex].text = postText
        threadEntries[currentThreadIndex].mediaItems = mediaItems
        threadEntries[currentThreadIndex].videoItem = videoItem
        threadEntries[currentThreadIndex].selectedGif = selectedGif
        threadEntries[currentThreadIndex].detectedURLs = detectedURLs
        threadEntries[currentThreadIndex].urlCards = urlCards
        threadEntries[currentThreadIndex].selectedEmbedURL = selectedEmbedURL
        threadEntries[currentThreadIndex].urlsKeptForEmbed = urlsKeptForEmbed
        threadEntries[currentThreadIndex].hashtags = outlineTags
        
        // Note: Attributed text and link facets are not persisted for thread entries yet.
        // Extending ThreadEntry to include attributed text will enable full preservation.
    }
    
    /// Load entry state with link preservation
    func loadEntryStateWithLinkPreservation() {
        guard threadEntries.indices.contains(currentThreadIndex) else { return }
        
        isUpdatingText = true
        defer { isUpdatingText = false }
        
        let entry = threadEntries[currentThreadIndex]
        
        // Clear all state first using public methods
        // clearComposerState is private, so we'll reset key properties manually
        mediaItems = []
        videoItem = nil
        selectedGif = nil
        detectedURLs = []
        urlCards = [:]
        outlineTags = []
        
        // Load entry state
        postText = entry.text
        mediaItems = entry.mediaItems.map { item in
            var newItem = PostComposerViewModel.MediaItem()
            newItem.image = item.image
            newItem.rawData = item.rawData
            newItem.altText = item.altText
            newItem.isLoading = item.isLoading
            newItem.pickerItem = item.pickerItem
            newItem.aspectRatio = item.aspectRatio
            newItem.videoData = item.videoData
            newItem.rawVideoURL = item.rawVideoURL
            newItem.rawVideoAsset = item.rawVideoAsset
            return newItem
        }
        videoItem = entry.videoItem
        selectedGif = entry.selectedGif
        detectedURLs = entry.detectedURLs
        urlCards = entry.urlCards
        selectedEmbedURL = entry.selectedEmbedURL
        urlsKeptForEmbed = entry.urlsKeptForEmbed
        outlineTags = entry.hashtags
        
        // Restore attributed text with proper font attributes
        #if os(iOS)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        ]
        richAttributedText = NSAttributedString(string: postText, attributes: attributes)
        #else
        richAttributedText = NSAttributedString(string: postText)
        #endif
        
        // Update AttributedString for iOS 26+ compatibility
        if #available(iOS 26.0, macOS 15.0, *) {
            attributedPostText = AttributedString(richAttributedText)
        }
        
        // Update content after loading
        updatePostContent()
    }
}
