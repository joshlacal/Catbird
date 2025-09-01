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
            optimizer.debounceTextProcessing {
                self.performUpdatePostContent()
            }
        } else {
            performUpdatePostContent()
        }
    }
    
    private func performUpdatePostContent() {
        logger.debug("RT: updatePostContent start len=\(self.postText.count)")
        suggestedLanguage = detectLanguage()

        // Parse the text content to get URLs and update mentions
        let (_, _, facets, urls, _) = PostParser.parsePostContent(postText, resolvedProfiles: resolvedProfiles)
        logger.debug("RT: parser facets=\(facets.count) urls=\(urls.count)")

        // Update attributed text with highlighting using existing RichText implementation
        updateAttributedText(facets: facets)
        
        // Handle URLs with debouncing
        handleDetectedURLsOptimized(urls)

        Task {
            await updateMentionSuggestions()
        }
    }
    
    func updateFromAttributedText(_ nsAttributedText: NSAttributedString) {
        let counts = summarizeNS(nsAttributedText)
        logger.debug("RT: updateFromAttributedText len=\(nsAttributedText.string.count) runs=\(counts.runs) linkRuns=\(counts.linkRuns)")
        // Extract plain text from attributed text
        let newText = nsAttributedText.string
        
        // Only update if text actually changed to avoid infinite loops
        if newText != postText && !isUpdatingText {
            isUpdatingText = true
            
            postText = newText
            richAttributedText = nsAttributedText
            
            // Update AttributedString for iOS 26+ compatibility
            if #available(iOS 26.0, macOS 15.0, *) {
                attributedPostText = AttributedString(nsAttributedText)
            }
            
            // Trigger standard post content update
            updatePostContent()
            
            isUpdatingText = false
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
        // Implementation would load user's preferred languages
        // For now, use system language as default
        if let systemLanguage = Locale.current.language.languageCode?.identifier {
            selectedLanguages = [LanguageCodeContainer(languageCode: systemLanguage)]
        }
    }
    
    // MARK: - URL Handling
    
    private func handleDetectedURLs(_ urls: [String]) {
        handleDetectedURLsOptimized(urls)
    }
    
    private func handleDetectedURLsOptimized(_ urls: [String]) {
        logger.debug("RT: handleDetectedURLsOptimized count=\(urls.count)")
        
        // Update detected URLs immediately
        detectedURLs = urls
        
        // Remove cards for URLs no longer in text
        let urlsSet = Set(urls)
        urlCards = urlCards.filter { urlsSet.contains($0.key) }
        
        // Use performance optimizer for debounced URL card loading
        if let optimizer = performanceOptimizer {
            let newUrls = urls.filter { urlCards[$0] == nil }
            if !newUrls.isEmpty {
                optimizer.debounceURLDetection(urls: newUrls) { urlsToProcess in
                    Task {
                        await self.loadURLCardsOptimized(urlsToProcess)
                    }
                }
            }
        } else {
            // Fallback to original behavior
            for url in urls {
                if urlCards[url] == nil {
                    Task {
                        await loadURLCard(for: url)
                    }
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
    private func loadURLCard(for urlString: String) async {
        guard let url = URL(string: urlString),
              let client = appState.atProtoClient else { return }
        
        isLoadingURLCard = true
        
        do {
            let cardResponse = try await URLCardService.fetchURLCard(for: urlString)
            urlCards[urlString] = cardResponse
        } catch {
            logger.error("Failed to load URL card for \(urlString): \(error)")
        }
        
        isLoadingURLCard = false
    }
    
    // MARK: - Mention Suggestions
    
    @MainActor
    private func updateMentionSuggestions() async {
        // Extract current mention being typed
        guard let currentMention = getCurrentTypingMention() else {
            mentionSuggestions = []
            return
        }
        
        // Search for matching profiles
        await searchProfiles(query: currentMention)
    }
    
    private func getCurrentTypingMention() -> String? {
        // Find the last @ symbol and check if it's part of an incomplete mention
        guard let lastAtIndex = postText.lastIndex(of: "@") else { return nil }
        
        let mentionStartIndex = postText.index(after: lastAtIndex)
        let mentionText = String(postText[mentionStartIndex...])
        
        // Check if the mention is still being typed (no spaces)
        if mentionText.contains(" ") || mentionText.contains("\n") {
            return nil
        }
        
        return mentionText
    }
    
    @MainActor
    private func searchProfiles(query: String) async {
        guard !query.isEmpty,
              let client = appState.atProtoClient else {
            mentionSuggestions = []
            return
        }
        
        do {
            let params = AppBskyActorSearchActors.Parameters(q: query, limit: 5)
            let (responseCode, searchResponse) = try await client.app.bsky.actor.searchActors(input: params)
            
            if responseCode >= 200 && responseCode < 300, let response = searchResponse {
                // Convert ProfileView to ProfileViewBasic
                mentionSuggestions = response.actors.compactMap { profileView in
                    AppBskyActorDefs.ProfileViewBasic(
                        did: profileView.did,
                        handle: profileView.handle,
                        displayName: profileView.displayName,
                        avatar: profileView.avatar,
                        associated: profileView.associated,
                        viewer: profileView.viewer,
                        labels: profileView.labels,
                        createdAt: profileView.createdAt,
                        verification: profileView.verification,
                        status: profileView.status
                    )
                }
            } else {
                mentionSuggestions = []
            }
        } catch {
            logger.error("Failed to search profiles: \(error)")
            mentionSuggestions = []
        }
    }
    
    func selectMentionSuggestion(_ profile: AppBskyActorDefs.ProfileViewBasic) {
        // Replace the current partial mention with the selected profile
        guard let lastAtIndex = postText.lastIndex(of: "@") else { return }
        
        let beforeMention = String(postText[..<lastAtIndex])
        let afterMention = ""  // Remove any partial text after @
        
        let newText = beforeMention + "@\(profile.handle.description) " + afterMention
        postText = newText
        
        // Store resolved profile for facet generation
        resolvedProfiles[profile.handle.description] = profile
        
        // Clear suggestions
        mentionSuggestions = []
        
        // Update content to regenerate facets
        updatePostContent()
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
