import Foundation
import NaturalLanguage
import Petrel
import SwiftUI
import os

// MARK: - Text Processing Extension

extension PostComposerViewModel {
    
    // MARK: - Real-time Text Parsing and Highlighting
    
    func updatePostContent() {
        // Use performance optimizer for debounced processing
        if let optimizer = performanceOptimizer {
            logger.trace("PostComposerTextProcessing: Using performance optimizer for debounced processing")
            optimizer.debounceTextProcessing {
                self.performUpdatePostContent()
            }
        } else {
            logger.trace("PostComposerTextProcessing: No optimizer, performing immediate update")
            performUpdatePostContent()
        }
    }
    
    private func performUpdatePostContent() {
        logger.info("PostComposerTextProcessing: updatePostContent start - length: \(self.postText.count), cursor: \(self.cursorPosition)")
        suggestedLanguage = detectLanguage()
        logger.debug("PostComposerTextProcessing: Detected language: \(self.suggestedLanguage?.lang.minimalIdentifier ?? "none")")

        // Parse the text content to get URLs and update mentions
        let (_, _, parsedFacets, urls, _) = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)
        logger.info("PostComposerTextProcessing: Parser results - facets: \(parsedFacets.count), URLs: \(urls.count), manualLinkFacets: \(self.manualLinkFacets.count)")

        // Merge in any manually created link facets (from the UIKit editor) so that:
        // - inline links with custom display text stay visually highlighted
        // - multiple created links are preserved across text updates
        var displayFacets = parsedFacets
        if !manualLinkFacets.isEmpty {
            displayFacets.append(contentsOf: manualLinkFacets)
            logger.debug("PostComposerTextProcessing: Merged manual link facets - total display facets: \(displayFacets.count)")
        }

        // Update attributed text with highlighting using existing RichText implementation
        updateAttributedText(facets: displayFacets)
        
        // Handle URLs with debouncing
        handleDetectedURLsOptimized(urls)

        Task {
            await updateMentionSuggestions()
        }
    }
    
    func updateFromAttributedText(_ nsAttributedText: NSAttributedString, cursorPosition: Int = 0) {
        let counts = summarizeNS(nsAttributedText)
        logger.info("PostComposerTextProcessing: updateFromAttributedText - length: \(nsAttributedText.string.count), runs: \(counts.runs), linkRuns: \(counts.linkRuns), cursor: \(cursorPosition)")
        // Extract plain text from attributed text
        let newText = nsAttributedText.string
        
        // Store cursor position for mention detection
        self.cursorPosition = cursorPosition
        
        // Only update if text actually changed to avoid infinite loops
        if newText != postText && !isUpdatingText {
            logger.debug("PostComposerTextProcessing: Text changed, updating - old length: \(self.postText.count), new length: \(newText.count)")
            isUpdatingText = true
            
            postText = newText
            richAttributedText = nsAttributedText
            
            // Update AttributedString for iOS 26+ compatibility
            if #available(iOS 26.0, macOS 15.0, *) {
                attributedPostText = AttributedString(nsAttributedText)
                logger.trace("PostComposerTextProcessing: Updated AttributedString for iOS 26+")
            }
            
            // Trigger standard post content update
            updatePostContent()
            
            isUpdatingText = false
        } else {
            logger.trace("PostComposerTextProcessing: Text unchanged or already updating - skipping")
        }
    }
    
    // MARK: - iOS 26+ AttributedString Support
    
    @available(iOS 26.0, macOS 15.0, *)
    func updateFromAttributedString(_ attributedString: AttributedString) {
        logger.debug("RT: updateFromAttributedString len=\(String(attributedString.characters).count)")
        // Extract plain text from attributed string
        let newText = String(attributedString.characters)
        
        // Only update if text actually changed to avoid infinite loops
        if newText != postText && !isUpdatingText {
            isUpdatingText = true
            
            postText = newText
            attributedPostText = attributedString
            
            // Convert to NSAttributedString for legacy compatibility
            richAttributedText = NSAttributedString(attributedString)
            
            // Extract any existing facets from the AttributedString using Petrel's infrastructure
            do {
                if let facets = try attributedString.toFacets() {
                    logger.debug("RT: toFacets -> count=\(facets.count)")
                    // Update content using existing facets
                    updateWithExistingFacets(facets)
                } else {
                    // Trigger standard post content update if no facets
                    updatePostContent()
                }
            } catch {
                logger.error("Failed to extract facets from AttributedString: \(error)")
                // Fallback to standard update
                updatePostContent()
            }
            
            isUpdatingText = false
        }
    }
    
    private func updateWithExistingFacets(_ facets: [AppBskyRichtextFacet]) {
        logger.debug("RT: updateWithExistingFacets count=\(facets.count)")
        // Update attributed text with existing facets using Petrel's infrastructure
        let mockPost = AppBskyFeedPost(text: postText, entities: nil, facets: facets, reply: nil, embed: nil, langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date()))
        
        // Use Petrel's built-in facetsAsAttributedString method
        if #available(iOS 26.0, macOS 15.0, *) {
            attributedPostText = mockPost.facetsAsAttributedString
            richAttributedText = NSAttributedString(attributedPostText)
        } else {
            richAttributedText = NSAttributedString(mockPost.facetsAsAttributedString)
        }
        
        // Update language and mention suggestions. Do NOT generate URL cards from link facets
        // to avoid auto-creating external embeds when users add inline links.
        suggestedLanguage = detectLanguage()
        
        Task {
            await updateMentionSuggestions()
        }
    }
    
    private func extractURLsFromFacets(_ facets: [AppBskyRichtextFacet]) -> [String] {
        var urls: [String] = []
        for facet in facets {
            for feature in facet.features {
                if case .appBskyRichtextFacetLink(let link) = feature {
                    urls.append(link.uri.uriString())
                }
            }
        }
        return urls
    }
    
    func syncAttributedTextFromPlainText() {
        // Update NSAttributedString when plain text changes
        if postText != richAttributedText.string && !isUpdatingText {
            richAttributedText = NSAttributedString(string: postText)
            
            // Update AttributedString for iOS 26+ compatibility
            if #available(iOS 26.0, macOS 15.0, *) {
                attributedPostText = AttributedString(richAttributedText)
            }
        }
    }
    
    /// Update the attributed text with real-time highlighting using Petrel's infrastructure
    private func updateAttributedText(facets: [AppBskyRichtextFacet]) {
        logger.debug("RT: updateAttributedText facets=\(facets.count)")
        // Use Petrel's built-in facetsAsAttributedString method for consistent formatting
        let mockPost = AppBskyFeedPost(text: postText, entities: nil, facets: facets, reply: nil, embed: nil, langs: nil, labels: nil, tags: nil, createdAt: ATProtocolDate(date: Date()))
        let styledAttributedText = mockPost.facetsAsAttributedString
        
        // Update both AttributedString (iOS 26+) and NSAttributedString (legacy)
        if #available(iOS 26.0, macOS 15.0, *) {
            attributedPostText = styledAttributedText
            richAttributedText = NSAttributedString(styledAttributedText)
        } else {
            richAttributedText = NSAttributedString(styledAttributedText)
        }
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
    
    // MARK: - Language Detection
    
    func detectLanguage() -> LanguageCodeContainer? {
        guard !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(postText)
        
        if let dominantLanguage = recognizer.dominantLanguage {
            let localeLanguage = localeLanguage(from: dominantLanguage)
            return LanguageCodeContainer(languageCode: localeLanguage.languageCode?.identifier ?? "en")
        }
        
        return nil
    }
    
    @MainActor
    func loadUserLanguagePreference() async {
        logger.debug("PostComposerTextProcessing: Loading user language preference")
        
        // Try to load user's saved default language preference
        if let savedLanguageCode = UserDefaults.standard.string(forKey: "defaultComposerLanguage") {
            logger.info("PostComposerTextProcessing: Using saved default language: \(savedLanguageCode)")
            selectedLanguages = [LanguageCodeContainer(languageCode: savedLanguageCode)]
        } else {
            // No saved preference - leave empty and let user choose or use detection
            logger.info("PostComposerTextProcessing: No saved preference, leaving language unset")
            selectedLanguages = []
        }
    }
    
    /// Call this when user manually changes language to persist their preference
    func saveDefaultLanguagePreference() {
        guard let firstLanguage = selectedLanguages.first else { return }
        let languageCode = firstLanguage.lang.languageCode?.identifier ?? firstLanguage.lang.minimalIdentifier
        logger.info("PostComposerTextProcessing: Saving new default language preference: \(languageCode)")
        UserDefaults.standard.set(languageCode, forKey: "defaultComposerLanguage")
    }
    
    // MARK: - URL Handling
    
    private func handleDetectedURLs(_ urls: [String]) {
        handleDetectedURLsOptimized(urls)
    }
    
    private func handleDetectedURLsOptimized(_ urls: [String]) {
        logger.debug("RT: handleDetectedURLsOptimized count=\(urls.count)")

        // Track which URLs were removed (for manual deletion detection)
        let previousURLs = Set(detectedURLs)
        let currentURLs = Set(urls)
        let removedURLs = previousURLs.subtracting(currentURLs).subtracting(urlsKeptForEmbed)

        // Update detected URLs immediately
        detectedURLs = urls

        // CRITICAL FIX: Clear manual link facets for URLs that were manually deleted
        // This prevents orphaned facets when users delete URLs from text
        if !removedURLs.isEmpty {
            manualLinkFacets.removeAll { facet in
                facet.features.contains { feature in
                    if case .appBskyRichtextFacetLink(let link) = feature {
                        return removedURLs.contains(link.uri.uriString())
                    }
                    return false
                }
            }
            logger.debug("RT: Cleared manual link facets for \(removedURLs.count) manually deleted URLs")

            // Reset typing attributes to prevent blue text inheritance
            resetTypingAttributes()
        }

        // Debounced URL embed selection to prevent premature link card generation
        // Cancel any pending URL selection task
        urlEmbedSelectionTask?.cancel()
        
        // Set the first URL as the selected embed URL if none is set and we have URLs
        // Use debouncing to allow user to finish typing (e.g., "google.com" not "google.co")
        if selectedEmbedURL == nil && !urls.isEmpty {
            let firstURL = urls.first!
            urlEmbedSelectionTask = Task { @MainActor in
                // Wait 750ms to allow user to finish typing
                try? await Task.sleep(for: .milliseconds(750))
                
                // Check if task was cancelled or URL is no longer valid
                guard !Task.isCancelled, 
                      detectedURLs.contains(firstURL),
                      selectedEmbedURL == nil else {
                    return
                }
                
                selectedEmbedURL = firstURL
                logger.debug("RT: Set first URL as selected embed after debounce: \(firstURL)")
            }
        }

        // If the selected embed URL is no longer in the detected URLs,
        // only clear it if it's not in the kept-for-embed set
        if let selectedURL = selectedEmbedURL, !urls.contains(selectedURL) {
            if !urlsKeptForEmbed.contains(selectedURL) {
                // URL was manually deleted - keep it for embed automatically
                // This makes cards "sticky" - they persist unless explicitly removed via X button
                urlsKeptForEmbed.insert(selectedURL)
                logger.debug("RT: Automatically kept selected embed URL after manual text deletion: \(selectedURL)")
            } else {
                logger.debug("RT: Kept selected embed URL even though it's not in text (user removed text but kept card)")
            }
        }

        // STICKY CARDS FIX: Keep ALL existing cards regardless of text state
        // Cards are only removed when user explicitly clicks the X button (via removeURLCard)
        // This prevents cards from disappearing when users edit text around the URL
        // The filter is now a no-op since we keep all cards, but we'll keep it for clarity
        let urlsSet = Set(urls)
        // Note: We keep ALL cards now - urlCards.filter would remove them, so we skip filtering
        // Cards are only removed explicitly via removeURLCard() method
        logger.debug("RT: Maintaining \(self.urlCards.count) existing URL cards (sticky behavior)")

        // Only load card for the first detected URL (which will be the embed)
        // This prevents multiple cards from being loaded and displayed
        if let firstURL = urls.first, urlCards[firstURL] == nil {
            // Use performance optimizer for debounced URL card loading
            if let optimizer = performanceOptimizer {
                optimizer.debounceURLDetection(urls: [firstURL]) { urlsToProcess in
                    Task {
                        await self.loadURLCardsOptimized(urlsToProcess)
                    }
                }
            } else {
                // Fallback to original behavior
                Task {
                    await loadURLCard(for: firstURL)
                }
            }
        }
    }
    
    @MainActor
    private func loadURLCardsOptimized(_ urls: [String]) async {
        for url in urls {
            guard urlCards[url] == nil else { continue }
            
            if let optimizer = performanceOptimizer {
                optimizer.coalesceURLCardRequest(for: url) {
                    Task {
                        await self.loadURLCardWithCoalescing(for: url)
                    }
                }
            } else {
                await loadURLCard(for: url)
            }
        }
    }
    
    @MainActor
    private func loadURLCardWithCoalescing(for urlString: String) async {
        defer {
            performanceOptimizer?.completeURLCardRequest(for: urlString)
        }
        
        await loadURLCard(for: urlString)
    }
    
    @MainActor
    func loadURLCard(for urlString: String) async {
        guard let url = URL(string: urlString),
              let client = appState.atProtoClient else { return }
        
        isLoadingURLCard = true
        
        do {
            var cardResponse = try await URLCardService.fetchURLCard(for: urlString)
            cardResponse.sourceURL = urlString
            urlCards[urlString] = cardResponse
        } catch {
            logger.error("Failed to load URL card for \(urlString): \(error)")
        }
        
        isLoadingURLCard = false
    }
    
    // MARK: - Mention Suggestions
    
    @MainActor
    private func updateMentionSuggestions() async {
        // Cancel any in-flight search to avoid stale results after selection
        mentionSearchTask?.cancel()
        logger.trace("PostComposerTextProcessing: Cancelled previous mention search task")

        // Extract current mention being typed
        guard let currentMention = getCurrentTypingMention() else {
            logger.trace("PostComposerTextProcessing: No current mention being typed")
            mentionSuggestions = []
            mentionSearchTask = nil
            return
        }

        logger.info("PostComposerTextProcessing: Detected mention query: '\(currentMention)'")
        // Kick off a fresh search task
        mentionSearchTask = Task { [weak self] in
            await self?.searchProfiles(query: currentMention)
        }
    }
    
    private func getCurrentTypingMention() -> String? {
        // Use cursor position to detect mention at current typing location
        guard cursorPosition <= postText.count else { return nil }
        
        let textUpToCursor = String(postText.prefix(cursorPosition))
        
        // Find the last @ symbol before the cursor
        guard let lastAtIndex = textUpToCursor.lastIndex(of: "@") else { return nil }
        
        let atPosition = textUpToCursor.distance(from: textUpToCursor.startIndex, to: lastAtIndex)
        
        // Check if @ is at the beginning or preceded by whitespace
        let isValidMentionStart: Bool
        if atPosition == 0 {
            isValidMentionStart = true
        } else {
            let characterBeforeAt = textUpToCursor[textUpToCursor.index(textUpToCursor.startIndex, offsetBy: atPosition - 1)]
            isValidMentionStart = characterBeforeAt.isWhitespace
        }
        
        guard isValidMentionStart else { return nil }
        
        // Extract text after @ up to cursor
        let mentionStart = textUpToCursor.index(after: lastAtIndex)
        let mentionText = String(textUpToCursor[mentionStart...])
        
        // Check if mention text contains whitespace (which would invalidate the mention)
        guard !mentionText.contains(where: { $0.isWhitespace }) else { return nil }
        
        return mentionText
    }
    
    @MainActor
    private func searchProfiles(query: String) async {
        guard !query.isEmpty,
              let client = appState.atProtoClient else {
            logger.trace("PostComposerTextProcessing: searchProfiles - empty query or no client")
            mentionSuggestions = []
            return
        }
        
        logger.info("PostComposerTextProcessing: Searching profiles for query: '\(query)'")
        do {
            let params = AppBskyActorSearchActors.Parameters(q: query, limit: 5)
            let (responseCode, searchResponse) = try await client.app.bsky.actor.searchActors(input: params)
            
            if responseCode >= 200 && responseCode < 300, let response = searchResponse {
                logger.info("PostComposerTextProcessing: Profile search successful - found \(response.actors.count) actors")
                // Convert ProfileView to ProfileViewBasic
                mentionSuggestions = response.actors.compactMap { profileView in
                    AppBskyActorDefs.ProfileViewBasic(
                        did: profileView.did,
                        handle: profileView.handle,
                        displayName: profileView.displayName,
                        pronouns: profileView.pronouns, avatar: profileView.avatar,
                        associated: profileView.associated,
                        viewer: profileView.viewer,
                        labels: profileView.labels,
                        createdAt: profileView.createdAt,
                        verification: profileView.verification,
                        status: profileView.status
                    )
                }
                logger.debug("PostComposerTextProcessing: Converted to \(self.mentionSuggestions.count) ProfileViewBasic")
            } else {
                logger.warning("PostComposerTextProcessing: Profile search failed - response code: \(responseCode)")
                mentionSuggestions = []
            }
        } catch {
            logger.error("PostComposerTextProcessing: Failed to search profiles - error: \(error.localizedDescription)")
            mentionSuggestions = []
        }
    }
    
    func selectMentionSuggestion(_ profile: AppBskyActorDefs.ProfileViewBasic) -> Int {
        #if os(iOS)
        // If we have direct access to the UITextView, update it in-place to avoid keyboard disruption
        if let textView = activeRichTextView {
            return insertMentionDirectly(profile, in: textView)
        }
        #endif
        
        // Fallback to standard text update
        return insertMentionViaTextUpdate(profile)
    }
    
    #if os(iOS)
    private func insertMentionDirectly(_ profile: AppBskyActorDefs.ProfileViewBasic, in textView: UITextView) -> Int {
        // Get current selection
        let currentRange = textView.selectedRange
        let text = textView.text ?? ""
        
        // Find the @ symbol before cursor
        guard let lastAtIndex = text.prefix(currentRange.location).lastIndex(of: "@") else {
            return currentRange.location
        }
        
        let atPosition = text.distance(from: text.startIndex, to: lastAtIndex)
        let mentionText = "@\(profile.handle.description) "
        
        // Calculate ranges
        let replaceRange = NSRange(location: atPosition, length: currentRange.location - atPosition)
        let cursorPosition = atPosition + mentionText.count
        
        // Store resolved profile for facet generation
        resolvedProfiles[profile.handle.description] = profile
        
        // Clear suggestions immediately
        mentionSuggestions = []
        
        // Update the text view directly
        isUpdatingText = true
        
        // Create attributed string for the mention
        let mentionAttributedText = NSMutableAttributedString(string: mentionText)
        let font = textView.font ?? UIFont.preferredFont(forTextStyle: UIFont.TextStyle.body)
        mentionAttributedText.addAttributes([
            .font: font,
            .foregroundColor: UIColor.label
        ], range: NSRange(location: 0, length: mentionText.count))
        
        // Replace the range in the text view
        textView.textStorage.replaceCharacters(in: replaceRange, with: mentionAttributedText)
        
        // Update cursor position
        textView.selectedRange = NSRange(location: cursorPosition, length: 0)
        
        // Reset typing attributes to prevent inheriting any unwanted attributes
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        
        // Sync back to view model
        let newText = textView.text ?? ""
        postText = newText
        richAttributedText = textView.attributedText
        
        // Update content to regenerate facets (with isUpdatingText flag preventing loops)
        updatePostContent()
        
        isUpdatingText = false
        
        return cursorPosition
    }
    #endif
    
    private func insertMentionViaTextUpdate(_ profile: AppBskyActorDefs.ProfileViewBasic) -> Int {
        // Replace the current partial mention with the selected profile
        guard let lastAtIndex = postText.lastIndex(of: "@") else { return postText.count }
        
        let beforeMention = String(postText[..<lastAtIndex])
        let afterMention = ""  // Remove any partial text after @
        
        let mentionText = "@\(profile.handle.description) "
        let newText = beforeMention + mentionText + afterMention
        
        // Calculate cursor position: right after the inserted mention (including the space)
        let cursorPosition = beforeMention.count + mentionText.count
        
        // Store resolved profile for facet generation
        resolvedProfiles[profile.handle.description] = profile
        
        // Clear suggestions immediately
        mentionSuggestions = []
        
        // Update text with loop prevention flag set
        isUpdatingText = true
        postText = newText
        
        // Update content to regenerate facets
        updatePostContent()
        
        isUpdatingText = false
        
        // Return the cursor position so the caller can set it
        return cursorPosition
    }
    
    // MARK: - iOS 26+ Enhanced Mention and Link Support using Petrel infrastructure
    
    @available(iOS 26.0, macOS 15.0, *)
    func insertMentionWithAttributedString(_ profile: AppBskyActorDefs.ProfileViewBasic, at range: Range<AttributedString.Index>) {
        // Create mention text with Petrel's rich text attributes
        let mentionText = "@\(profile.handle.description)"
        var mentionAttributedString = AttributedString(mentionText)
        
        // Apply styling and link using Petrel's RichText system
        mentionAttributedString.foregroundColor = .accentColor
        let encodedDID = profile.did.didString().addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? profile.did.didString()
        let mentionURL = URL(string: "mention://\(encodedDID)")!
        mentionAttributedString.link = mentionURL
        mentionAttributedString.richText.mentionLink = profile.did.didString()
        
        // Replace the range with the mention
        attributedPostText.replaceSubrange(range, with: mentionAttributedString)
        
        // Update plain text and legacy NSAttributedString
        postText = String(attributedPostText.characters)
        richAttributedText = NSAttributedString(attributedPostText)
        
        // Store resolved profile
        resolvedProfiles[profile.handle.description] = profile
        
        // Clear mention suggestions
        mentionSuggestions = []
        
        // Trigger content update to generate proper facets
        updatePostContent()
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    func insertLinkWithAttributedString(url: URL, displayText: String? = nil, at range: Range<AttributedString.Index>) {
        logger.debug("RT: insertLinkWithAttributedString url=\(url.absoluteString) displayText='\(displayText ?? "nil")' range=\(range)")
        
        // Use provided display text when present. If inserting at the caret with no
        // selection, avoid appending the full URL into the user's text which feels
        // noisy. Prefer a compact display derived from the URL (domain + path)
        // while keeping the facet/target URL intact.
        let linkText: String
        if let display = displayText, !display.isEmpty {
            linkText = display
        } else if range.isEmpty {
            // Compact display for caret insertion – keep facets via .link attribute
            linkText = shortenURLForDisplay(url)
        } else {
            // When replacing an existing selection, use the selected text as display
            let selectedText = String(attributedPostText[range].characters)
            linkText = selectedText.isEmpty ? shortenURLForDisplay(url) : selectedText
        }
        
        // Create link AttributedString and insert
        var linkAttributedString = AttributedString(linkText)
        linkAttributedString.link = url
        linkAttributedString.foregroundColor = .accentColor
        linkAttributedString.underlineStyle = .single
        
        // Replace the range with the link
        attributedPostText.replaceSubrange(range, with: linkAttributedString)
        
        // Update plain text and legacy NSAttributedString
        postText = String(attributedPostText.characters)
        richAttributedText = NSAttributedString(attributedPostText)
        
        let counts = summarizeNS(richAttributedText)
        logger.debug("RT: insertLink success url=\(url.absoluteString) text='\(linkText)' runs=\(counts.runs) linkRuns=\(counts.linkRuns)")
        
        // Generate facets from the AttributedString so links survive even when the
        // displayed text is a shortened form that NSDataDetector might not match.
        do {
            if let facets = try attributedPostText.toFacets() {
                updateWithExistingFacets(facets)
            } else {
                updatePostContent()
            }
        } catch {
            logger.error("RT: Failed to extract facets after link insertion: \(error)")
            updatePostContent()
        }
    }
}

// Debug helper for attributed string summary (NSAttributedString)
private func summarizeNS(_ ns: NSAttributedString) -> (runs: Int, linkRuns: Int) {
    var runs = 0
    var linkRuns = 0
    ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, _, _ in
        runs += 1
        if attrs[.link] != nil { linkRuns += 1 }
    }
    return (runs, linkRuns)
}
