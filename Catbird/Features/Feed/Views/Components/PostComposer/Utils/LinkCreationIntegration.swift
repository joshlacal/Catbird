//
//  LinkCreationIntegration.swift
//  Catbird
//
//  Enhanced link creation integration with URL card generation and performance optimization
//

import Foundation
import SwiftUI
import os
import Petrel

// MARK: - Link Creation Delegate Extension
// LinkCreationDelegate protocol defined in EnhancedRichTextEditor.swift

@available(iOS 16.0, macOS 13.0, *)
extension LinkCreationDelegate {
    func requestLinkEdit(for linkFacet: RichTextFacetUtils.LinkFacet) {
        // Default implementation - can be overridden
    }
    func requestLinkRemoval(for linkFacet: RichTextFacetUtils.LinkFacet) {
        // Default implementation - can be overridden  
    }
}

// MARK: - Enhanced Link Creation Integration

@available(iOS 16.0, macOS 13.0, *)
extension PostComposerViewModel: LinkCreationDelegate {
    
    // MARK: - Link Creation Request Handling
    
    func requestLinkCreation(for text: String, in range: NSRange) {
        logger.debug("Link creation requested for range: \(range.debugDescription)")
        
        // Extract selected text for display
        let selectedText = extractSelectedText(from: text, range: range)
        
        // Show link creation dialog with URL card integration
        showLinkCreationDialog(selectedText: selectedText, range: range)
    }
    
    func requestLinkEdit(for linkFacet: RichTextFacetUtils.LinkFacet) {
        logger.debug("Link edit requested for: \(linkFacet.url.absoluteString)")
        
        // Show link editing dialog with current values
        showLinkEditDialog(linkFacet: linkFacet)
    }
    
    func requestLinkRemoval(for linkFacet: RichTextFacetUtils.LinkFacet) {
        logger.debug("Link removal requested for: \(linkFacet.url.absoluteString)")
        
        // Remove link with animation
        removeLinkWithAnimation(linkFacet: linkFacet)
    }
    
    // MARK: - Private Link Creation Methods
    
    private func extractSelectedText(from text: String, range: NSRange) -> String {
        guard range.location >= 0,
              range.location + range.length <= text.count else {
            return ""
        }
        
        let startIndex = text.index(text.startIndex, offsetBy: range.location)
        let endIndex = text.index(startIndex, offsetBy: range.length)
        return String(text[startIndex..<endIndex])
    }
    
    private func showLinkCreationDialog(selectedText: String, range: NSRange) {
        // Deprecated integration point. The app uses LinkCreationDialog from the View layer.
        // Intentionally left as no-op to avoid conflicting behaviors.
    }
    
    private func showLinkEditDialog(linkFacet: RichTextFacetUtils.LinkFacet) {
        // Show editing interface for existing link
        logger.info("Editing link: \(linkFacet.url.absoluteString)")
    }
    
    private func removeLinkWithAnimation(linkFacet: RichTextFacetUtils.LinkFacet) {
        // Remove link with smooth animation
        withAnimation(LinkCreationPerformanceEnhancer.linkEditingAnimation) {
            removeLinkFacet(linkFacet)
        }
    }
    
    // MARK: - Enhanced Link Creation with URL Card Integration
    
    @available(iOS 26.0, macOS 15.0, *)
    func createLinkWithURLCardIntegration(url: URL, displayText: String? = nil, range: NSRange) {
        logger.debug("Creating link with URL card integration: \(url.absoluteString)")
        
        // Convert NSRange to AttributedString range
        let start = attributedPostText.index(attributedPostText.startIndex, offsetByCharacters: range.location)
        let end = attributedPostText.index(start, offsetByCharacters: range.length)
        let attributedRange = start..<end
        
        // Create link using enhanced method
        insertLinkWithURLCardIntegration(url: url, displayText: displayText, at: attributedRange)
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func insertLinkWithURLCardIntegration(url: URL, displayText: String? = nil, at range: Range<AttributedString.Index>) {
        // Use existing insertLinkWithAttributedString method without forcing URL card generation.
        insertLinkWithAttributedString(url: url, displayText: displayText, at: range)
    }
    
    // MARK: - Fallback Link Creation for iOS < 26
    
    func createLinkFallback(url: URL, displayText: String? = nil, range: NSRange) {
        logger.debug("Creating link fallback for older iOS: \(url.absoluteString)")
        
        // Use NSAttributedString approach for older iOS versions
        let linkText = displayText ?? Self.shortenURLForDisplay(url)
        var linkAttributedString = NSMutableAttributedString(string: linkText)
        
        // Apply link attributes
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .link: url,
            .foregroundColor: PlatformColor.systemBlue,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        linkAttributedString.addAttributes(linkAttributes, range: NSRange(location: 0, length: linkText.count))
        
        // Update rich attributed text
        let mutableText = NSMutableAttributedString(attributedString: richAttributedText)
        mutableText.replaceCharacters(in: range, with: linkAttributedString)
        richAttributedText = mutableText
        
        // Update plain text
        let plainText = NSMutableString(string: postText)
        plainText.replaceCharacters(in: range, with: linkText)
        postText = String(plainText)
        
        // Do not auto-create URL cards for inline link facets.
    }
    
    private func triggerURLCardGeneration(for urlString: String) {
        // Deprecated: inline links should not auto-generate URL cards.
    }
    
    @MainActor
    private func loadURLCardWithPreviewGeneration(for urlString: String) async { }

    private static func shortenURLForDisplay(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        let path = url.path
        if path.isEmpty || path == "/" { return host }
        let maxPath = 15
        if path.count > maxPath {
            let truncated = String(path.prefix(maxPath)) + "..."
            return host + truncated
        }
        return host + path
    }
    
// uploadAndCacheThumbnailOptimized removed - using existing preUploadThumbnails() method instead
    
    // MARK: - Link Facet Management
    
    private func removeLinkFacet(_ linkFacet: RichTextFacetUtils.LinkFacet) {
        // Remove link formatting from attributed text
        if #available(iOS 26.0, macOS 15.0, *) {
            removeLinkFromAttributedString(linkFacet)
        } else {
            removeLinkFromNSAttributedString(linkFacet)
        }
        
        // Update post content to reflect changes
        updatePostContent()
    }
    
    @available(iOS 26.0, macOS 15.0, *)
    private func removeLinkFromAttributedString(_ linkFacet: RichTextFacetUtils.LinkFacet) {
        // Convert NSRange to AttributedString range
        let start = attributedPostText.index(attributedPostText.startIndex, offsetByCharacters: linkFacet.range.location)
        let end = attributedPostText.index(start, offsetByCharacters: linkFacet.range.length)
        let range = start..<end
        
        // Remove link attributes
        attributedPostText[range].link = nil
        attributedPostText[range].foregroundColor = nil
        attributedPostText[range].underlineStyle = nil
        
        // Update other text representations
        postText = String(attributedPostText.characters)
        richAttributedText = NSAttributedString(attributedPostText)
    }
    
    private func removeLinkFromNSAttributedString(_ linkFacet: RichTextFacetUtils.LinkFacet) {
        let mutableText = NSMutableAttributedString(attributedString: richAttributedText)
        
        // Remove link attributes
        mutableText.removeAttribute(.link, range: linkFacet.range)
        mutableText.removeAttribute(.foregroundColor, range: linkFacet.range)
        mutableText.removeAttribute(.underlineStyle, range: linkFacet.range)
        
        // Update text representations
        richAttributedText = mutableText
        postText = mutableText.string
        
        // Update AttributedString for iOS 26+ compatibility
        if #available(iOS 26.0, macOS 15.0, *) {
            attributedPostText = AttributedString(mutableText)
        }
    }
    
    // MARK: - Keyboard Shortcut Integration
    
    func handleLinkCreationKeyboardShortcut(selectedRange: NSRange) {
        logger.debug("Link creation keyboard shortcut triggered")
        
        // Check if there's a selection or cursor position
        if selectedRange.length > 0 {
            // Create link for selected text
            requestLinkCreation(for: postText, in: selectedRange)
        } else {
            // Show link creation dialog for cursor position
            requestLinkCreation(for: postText, in: selectedRange)
        }
    }
    
    // MARK: - Context Menu Integration
    
    func getLinkContextMenuActions(for linkFacet: RichTextFacetUtils.LinkFacet) -> [LinkContextMenuAction] {
        return [
            LinkContextMenuAction(
                title: "Edit Link",
                systemImage: "pencil",
                action: { self.requestLinkEdit(for: linkFacet) }
            ),
            LinkContextMenuAction(
                title: "Copy Link",
                systemImage: "doc.on.doc",
                action: { 
                    #if os(iOS)
                    UIPasteboard.general.url = linkFacet.url
                    #elseif os(macOS)
                    NSPasteboard.general.setString(linkFacet.url.absoluteString, forType: .string)
                    #endif
                }
            ),
            LinkContextMenuAction(
                title: "Remove Link",
                systemImage: "trash",
                isDestructive: true,
                action: { self.requestLinkRemoval(for: linkFacet) }
            )
        ]
    }
}

// MARK: - Link Context Menu Action

struct LinkContextMenuAction {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    let action: () -> Void
    
    init(title: String, systemImage: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.action = action
    }
}

// MARK: - Link Creation State Manager

@available(iOS 16.0, macOS 13.0, *)
@MainActor
@Observable
final class LinkCreationStateManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "LinkCreation.State")
    
    // MARK: - State Properties
    
    var isLinkCreationDialogPresented = false
    var isLinkEditingDialogPresented = false
    var selectedLinkFacet: RichTextFacetUtils.LinkFacet?
    var selectedRange: NSRange = NSRange()
    var selectedText: String = ""
    
    // MARK: - Animation State
    
    var isLinkCreationAnimating = false
    var isLinkEditingAnimating = false
    
    // MARK: - Public Methods
    
    func presentLinkCreationDialog(selectedText: String, range: NSRange) {
        self.selectedText = selectedText
        self.selectedRange = range
        
        withAnimation(LinkCreationPerformanceEnhancer.linkCreationAnimation) {
            isLinkCreationDialogPresented = true
        }
    }
    
    func presentLinkEditingDialog(linkFacet: RichTextFacetUtils.LinkFacet) {
        self.selectedLinkFacet = linkFacet
        
        withAnimation(LinkCreationPerformanceEnhancer.linkEditingAnimation) {
            isLinkEditingDialogPresented = true
        }
    }
    
    func dismissLinkCreationDialog() {
        withAnimation(LinkCreationPerformanceEnhancer.linkCreationAnimation) {
            isLinkCreationDialogPresented = false
        }
        
        // Clear state after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.selectedText = ""
            self.selectedRange = NSRange()
        }
    }
    
    func dismissLinkEditingDialog() {
        withAnimation(LinkCreationPerformanceEnhancer.linkEditingAnimation) {
            isLinkEditingDialogPresented = false
        }
        
        // Clear state after animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.selectedLinkFacet = nil
        }
    }
}

// MARK: - Extensions

extension NSRange {
    var debugDescription: String {
        return "NSRange(location: \(location), length: \(length))"
    }
}
