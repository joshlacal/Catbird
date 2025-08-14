import Foundation
import NaturalLanguage
import Petrel
import SwiftUI

// MARK: - Text Processing Extension

extension PostComposerViewModel {
    
    // MARK: - Real-time Text Parsing and Highlighting
    
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
        if newText != postText && !isUpdatingText {
            isUpdatingText = true
            
            postText = newText
            richAttributedText = nsAttributedText
            
            // Trigger standard post content update
            updatePostContent()
            
            isUpdatingText = false
        }
    }
    
    func syncAttributedTextFromPlainText() {
        // Update NSAttributedString when plain text changes
        if postText != richAttributedText.string && !isUpdatingText {
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
        // Update detected URLs
        detectedURLs = urls
        
        // Load URL cards for new URLs
        for url in urls {
            if urlCards[url] == nil {
                Task {
                    await loadURLCard(for: url)
                }
            }
        }
        
        // Remove cards for URLs no longer in text
        let urlsSet = Set(urls)
        urlCards = urlCards.filter { urlsSet.contains($0.key) }
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
}
