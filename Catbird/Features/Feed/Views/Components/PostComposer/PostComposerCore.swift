import Foundation
import os
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Core Functionality Extension

extension PostComposerViewModel {
    
    // MARK: - Post Management
    
    func resetPost() {
        isUpdatingText = true
        defer { isUpdatingText = false }
        
        postText = ""
        richAttributedText = NSAttributedString()
        attributedPostText = AttributedString()
        selectedLanguages = []
        suggestedLanguage = nil
        selectedLabels = []
        mediaItems.removeAll()
        videoItem = nil
        selectedGif = nil
        detectedURLs.removeAll()
        urlCards.removeAll()
        selectedEmbedURL = nil
        urlsKeptForEmbed.removeAll()
        thumbnailCache.removeAll()
        mentionSuggestions.removeAll()
        resolvedProfiles.removeAll()
        alertItem = nil
        mediaSourceTracker.removeAll()
        outlineTags.removeAll()
        
        // Reset thread mode state
        threadEntries = [ThreadEntry()]
        currentThreadIndex = 0
        isThread = false
        isThreadMode = false
    }
    
    // MARK: - Thread Management
    
    func addThreadPost() {
        threadEntries.append(ThreadEntry())
        currentThreadIndex = threadEntries.count - 1
        isThread = threadEntries.count > 1
        
        // Clear composer state for new post
        clearComposerState()
    }
    
    private func clearComposerState() {
        isUpdatingText = true
        defer { isUpdatingText = false }
        
        postText = ""
        mediaItems = []
        videoItem = nil
        selectedGif = nil
        detectedURLs = []
        urlCards = [:]
        outlineTags = []
        richAttributedText = NSAttributedString()
        
        // Clear mention suggestions
        mentionSuggestions = []
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
        urlsKeptForEmbed.remove(url)
        
        // If this was the selected embed URL, try to select the next available URL
        if selectedEmbedURL == url {
            selectedEmbedURL = nil
            logger.debug("Cleared selected embed URL after card removal")
            
            // Try to create an embed for the next URL in the array
            if let nextURL = detectedURLs.first {
                selectedEmbedURL = nextURL
                logger.debug("Set next URL as selected embed: \(nextURL)")
                
                // Load card for the next URL if not already loaded
                if urlCards[nextURL] == nil {
                    Task {
                        await loadURLCard(for: nextURL)
                    }
                }
            }
        }
    }
    
    func willBeUsedAsEmbed(for url: String) -> Bool {
        // Return true if this URL is the selected embed URL
        return selectedEmbedURL == url && urlCards[url] != nil
    }
    
    func removeURLFromText(for url: String) {
        // Remove the URL from the text but keep the card for embedding
        // This allows users to post just the embed card without the URL text

        // First check if URL is currently in detected URLs
        guard let urlToRemove = detectedURLs.first(where: { $0 == url }) else {
            logger.debug("Cannot remove URL from text - not found in detectedURLs: \(url)")
            return
        }

        // Mark this URL as one to keep for embedding even when not in text
        urlsKeptForEmbed.insert(url)
        logger.debug("Marked URL as kept for embed: \(url)")

        // Find and remove the URL from the text
        if let range = postText.range(of: urlToRemove) {
            isUpdatingText = true
            postText.removeSubrange(range)
            // Clean up any extra whitespace
            postText = postText.replacingOccurrences(of: "  ", with: " ")
            postText = postText.trimmingCharacters(in: .whitespacesAndNewlines)
            isUpdatingText = false

            // CRITICAL FIX: Clear manual link facets that reference the removed URL
            // This prevents stale facets with invalid byte ranges from persisting
            manualLinkFacets.removeAll { facet in
                facet.features.contains { feature in
                    if case .appBskyRichtextFacetLink(let link) = feature {
                        return link.uri.uriString() == url
                    }
                    return false
                }
            }
            logger.debug("Cleared manual link facets for removed URL: \(url)")

            // Update content to regenerate facets without this URL
            updatePostContent()

            // Reset typing attributes to prevent blue text inheritance
            resetTypingAttributes()

            logger.debug("Removed URL from text but kept card for embedding: \(url)")
        }
    }

    /// Reset UITextView typing attributes to default to prevent link styling inheritance
    func resetTypingAttributes() {
        #if os(iOS)
        // Access the active RichTextView and reset its typing attributes
        // This prevents newly typed text from inheriting link color/styling
        guard let activeView = activeRichTextView else {
            logger.debug("No active RichTextView to reset typing attributes")
            return
        }

        // Reset to default text attributes
        activeView.typingAttributes = [
            .font: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body),
            .foregroundColor: UIColor.label
        ]
        logger.debug("Reset typing attributes to default")
        #endif
    }
    
    // MARK: - Thread Management
    
    func addNewThreadEntry() {
        // Save current state to current thread entry before switching
        updateCurrentThreadEntry()
        addThreadPost()
    }
    
    // MARK: - Thread Mode Management
    
    func enterThreadMode() {
        guard !isThreadMode else { return }

        // Save current post content to first thread entry
        threadEntries[0].text = postText
        threadEntries[0].mediaItems = mediaItems
        threadEntries[0].videoItem = videoItem
        threadEntries[0].selectedGif = selectedGif
        threadEntries[0].detectedURLs = detectedURLs
        threadEntries[0].urlCards = urlCards
        threadEntries[0].hashtags = outlineTags

        // Preserve reply/quote references in thread entries
        // This ensures parentPost and quotedPost are maintained when toggling thread mode

        isThreadMode = true
        isThread = true
        currentThreadIndex = 0
    }
    
    func exitThreadMode() {
        guard isThreadMode else { return }
        
        // Load first thread entry back to main composer state
        if !threadEntries.isEmpty {
            let firstEntry = threadEntries[0]
            
            isUpdatingText = true
            defer { isUpdatingText = false }
            
            postText = firstEntry.text
            mediaItems = firstEntry.mediaItems
            videoItem = firstEntry.videoItem
            selectedGif = firstEntry.selectedGif
            detectedURLs = firstEntry.detectedURLs
            urlCards = firstEntry.urlCards
            selectedEmbedURL = firstEntry.selectedEmbedURL
            urlsKeptForEmbed = firstEntry.urlsKeptForEmbed
            outlineTags = firstEntry.hashtags
            
            // Preserve font attributes when exiting thread mode
            #if os(iOS)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
            ]
            richAttributedText = NSAttributedString(string: postText, attributes: attributes)
            #else
            richAttributedText = NSAttributedString(string: postText)
            #endif
        }
        
        // Reset to single post mode
        threadEntries = [ThreadEntry()]
        isThreadMode = false
        isThread = false
        currentThreadIndex = 0
        
        // Update content
        updatePostContent()
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

                        #if os(iOS)
                        let platformImage = UIImage(data: data)
                        if let platformImage = platformImage {
                            mediaItem.image = Image(uiImage: platformImage)
                            mediaItem.aspectRatio = CGSize(width: platformImage.size.width, height: platformImage.size.height)
                        }
                        #elseif os(macOS)
                        let platformImage = NSImage(data: data)
                        if let platformImage = platformImage {
                            mediaItem.image = Image(nsImage: platformImage)
                            mediaItem.aspectRatio = platformImage.size
                        }
                        #endif
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

        #if os(iOS)
        let platformImage = UIImage(data: genmojiData)
        if let platformImage = platformImage {
            mediaItem.image = Image(uiImage: platformImage)
            mediaItem.aspectRatio = CGSize(width: platformImage.size.width, height: platformImage.size.height)
        }
        #elseif os(macOS)
        let platformImage = NSImage(data: genmojiData)
        if let platformImage = platformImage {
            mediaItem.image = Image(nsImage: platformImage)
            mediaItem.aspectRatio = platformImage.size
        }
        #endif
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
    
    func insertMention(_ profile: AppBskyActorDefs.ProfileViewBasic) -> Int {
        return selectMentionSuggestion(profile)
    }
    
    // MARK: - GIF Management
    
    func removeSelectedGif() {
        selectedGif = nil
    }
    
    // MARK: - Language Management
    
    func toggleLanguage(_ language: LanguageCodeContainer) {
        if selectedLanguages.contains(language) {
            // Allow removing all languages - it's optional
            selectedLanguages.removeAll { $0 == language }
            // Update saved preference
            if selectedLanguages.isEmpty {
                // Clear the saved default if user removed all languages
                UserDefaults.standard.removeObject(forKey: "defaultComposerLanguage")
                logger.info("PostComposerCore: Cleared default language preference")
            } else {
                // Save the first remaining language as the new default
                saveDefaultLanguagePreference()
            }
        } else {
            selectedLanguages.append(language)
            // Save this language as the default preference
            saveDefaultLanguagePreference()
        }
        saveDraftIfNeeded()
    }
    
    /// Applies suggested language from detection
    func applySuggestedLanguage() {
        guard let suggested = suggestedLanguage else { return }
        logger.info("PostComposerCore: Applying suggested language: \(suggested.lang.minimalIdentifier)")
        selectedLanguages = [suggested]
        saveDefaultLanguagePreference()
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
        
        // Extract just the text from each entry for the batch thread creation
        let postTexts = validEntries.map { $0.text }
        
        // Process facets for each post
        var allFacets: [[AppBskyRichtextFacet]] = []
        for entry in validEntries {
            let facets = await processFacetsForText(entry.text)
            allFacets.append(facets)
        }
        
        // Process embeds for each post
        var allEmbeds: [AppBskyFeedPost.AppBskyFeedPostEmbedUnion?] = []
        for (idx, entry) in validEntries.enumerated() {
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
            } else if !entry.urlCards.isEmpty {
                // Use the first URL card from the entry for the embed
                // In thread mode, each entry tracks its own URL cards
                if let urlCard = entry.urlCards.values.first {
                    embed = await createExternalEmbedWithThumbnail(urlCard)
                }
            }
            allEmbeds.append(embed)
        }
        
        // Create self labels
        // If adult content is disabled, do not allow adult self-labels on posts
        let adultOnly: Set<String> = ["porn", "sexual", "nudity"]
        let filteredLabels: Set<ComAtprotoLabelDefs.LabelValue>
        if !appState.isAdultContentEnabled {
            filteredLabels = selectedLabels.filter { !adultOnly.contains($0.rawValue) }
        } else {
            filteredLabels = selectedLabels
        }
        let selfLabels = ComAtprotoLabelDefs.SelfLabels(values: filteredLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) })
        
        // Set up threadgate for the first post
        var threadgateRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
        if !threadgateSettings.allowEverybody {
            threadgateRules = threadgateSettings.toAllowUnions()
        }
        
        // Create the entire thread in one batch operation
        do {
            try await postManager.createThread(
                posts: postTexts,
                languages: selectedLanguages,
                selfLabels: selfLabels,
                hashtags: outlineTags,
                facets: allFacets,
                embeds: allEmbeds,
                parentPost: parentPost,
                threadgateAllowRules: threadgateRules
            )
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && (nsErr.code == NSURLErrorNotConnectedToInternet || nsErr.code == NSURLErrorTimedOut) {
                ComposerOutbox.shared.enqueueThread(texts: postTexts, languages: selectedLanguages, labels: selectedLabels, hashtags: outlineTags)
                appState.composerDraftManager.clearDraft()
                logger.info("Thread queued offline")
                return
            }
            throw error
        }
        
        // Clear draft on successful post creation
        appState.composerDraftManager.clearDraft()
    }
    
    private func processFacetsForText(_ text: String) async -> [AppBskyRichtextFacet] {
        // Temporarily set postText for facet processing
        let originalText = postText
        postText = text
        var facets = await processFacets()
        // Merge in manual inline link facets (legacy path support)
        if !manualLinkFacets.isEmpty {
            facets.append(contentsOf: manualLinkFacets)
        }
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
        } else if let embedURL = selectedEmbedURL, let urlCard = urlCards[embedURL] {
            logger.debug("Creating external link embed for selected URL: \(embedURL)")
            embed = await createExternalEmbedWithThumbnail(urlCard)
        } else {
            logger.debug("No embed needed")
        }
        
        // Create self labels
        // If adult content is disabled, do not allow adult self-labels on posts
        let adultOnly: Set<String> = ["porn", "sexual", "nudity"]
        let filteredLabels: Set<ComAtprotoLabelDefs.LabelValue>
        if !appState.isAdultContentEnabled {
            filteredLabels = selectedLabels.filter { !adultOnly.contains($0.rawValue) }
        } else {
            filteredLabels = selectedLabels
        }
        let selfLabels = ComAtprotoLabelDefs.SelfLabels(values: filteredLabels.map { ComAtprotoLabelDefs.SelfLabel(val: $0.rawValue) })
        
        // Convert threadgate settings if needed
        var threadgateRules: [AppBskyFeedThreadgate.AppBskyFeedThreadgateAllowUnion]?
        if !threadgateSettings.allowEverybody {
            threadgateRules = threadgateSettings.toAllowUnions()
        }
        
        // Create the post
        logger.info("Calling postManager.createPost with text: '\(self.postText)', languages: \(self.selectedLanguages.count), facets: \(facets.count), hasEmbed: \(embed != nil), isReply: \(self.parentPost != nil)")
        
        do {
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
        } catch {
            // If offline, enqueue into outbox and surface queued status
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && (nsErr.code == NSURLErrorNotConnectedToInternet || nsErr.code == NSURLErrorTimedOut) {
                ComposerOutbox.shared.enqueuePost(text: postText, languages: selectedLanguages, labels: selectedLabels, hashtags: outlineTags)
                appState.composerDraftManager.clearDraft()
                logger.info("Post queued offline")
                return
            }
            throw error
        }
        
        // Clear draft on successful post creation
        appState.composerDraftManager.clearDraft()
        
        logger.info("Post created successfully")
    }

    // MARK: - Thumbnail Management
    
    /// Pre-upload thumbnails for all URL cards that don't have them yet
    @MainActor
    func preUploadThumbnails() async {
        let urlCardsToProcess = urlCards.values.filter {
            !$0.image.isEmpty && thumbnailCache[$0.resolvedURL] == nil && $0.thumbnailBlob == nil
        }
        
        // Process thumbnails in background to avoid blocking UI
        if #available(iOS 16.0, macOS 13.0, *), let optimizer = performanceOptimizer {
            for urlCard in urlCardsToProcess {
                do {
                    try await optimizer.executeThumbnailUpload {
                        await self.uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
                    }
                } catch {
                    logger.error("Failed to upload thumbnail for \(urlCard.resolvedURL): \(error)")
                }
            }
        } else {
            // Fallback for older OS versions
            for urlCard in urlCardsToProcess {
                await uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
            }
        }
    }
    
    /// Check if thumbnail is available for a URL
    func hasThumbnail(for url: String) -> Bool {
        return thumbnailCache[url] != nil || urlCards[url]?.thumbnailBlob != nil
    }
    
    /// Get thumbnail blob for a URL
    func getThumbnail(for url: String) -> Blob? {
        return urlCards[url]?.thumbnailBlob ?? thumbnailCache[url]
    }
    
    /// Retry thumbnail upload for a specific URL
    @MainActor
    func retryThumbnailUpload(for url: String) async {
        guard let urlCard = urlCards[url],
              !urlCard.image.isEmpty,
              thumbnailCache[url] == nil,
              urlCard.thumbnailBlob == nil else {
            return
        }
        
        logger.info("Retrying thumbnail upload for: \(url)")
        
        // Use performance optimizer for retry if available
        if #available(iOS 16.0, macOS 13.0, *), let optimizer = performanceOptimizer {
            do {
                try await optimizer.executeThumbnailUpload {
                    await self.uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
                }
            } catch {
                logger.error("Failed to retry thumbnail upload for \(url): \(error)")
            }
        } else {
            await uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
        }
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
        
        // Sync media state to current thread
        if isThreadMode && threadEntries.indices.contains(currentThreadIndex) {
            threadEntries[currentThreadIndex].selectedGif = selectedGif
            threadEntries[currentThreadIndex].mediaItems = []
            threadEntries[currentThreadIndex].videoItem = nil
        }
        
        // Save draft after GIF selection
        saveDraftIfNeeded()
    }
    
    var isPostButtonDisabled: Bool {
        let videoBlocked = (videoUploadBlockedReason != nil)
        let videoPreparing = (videoItem?.isLoading ?? false)
        return !canSubmitPost || isPosting || videoBlocked || videoPreparing
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
        guard threadEntries.indices.contains(currentThreadIndex) else { return }
        
        threadEntries[currentThreadIndex].text = postText
        threadEntries[currentThreadIndex].mediaItems = mediaItems
        threadEntries[currentThreadIndex].videoItem = videoItem
        threadEntries[currentThreadIndex].selectedGif = selectedGif
        threadEntries[currentThreadIndex].detectedURLs = detectedURLs
        threadEntries[currentThreadIndex].urlCards = urlCards
        threadEntries[currentThreadIndex].selectedEmbedURL = selectedEmbedURL
        threadEntries[currentThreadIndex].urlsKeptForEmbed = urlsKeptForEmbed
        threadEntries[currentThreadIndex].hashtags = outlineTags
        threadEntries[currentThreadIndex].selectedLanguages = selectedLanguages
        threadEntries[currentThreadIndex].outlineTags = outlineTags
    }
    
    func loadEntryState() {
        // Load the current thread entry state into the composer
        guard threadEntries.indices.contains(currentThreadIndex) else { return }
        
        isUpdatingText = true
        defer { isUpdatingText = false }
        
        let entry = threadEntries[currentThreadIndex]
        
        // First clear all state to prevent contamination
        clearComposerState()
        
        // Then load the entry state
        postText = entry.text
        mediaItems = entry.mediaItems.map { item in
            // Create new instances to avoid reference issues
            var newItem = MediaItem()
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
        outlineTags = entry.hashtags.isEmpty ? entry.outlineTags : entry.hashtags
        selectedLanguages = entry.selectedLanguages
        
        // Sync attributed text with proper font attributes
        #if os(iOS)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        ]
        richAttributedText = NSAttributedString(string: postText, attributes: attributes)
        #else
        richAttributedText = NSAttributedString(string: postText)
        #endif
        
        // Update content after loading
        updatePostContent()
    }
    
    func removeThreadEntry(at index: Int) {
        removeThreadPost(at: index)
        // If only one entry remains, automatically revert to single-post mode
        if isThreadMode && threadEntries.count <= 1 {
            currentThreadIndex = 0
            exitThreadMode()
        }
    }

    func moveThreadEntry(from index: Int, direction: Int) {
        // direction: -1 for up, +1 for down
        let newIndex = index + direction
        guard threadEntries.indices.contains(index), threadEntries.indices.contains(newIndex) else { return }
        let entry = threadEntries.remove(at: index)
        threadEntries.insert(entry, at: newIndex)
        currentThreadIndex = newIndex
    }

    func moveThreadEntry(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              threadEntries.indices.contains(sourceIndex),
              threadEntries.indices.contains(destinationIndex) else { return }
        let entry = threadEntries.remove(at: sourceIndex)
        threadEntries.insert(entry, at: destinationIndex)
        currentThreadIndex = destinationIndex
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
            // Add size parameters to match Bluesky app format
            let baseURL = gifFormat.url
            if !baseURL.contains("?") && gifFormat.dims.count >= 2 {
                let width = gifFormat.dims[0]
                let height = gifFormat.dims[1]
                gifURL = "\(baseURL)?hh=\(height)&ww=\(width)"
            } else {
                gifURL = baseURL
            }
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
        // Priority order for thumbnail:
        // 1. URLCard's cached thumbnailBlob
        // 2. Thumbnail cache by URL
        // 3. Async upload if needed
        let cacheKey = urlCard.resolvedURL
        let thumbBlob = urlCard.thumbnailBlob ?? thumbnailCache[cacheKey]
        
        let external = AppBskyEmbedExternal.External(
            uri: URI(uriString: cacheKey),
            title: urlCard.title,
            description: urlCard.description,
            thumb: thumbBlob
        )
        
        // Start async thumbnail upload if image is available and not cached
        if !urlCard.image.isEmpty && thumbBlob == nil {
            Task {
                await uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
            }
        }
        
        return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
    }
    
    /// Create external embed with synchronous thumbnail if available
    @MainActor
    private func createExternalEmbedWithThumbnail(_ urlCard: URLCardResponse) async -> AppBskyFeedPost.AppBskyFeedPostEmbedUnion? {
        // Check for existing thumbnail
        let cacheKey = urlCard.resolvedURL
        var thumbBlob = urlCard.thumbnailBlob ?? thumbnailCache[cacheKey]
        
        // If no thumbnail exists but image URL is available, try to upload synchronously
        if thumbBlob == nil && !urlCard.image.isEmpty {
            await uploadAndCacheThumbnail(imageURL: urlCard.image, urlCard: urlCard)
            thumbBlob = thumbnailCache[cacheKey]
        }
        
        let external = AppBskyEmbedExternal.External(
            uri: URI(uriString: cacheKey),
            title: urlCard.title,
            description: urlCard.description,
            thumb: thumbBlob
        )
        
        return .appBskyEmbedExternal(AppBskyEmbedExternal(external: external))
    }
    
    /// Uploads thumbnail for external embed and caches the blob reference
    private func uploadAndCacheThumbnail(imageURL: String, urlCard: URLCardResponse) async {
        guard let client = appState.atProtoClient,
              let url = URL(string: imageURL) else {
            logger.warning("Cannot upload thumbnail: invalid URL or missing client")
            return
        }
        
        do {
            logger.debug("Downloading thumbnail from: \(imageURL)")
            
            // Download the image data
            let (data, response) = try await URLSession.shared.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                logger.warning("Failed to download thumbnail: invalid HTTP response")
                return
            }
            
            // Validate it's an image
            guard data.count > 0 else {
                logger.warning("Downloaded thumbnail is empty")
                return
            }
            
            // Determine MIME type from response or data
            let mimeType = httpResponse.mimeType ?? "image/jpeg"
            
            // Resize image if too large (max 1MB for thumbnails)
            let processedData: Data
            if data.count > 1_000_000 {
                processedData = try await resizeImageData(data, maxSizeBytes: 1_000_000)
            } else {
                processedData = data
            }
            
            logger.debug("Uploading thumbnail (\(processedData.count) bytes) with MIME type: \(mimeType)")
            
            // Upload to AT Protocol
            let (uploadCode, uploadResult) = try await client.com.atproto.repo.uploadBlob(
                data: processedData,
                mimeType: mimeType
            )
            
            guard uploadCode >= 200 && uploadCode < 300,
                  let blob = uploadResult?.blob else {
                logger.error("Failed to upload thumbnail: HTTP \(uploadCode)")
                return
            }
            
            logger.info("Successfully uploaded thumbnail for external embed: \(String(describing:blob.ref?.cid.string))")
            
            // Cache the blob reference for future use
            await MainActor.run {
                let cacheKey = urlCard.resolvedURL
                self.thumbnailCache[cacheKey] = blob
                
                // Update the URL card if it still exists in current cards
                if var existingCard = self.urlCards[cacheKey] {
                    existingCard.thumbnailBlob = blob
                    if existingCard.sourceURL == nil {
                        existingCard.sourceURL = cacheKey
                    }
                    self.urlCards[cacheKey] = existingCard
                }
            }
            
        } catch {
            logger.error("Failed to upload thumbnail: \(error.localizedDescription)")
        }
    }
    
    /// Resizes image data to fit within specified byte limit
    private func resizeImageData(_ data: Data, maxSizeBytes: Int) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let image = PlatformImage(data: data) else {
                    continuation.resume(throwing: ThumbnailUploadError.invalidImageData)
                    return
                }
                
                var compressionQuality: CGFloat = 1.0
                var resizedData = data
                
                // Try different compression qualities
                while resizedData.count > maxSizeBytes && compressionQuality > 0.1 {
                    compressionQuality -= 0.1
                    
                    #if os(iOS)
                    if let compressed = image.jpegData(compressionQuality: compressionQuality) {
                        resizedData = compressed
                    }
                    #elseif os(macOS)
                    if let tiffData = image.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let compressed = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality]) {
                        resizedData = compressed
                    }
                    #endif
                }
                
                // If still too large, resize the image dimensions
                if resizedData.count > maxSizeBytes {
                    let scale = sqrt(Double(maxSizeBytes) / Double(resizedData.count))
                    let newSize = CGSize(
                        width: image.size.width * scale,
                        height: image.size.height * scale
                    )
                    
                    #if os(iOS)
                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                    let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
                    UIGraphicsEndImageContext()
                    
                    if let resizedImage = resizedImage,
                       let finalData = resizedImage.jpegData(compressionQuality: 0.8) {
                        resizedData = finalData
                    }
                    #elseif os(macOS)
                    let resizedImage = NSImage(size: newSize, flipped: false) { rect in
                        image.draw(in: rect)
                        return true
                    }
                    
                    if let tiffData = resizedImage.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let finalData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                        resizedData = finalData
                    }
                    #endif
                }
                
                continuation.resume(returning: resizedData)
            }
        }
    }
    
    // MARK: - Facet Processing
    
    private func processFacets() async -> [AppBskyRichtextFacet] {
        // Use the same PostParser logic that's used for real-time parsing to ensure consistency
        logger.debug("PostComposer: processFacets called with postText='\(self.postText)' (length=\(self.postText.count))")
        let (_, _, facets, _, _) = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)
        
        // Try to resolve any unresolved mentions for posting
        var enhancedFacets = facets
        let unresolvedMentions = extractUnresolvedMentions(from: postText)
        
        if !unresolvedMentions.isEmpty {
            logger.debug("PostComposer: Found \(unresolvedMentions.count) unresolved mentions, attempting to resolve")
            let resolvedMentionFacets = await resolveAndCreateMentionFacets(for: unresolvedMentions)
            enhancedFacets.append(contentsOf: resolvedMentionFacets)
        }
        
        // Merge in manual inline link facets (from UIKit editor)
        logger.debug("PostComposer: Checking manualLinkFacets: count=\(self.manualLinkFacets.count), isEmpty=\(self.manualLinkFacets.isEmpty)")
        if !manualLinkFacets.isEmpty {
            logger.debug("PostComposer: Adding \(self.manualLinkFacets.count) manual link facets: \(self.manualLinkFacets)")
            enhancedFacets.append(contentsOf: manualLinkFacets)
        } else {
            logger.debug("PostComposer: No manual link facets to add")
        }
        
        logger.debug("PostComposer: Final facets count: \(enhancedFacets.count)")
        return enhancedFacets
    }
    
    /// Extract mention handles from text that aren't in resolvedProfiles
    private func extractUnresolvedMentions(from text: String) -> [(handle: String, range: NSRange)] {
        var unresolved: [(String, NSRange)] = []
        
        let mentionPattern = #"@([a-zA-Z0-9.-]+)"#
        if let regex = try? NSRegularExpression(pattern: mentionPattern, options: []) {
            let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
            
            for match in matches {
                if let range = Range(match.range, in: text) {
                    let handle = String(text[range].dropFirst()) // Remove @
                    
                    // Only include if not already resolved
                    if resolvedProfiles[handle] == nil {
                        unresolved.append((handle, match.range))
                    }
                }
            }
        }
        
        return unresolved
    }
    
    /// Attempt to resolve mentions and create facets for them
    private func resolveAndCreateMentionFacets(for mentions: [(handle: String, range: NSRange)]) async -> [AppBskyRichtextFacet] {
        guard let client = appState.atProtoClient else { return [] }
        
        var newFacets: [AppBskyRichtextFacet] = []
        
        for (handle, range) in mentions {
            do {
                // Try to resolve the profile
                let params = AppBskyActorSearchActorsTypeahead.Parameters(q: handle, limit: 1)
                let (responseCode, searchResponse) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
                
                if responseCode >= 200 && responseCode < 300,
                   let response = searchResponse,
                   let profile = response.actors.first,
                   profile.handle.description.lowercased() == handle.lowercased() {
                    
                    // Store resolved profile for future use
                    let profileBasic = AppBskyActorDefs.ProfileViewBasic(
                        did: profile.did,
                        handle: profile.handle,
                        displayName: profile.displayName,
                        pronouns: profile.pronouns, avatar: profile.avatar,
                        associated: profile.associated,
                        viewer: profile.viewer,
                        labels: profile.labels,
                        createdAt: profile.createdAt,
                        verification: profile.verification,
                        status: profile.status
                    )
                    
                    await MainActor.run {
                        resolvedProfiles[handle] = profileBasic
                    }
                    
                    // Create mention facet
                    let byteRange = calculateByteRange(for: range, in: postText)
                    let mention = AppBskyRichtextFacet.Mention(did: profile.did)
                    let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion.appBskyRichtextFacetMention(mention)
                    
                    let facet = AppBskyRichtextFacet(
                        index: AppBskyRichtextFacet.ByteSlice(
                            byteStart: byteRange.location,
                            byteEnd: byteRange.location + byteRange.length
                        ),
                        features: [feature]
                    )
                    newFacets.append(facet)
                    
                    logger.debug("PostComposer: Successfully resolved mention @\(handle) -> \(profile.did.didString())")
                } else {
                    logger.debug("PostComposer: Could not resolve mention @\(handle)")
                }
            } catch {
                logger.error("PostComposer: Failed to resolve mention @\(handle): \(error)")
            }
        }
        
        return newFacets
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

// MARK: - Thumbnail Upload Error

enum ThumbnailUploadError: LocalizedError {
    case invalidImageData
    case resizeFailed
    case uploadFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Invalid image data provided"
        case .resizeFailed:
            return "Failed to resize image"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}
