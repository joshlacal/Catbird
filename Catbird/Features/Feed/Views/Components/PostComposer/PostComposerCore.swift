import Foundation
import os
import Petrel
import SwiftUI
import UIKit

// MARK: - Core Functionality Extension

extension PostComposerViewModel {
    
    // MARK: - Post Management
    
    func resetPost() {
        postText = ""
        richAttributedText = NSAttributedString()
        selectedLanguages = []
        suggestedLanguage = nil
        selectedLabels = []
        mediaItems.removeAll()
        videoItem = nil
        selectedGif = nil
        detectedURLs.removeAll()
        urlCards.removeAll()
        mentionSuggestions.removeAll()
        resolvedProfiles.removeAll()
        alertItem = nil
        mediaSourceTracker.removeAll()
    }
    
    // MARK: - Thread Management
    
    func addThreadPost() {
        threadEntries.append(ThreadEntry())
        currentThreadIndex = threadEntries.count - 1
        isThread = threadEntries.count > 1
    }
    
    func removeThreadPost(at index: Int) {
        guard threadEntries.count > 1 && threadEntries.indices.contains(index) else { return }
        
        threadEntries.remove(at: index)
        
        if currentThreadIndex >= threadEntries.count {
            currentThreadIndex = threadEntries.count - 1
        }
        
        isThread = threadEntries.count > 1
    }
    
    func switchToThreadPost(at index: Int) {
        guard threadEntries.indices.contains(index) else { return }
        currentThreadIndex = index
    }
    
    // MARK: - Character Count
    
    var characterCount: Int {
        return postText.count
    }
    
    var isAtCharacterLimit: Bool {
        return characterCount >= 300
    }
    
    // MARK: - Validation
    
    var hasContent: Bool {
        return !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
               !mediaItems.isEmpty ||
               videoItem != nil ||
               selectedGif != nil
    }
    
    var canSubmitPost: Bool {
        return hasContent && !isOverCharacterLimit && !isPosting
    }
    
    // MARK: - URL Management
    
    func removeURLCard(for url: String) {
        urlCards.removeValue(forKey: url)
        detectedURLs.removeAll { $0 == url }
    }
    
    func willBeUsedAsEmbed(for url: String) -> Bool {
        // Return true if this URL will be used as an embed in the post
        // For now, return true for all URLs with valid cards
        return urlCards[url] != nil
    }
    
    // MARK: - Thread Management
    
    func addNewThreadEntry() {
        addThreadPost()
    }
    
    // MARK: - Media Paste Handling
    
    @MainActor
    func handleMediaPaste(_ items: [NSItemProvider]) async {
        for item in items {
            if item.hasItemConformingToTypeIdentifier("public.image") {
                do {
                    if let data = try await item.loadItem(forTypeIdentifier: "public.image", options: nil) as? Data {
                        var mediaItem = MediaItem()
                        mediaItem.rawData = data
                        mediaItem.image = Image(uiImage: UIImage(data: data) ?? UIImage())
                        mediaItem.isLoading = false
                        
                        if isDataAnimatedGIF(data) {
                            await processGIFAsVideoFromData(data)
                        } else {
                            mediaItems.append(mediaItem)
                        }
                    }
                } catch {
                    logger.error("Failed to process pasted media: \(error)")
                }
            }
        }
    }
    
    @MainActor
    func processDetectedGenmoji(_ genmojiData: Data) async {
        var mediaItem = MediaItem()
        mediaItem.rawData = genmojiData
        mediaItem.image = Image(uiImage: UIImage(data: genmojiData) ?? UIImage())
        mediaItem.isLoading = false
        
        let source = MediaSource.genmojiConversion(genmojiData)
        if !isMediaSourceAlreadyAdded(source) {
            trackMediaSource(source)
            
            if mediaItems.count < maxImagesAllowed {
                mediaItems.append(mediaItem)
            }
        }
    }
    
    // MARK: - Mention Management
    
    func insertMention(_ profile: AppBskyActorDefs.ProfileViewBasic) {
        selectMentionSuggestion(profile)
    }
    
    // MARK: - GIF Management
    
    func removeSelectedGif() {
        selectedGif = nil
    }
    
    // MARK: - Language Management
    
    func toggleLanguage(_ language: LanguageCodeContainer) {
        if selectedLanguages.contains(language) {
            selectedLanguages.removeAll { $0 == language }
        } else {
            selectedLanguages.append(language)
        }
    }
    
    // MARK: - Thread Creation
    
    func createThread() async throws {
        // Update current thread entry before posting
        updateCurrentThreadEntry()
        
        isPosting = true
        defer { isPosting = false }
        
        let postManager = appState.postManager
        
        // Filter out empty thread entries
        let validEntries = threadEntries.filter { entry in
            !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !entry.mediaItems.isEmpty ||
            entry.videoItem != nil ||
            entry.selectedGif != nil
        }
        
        guard !validEntries.isEmpty else {
            throw NSError(domain: "PostError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Thread has no valid posts"])
        }
        
        var previousPost: AppBskyFeedDefs.PostView?
        
        // Create each post in the thread
        for (index, entry) in validEntries.enumerated() {
            // Process facets for this entry
            let facets = await processFacetsForText(entry.text)
            
            // Create embed for this entry
            var embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?
            if let gif = entry.selectedGif {
                embed = try await createGifEmbed(gif)
            } else if !entry.mediaItems.isEmpty {
                // Create images embed from the entry's media items
                embed = try await createImagesEmbedForEntry(entry)
            } else if let videoItem = entry.videoItem {
                // Use the entry's video item
                self.videoItem = videoItem // Temporarily set for createVideoEmbed
                embed = try await createVideoEmbed()
                self.videoItem = nil // Clear it
            } else if let urlCard = entry.urlCards.values.first {
                embed = createExternalEmbed(urlCard)
            }
            
            // Create self labels
            let selfLabels = ComAtprotoLabelDefs.SelfLabels(values: selectedLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) })
            
            // Only apply threadgate to the first post
            var threadgateRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
            if index == 0 && !threadgateSettings.allowEverybody {
                threadgateRules = threadgateSettings.toAllowUnions()
            }
            
            // Create the post
            try await postManager.createPost(
                entry.text,
                languages: selectedLanguages,
                metadata: [:],
                hashtags: outlineTags,
                facets: facets,
                parentPost: previousPost,
                selfLabels: selfLabels,
                embed: embed,
                threadgateAllowRules: threadgateRules
            )
            
            // For thread posts, we need to wait a bit and get the created post
            // to use as parent for the next one. This is a limitation of the current
            // implementation - ideally we'd get the created post back from createPost
            if index < validEntries.count - 1 {
                // Small delay to ensure post is created
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }
        }
    }
    
    private func processFacetsForText(_ text: String) async -> [AppBskyRichtextFacet] {
        // Temporarily set postText for facet processing
        let originalText = postText
        postText = text
        let facets = await processFacets()
        postText = originalText
        return facets
    }
    
    private func createImagesEmbedForEntry(_ entry: ThreadEntry) async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        // Temporarily set mediaItems for image upload
        let originalItems = mediaItems
        mediaItems = entry.mediaItems
        let embed = try await createImagesEmbed()
        mediaItems = originalItems
        return embed
    }
    
    // MARK: - Post Creation
    
    func createPost() async throws {
        // Create single post
        isPosting = true
        defer { isPosting = false }
        
        logger.info("Creating post with text: \(self.postText)")
        
        let postManager = appState.postManager
        
        // Process facets (mentions, links, etc.)
        logger.debug("Processing facets...")
        let facets = await processFacets()
        logger.debug("Processed \(facets.count) facets")
        
        // Create embed if needed
        var embed: AppBskyFeedPost.AppBskyFeedPostEmbedUnion?
        if let gif = selectedGif {
            logger.debug("Creating GIF embed")
            // Handle GIF embed
            embed = try await createGifEmbed(gif)
        } else if !mediaItems.isEmpty {
            logger.debug("Creating images embed for \(self.mediaItems.count) images")
            // Handle image embeds
            embed = try await createImagesEmbed()
        } else if videoItem != nil {
            logger.debug("Creating video embed")
            // Handle video embed
            embed = try await createVideoEmbed()
        } else if let quotedPost = quotedPost {
            logger.debug("Creating quote post embed")
            // Handle quote post embed
            embed = createQuoteEmbed(quotedPost)
        } else if let urlCard = urlCards.values.first {
            logger.debug("Creating external link embed")
            // Handle external link embed
            embed = createExternalEmbed(urlCard)
        } else {
            logger.debug("No embed needed")
        }
        
        // Create self labels
        let selfLabels = ComAtprotoLabelDefs.SelfLabels(values: selectedLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) })
        
        // Convert threadgate settings if needed
        var threadgateRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
        if !threadgateSettings.allowEverybody {
            threadgateRules = threadgateSettings.toAllowUnions()
        }
        
        // Create the post
        logger.info("Calling postManager.createPost with text: '\(self.postText)', languages: \(self.selectedLanguages.count), facets: \(facets.count), hasEmbed: \(embed != nil), isReply: \(self.parentPost != nil)")
        
        try await postManager.createPost(
            postText,
            languages: selectedLanguages,
            metadata: [:],
            hashtags: outlineTags,
            facets: facets,
            parentPost: parentPost,
            selfLabels: selfLabels,
            embed: embed,
            threadgateAllowRules: threadgateRules
        )
        
        logger.info("Post created successfully")
    }
    
    // MARK: - Additional Helper Methods
    
    func insertEmoji(_ emoji: String) {
        postText += emoji
        updatePostContent()
    }
    
    func selectGif(_ gif: TenorGif) {
        selectedGif = gif
        showingGifPicker = false
        // Clear other media when GIF is selected
        mediaItems.removeAll()
        videoItem = nil
    }
    
    var isPostButtonDisabled: Bool {
        return !canSubmitPost || isPosting
    }
    
    func hasClipboardMedia() -> Bool {
        // Check if clipboard has media content
        // For now, return false - would need to check UIPasteboard
        return false
    }
    
    var currentThreadEntryIndex: Int {
        get { currentThreadIndex }
        set { currentThreadIndex = newValue }
    }
    
    func updateCurrentThreadEntry() {
        // Save current post content to the current thread entry
        if threadEntries.indices.contains(currentThreadIndex) {
            threadEntries[currentThreadIndex].text = postText
            threadEntries[currentThreadIndex].mediaItems = mediaItems
            threadEntries[currentThreadIndex].videoItem = videoItem
            threadEntries[currentThreadIndex].selectedGif = selectedGif
        }
    }
    
    func loadEntryState() {
        // Load the current thread entry state into the composer
        if threadEntries.indices.contains(currentThreadIndex) {
            let entry = threadEntries[currentThreadIndex]
            postText = entry.text
            mediaItems = entry.mediaItems
            videoItem = entry.videoItem
            selectedGif = entry.selectedGif
        }
    }
    
    func removeThreadEntry(at index: Int) {
        removeThreadPost(at: index)
    }
    
    // MARK: - Embed Creation Helpers
    
    private func createGifEmbed(_ gif: TenorGif) async throws -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        guard let client = appState.atProtoClient else { return nil }
        
        // Get the proper GIF media URL (not the Tenor page URL)
        // Debug: Log all available formats to find the right one
        logger.debug("Available media formats:")
        logger.debug("gif: \(gif.media_formats.gif?.url ?? "nil")")
        logger.debug("mediumgif: \(gif.media_formats.mediumgif?.url ?? "nil")")
        logger.debug("tinygif: \(gif.media_formats.tinygif?.url ?? "nil")")
        logger.debug("nanogif: \(gif.media_formats.nanogif?.url ?? "nil")")
        
        let gifURL: String
        if let gifFormat = gif.media_formats.gif {
            gifURL = gifFormat.url
        } else if let mediumGif = gif.media_formats.mediumgif {
            gifURL = mediumGif.url
        } else if let tinyGif = gif.media_formats.tinygif {
            gifURL = tinyGif.url
        } else {
            // Fallback to the page URL if no media formats available
            gifURL = gif.url
        }
        
        // Upload thumbnail if available
        var thumbBlob: Blob?
        if let previewURL = gif.media_formats.gifpreview?.url ?? gif.media_formats.tinygifpreview?.url {
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: previewURL)!)
                let (_, uploadResult) = try await client.com.atproto.repo.uploadBlob(data: data, mimeType: "image/jpeg")
                thumbBlob = uploadResult?.blob
            } catch {
                logger.debug("Failed to upload GIF thumbnail: \(error)")
            }
        }
        
        // Use proper title and description
        let title = gif.content_description.isEmpty ? gif.title : gif.content_description
        let description = gif.content_description.isEmpty ? "via Tenor" : "ALT: \(gif.content_description)"
        
        let external = AppBskyEmbedExternal.External(
            uri: URI(uriString: gifURL),
            title: title.isEmpty ? "GIF" : title,
            description: description,
            thumb: thumbBlob
        )
        
        return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
    }
    
    private func createQuoteEmbed(_ quotedPost: AppBskyFeedDefs.PostView) -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        let strongRef = ComAtprotoRepoStrongRef(
            uri: quotedPost.uri,
            cid: quotedPost.cid
        )
        
        return .appBskyEmbedRecord(AppBskyEmbedRecord(record: strongRef))
    }
    
    private func createExternalEmbed(_ urlCard: URLCardResponse) -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        // TODO: Upload thumbnail if available
        let external = AppBskyEmbedExternal.External(
            uri: URI(uriString: urlCard.url),
            title: urlCard.title,
            description: urlCard.description,
            thumb: nil // Would need to upload urlCard.image
        )
        
        return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
    }
    
    // MARK: - Facet Processing
    
    private func processFacets() async -> [AppBskyRichtextFacet] {
        var facets: [AppBskyRichtextFacet] = []
        
        // Process mentions
        let mentionPattern = #"@([a-zA-Z0-9.-]+)"#
        if let regex = try? NSRegularExpression(pattern: mentionPattern, options: []) {
            let matches = regex.matches(in: postText, options: [], range: NSRange(location: 0, length: postText.count))
            
            for match in matches {
                if let range = Range(match.range, in: postText) {
                    let handle = String(postText[range].dropFirst()) // Remove @
                    
                    // Check if we have a resolved profile for this handle
                    if let profile = resolvedProfiles[handle] {
                        let byteRange = calculateByteRange(for: match.range, in: postText)
                        let mention = AppBskyRichtextFacet.Mention(did: profile.did)
                        let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetMention(mention)
                        
                        let facet = AppBskyRichtextFacet(
                            index: AppBskyRichtextFacet.ByteSlice(
                                byteStart: byteRange.location,
                                byteEnd: byteRange.location + byteRange.length
                            ),
                            features: [feature]
                        )
                        facets.append(facet)
                    }
                }
            }
        }
        
        // Process URLs
        let urlPattern = #"https?://[^\s]+"#
        if let regex = try? NSRegularExpression(pattern: urlPattern, options: []) {
            let matches = regex.matches(in: postText, options: [], range: NSRange(location: 0, length: postText.count))
            
            for match in matches {
                if let range = Range(match.range, in: postText) {
                    let urlString = String(postText[range])
                    let byteRange = calculateByteRange(for: match.range, in: postText)
                    let link = AppBskyRichtextFacet.Link(uri: URI(uriString: urlString))
                    let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetLink(link)
                    
                    let facet = AppBskyRichtextFacet(
                        index: AppBskyRichtextFacet.ByteSlice(
                            byteStart: byteRange.location,
                            byteEnd: byteRange.location + byteRange.length
                        ),
                        features: [feature]
                    )
                    facets.append(facet)
                }
            }
        }
        
        // Process hashtags
        let hashtagPattern = #"#[a-zA-Z0-9_]+"#
        if let regex = try? NSRegularExpression(pattern: hashtagPattern, options: []) {
            let matches = regex.matches(in: postText, options: [], range: NSRange(location: 0, length: postText.count))
            
            for match in matches {
                if let range = Range(match.range, in: postText) {
                    let tag = String(postText[range].dropFirst()) // Remove #
                    let byteRange = calculateByteRange(for: match.range, in: postText)
                    let hashtag = AppBskyRichtextFacet.Tag(tag: tag)
                    let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetTag(hashtag)
                    
                    let facet = AppBskyRichtextFacet(
                        index: AppBskyRichtextFacet.ByteSlice(
                            byteStart: byteRange.location,
                            byteEnd: byteRange.location + byteRange.length
                        ),
                        features: [feature]
                    )
                    facets.append(facet)
                }
            }
        }
        
        return facets
    }
    
    private func calculateByteRange(for range: NSRange, in text: String) -> NSRange {
        // Convert NSRange to byte range for UTF-8 encoding
        let nsString = text as NSString
        let substring = nsString.substring(with: range)
        let bytesBefore = nsString.substring(to: range.location).data(using: .utf8)?.count ?? 0
        let bytesInRange = substring.data(using: .utf8)?.count ?? 0
        return NSRange(location: bytesBefore, length: bytesInRange)
    }
}
