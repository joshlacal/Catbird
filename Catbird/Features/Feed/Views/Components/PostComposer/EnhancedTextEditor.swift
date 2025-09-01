//
//  EnhancedTextEditor.swift
//  Catbird
//
//  Created by Claude Code on 12/31/24.
//

import SwiftUI
import Foundation
import Petrel
import os

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Rich Text Attributes (using Petrel's RichTextAttributes)
// Petrel provides richText.mentionLink and richText.tagLink attributes

// MARK: - iOS 26+ Native SwiftUI Implementation

@available(iOS 26.0, macOS 15.0, *)
struct ModernTextEditor: View {
    @Binding var attributedText: AttributedString
    @Binding var textSelection: AttributedTextSelection
    
    @Environment(\.fontResolutionContext) private var fontResolutionContext
    
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((PlatformImage) -> Void)?
    var onGenmojiDetected: (([Data]) -> Void)?
    var onTextChanged: ((AttributedString) -> Void)?
    var onLinkCreationRequested: ((String, NSRange) -> Void)?
    
    @State private var isShowingFormatting = false
    @State private var mentionSuggestions: [String] = []
    @State private var showingMentionSuggestions = false
    private let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Modern")
    @State private var isSanitizing = false
    @State private var isAutoLinking = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main text editor with simplified formatting for iOS 26+
            TextEditor(text: $attributedText, selection: $textSelection)
                .frame(minHeight: 120)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(Color.clear)
                // Enforce links-only formatting via SwiftUI definition API
                .attributedTextFormattingDefinition(LinksOnlyFormatting())
                // Enhanced context menu with multiple options
                .contextMenu {
                    enhancedContextMenu
                }
                .onChange(of: attributedText) { _, newValue in
                    // Debug summary before sanitize
                    let pre = summarizeNS(NSAttributedString(newValue))
                    rtLogger.debug("Change: len=\(newValue.characters.count), runs=\(pre.runs), linkRuns=\(pre.linkRuns)")
                    // Enforce links-only attributes on every change (typing/paste)
                    let sanitized = sanitizeToLinksOnly(newValue)
                    if sanitized != newValue {
                        let post = summarizeNS(NSAttributedString(sanitized))
                        rtLogger.debug("Sanitized: runs=\(post.runs), linkRuns=\(post.linkRuns)")
                        // Avoid publishing state changes during view updates
                        if !isSanitizing {
                            isSanitizing = true
                            attributedText = sanitized
                            isSanitizing = false
                        }
                        // Defer model updates to next runloop
                        DispatchQueue.main.async {
                            handleTextChange(sanitized)
                            onTextChanged?(sanitized)
                            applyAutoLinks()
                        }
                        return
                    }
                    // No sanitize change; defer model updates to avoid publishing-in-update warnings
                    DispatchQueue.main.async {
                        handleTextChange(newValue)
                        onTextChanged?(newValue)
                        applyAutoLinks()
                    }
                }
                #if os(macOS)
                .onPasteCommand(of: [.image]) { providers in
                    handleImagePaste(providers)
                }
                #endif
                .overlay(
                    Group {
                        if attributedText.characters.isEmpty {
                            Text(placeholder)
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    },
                    alignment: .topLeading
                )
            
            // Mention suggestions (simplified - main mention handling is in PostComposer)
            if showingMentionSuggestions && !mentionSuggestions.isEmpty {
                mentionSuggestionsView
            }

            // Enhanced inline link actions when selection contains text
            if selectionHasNonEmptyRange() {
                inlineLinkActionsView
            }
            
            // Link editing overlay for tap-to-edit functionality
            if #available(iOS 26.0, macOS 15.0, *) {
                LinkEditingOverlay(
                    attributedText: attributedText,
                    textSelection: textSelection,
                    onEditLink: { selectedText, range in
                        onLinkCreationRequested?(selectedText, range)
                    }
                )
                .allowsHitTesting(true)
            }
        }
        .background(Color.clear)
    }
    
    // MARK: - Enhanced Context Menu
    
    @ViewBuilder
    private var enhancedContextMenu: some View {
        // Link actions section
        Group {
            if selectionHasNonEmptyRange() {
                Button {
                    rtLogger.debug("ContextMenu Create Link tapped")
                    requestLinkCreation()
                } label: {
                    Label("Create Link", systemImage: "link")
                }
                .keyboardShortcut("l", modifiers: .command)
            }
            
            if hasLinkInSelection() {
                Button {
                    rtLogger.debug("ContextMenu Edit Link tapped")
                    editSelectedLink()
                } label: {
                    Label("Edit Link", systemImage: "link.badge.plus")
                }
                
                Button {
                    rtLogger.debug("ContextMenu Remove Link tapped")
                    removeSelectedLink()
                } label: {
                    Label("Remove Link", systemImage: "link.slash")
                }
                .foregroundColor(.red)
                
                Button {
                    rtLogger.debug("ContextMenu Copy Link tapped")
                    copySelectedLink()
                } label: {
                    Label("Copy Link", systemImage: "doc.on.clipboard")
                }
            }
        }
        
        if selectionHasNonEmptyRange() || hasLinkInSelection() {
            Divider()
        }
        
        // Standard text editing actions
        Group {
            if selectionHasNonEmptyRange() {
                Button {
                    copySelectedText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                
                Button {
                    cutSelectedText()
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .keyboardShortcut("x", modifiers: .command)
            }
            
            if canPaste() {
                Button {
                    pasteText()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard.fill")
                }
                .keyboardShortcut("v", modifiers: .command)
            }
            
            Button {
                selectAll()
            } label: {
                Label("Select All", systemImage: "selection.pin.in.out")
            }
            .keyboardShortcut("a", modifiers: .command)
        }
    }
    
    // MARK: - Context Menu Helper Methods
    
    private func hasLinkInSelection() -> Bool {
        switch textSelection.indices(in: attributedText) {
        case .insertionPoint:
            return false
        case .ranges(let rangeSet):
            guard let firstRange = rangeSet.ranges.first else { return false }
            return attributedText[firstRange].link != nil
        }
    }
    
    private func editSelectedLink() {
        guard let range = getSelectedRange() else { return }
        let selectedText = String(attributedText[range].characters)
        let nsRange = convertToNSRange(range)
        onLinkCreationRequested?(selectedText, nsRange)
    }
    
    private func removeSelectedLink() {
        guard let range = getSelectedRange() else { return }
        attributedText[range].link = nil
        attributedText[range].foregroundColor = nil
        attributedText[range].underlineStyle = nil
    }
    
    private func copySelectedLink() {
        guard let range = getSelectedRange(),
              let url = attributedText[range].link else { return }
        
        #if os(iOS)
        UIPasteboard.general.url = url
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #endif
    }
    
    private func copySelectedText() {
        guard let range = getSelectedRange() else { return }
        let text = String(attributedText[range].characters)
        
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
    
    private func cutSelectedText() {
        guard let range = getSelectedRange() else { return }
        let text = String(attributedText[range].characters)
        
        // Copy to clipboard
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        
        // Remove from text
        attributedText.removeSubrange(range)
    }
    
    private func pasteText() {
        #if os(iOS)
        if let string = UIPasteboard.general.string {
            insertText(string)
        }
        #elseif os(macOS)
        if let string = NSPasteboard.general.string(forType: .string) {
            insertText(string)
        }
        #endif
    }
    
    private func canPaste() -> Bool {
        #if os(iOS)
        return UIPasteboard.general.hasStrings
        #elseif os(macOS)
        return NSPasteboard.general.string(forType: .string) != nil
        #endif
    }
    
    private func selectAll() {
        let fullRange = attributedText.startIndex..<attributedText.endIndex
        textSelection = AttributedTextSelection(range: fullRange)
    }
    
    private func insertText(_ text: String) {
        let insertionRange = getInsertionRange()
        attributedText.replaceSubrange(insertionRange, with: AttributedString(text))
    }
    
    private func getSelectedRange() -> Range<AttributedString.Index>? {
        switch textSelection.indices(in: attributedText) {
        case .insertionPoint:
            return nil
        case .ranges(let rangeSet):
            return rangeSet.ranges.first
        }
    }
    
    private func getInsertionRange() -> Range<AttributedString.Index> {
        switch textSelection.indices(in: attributedText) {
        case .insertionPoint(let index):
            return index..<index
        case .ranges(let rangeSet):
            if let firstRange = rangeSet.ranges.first {
                return firstRange
            }
            return attributedText.endIndex..<attributedText.endIndex
        }
    }
    
    private func convertToNSRange(_ range: Range<AttributedString.Index>) -> NSRange {
        let location = attributedText.characters.distance(from: attributedText.startIndex, to: range.lowerBound)
        let length = attributedText.characters.distance(from: range.lowerBound, to: range.upperBound)
        return NSRange(location: location, length: length)
    }
    
    // MARK: - Inline Link Actions View
    
    private var inlineLinkActionsView: some View {
        HStack(spacing: 12) {
            // Primary link creation button
            Button {
                rtLogger.debug("Inline Link button tapped")
                requestLinkCreation()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .appFont(size: 14)
                    Text("Add Link")
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(
                            Capsule()
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        )
                )
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("l", modifiers: .command)
            
            // Secondary actions for existing links
            if hasLinkInSelection() {
                Button {
                    rtLogger.debug("Inline Edit Link button tapped")
                    editSelectedLink()
                } label: {
                    Image(systemName: "pencil")
                        .appFont(size: 14)
                        .foregroundColor(.secondary)
                        .padding(10)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                
                Button {
                    rtLogger.debug("Inline Remove Link button tapped")
                    removeSelectedLink()
                } label: {
                    Image(systemName: "link.slash")
                        .appFont(size: 14)
                        .foregroundColor(.red)
                        .padding(10)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selectionHasNonEmptyRange())
    }
    
    // MARK: - Mention Suggestions View
    
    private var mentionSuggestionsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(mentionSuggestions.prefix(5), id: \.self) { suggestion in
                Button(action: {
                    insertMention(suggestion)
                }) {
                    HStack {
                        Text("@\(suggestion)")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.systemBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Color.systemGray6)
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
    
    // MARK: - Text Formatting Methods
    
    func toggleBold() {
        attributedText.transformAttributes(in: &textSelection) { container in
            let currentFont = container.font ?? .body
            let resolved = currentFont.resolve(in: fontResolutionContext)
            container.font = currentFont.bold(!resolved.isBold)
        }
    }
    
    func toggleItalic() {
        attributedText.transformAttributes(in: &textSelection) { container in
            let currentFont = container.font ?? .body
            let resolved = currentFont.resolve(in: fontResolutionContext)
            container.font = currentFont.italic(!resolved.isItalic)
        }
    }
    
    func toggleUnderline() {
        attributedText.transformAttributes(in: &textSelection) { container in
            let currentStyle = container.underlineStyle ?? .none
            container.underlineStyle = currentStyle == .none ? .single : .none
        }
    }
    
    func setForegroundColor(_ color: Color) {
        attributedText.transformAttributes(in: &textSelection) { container in
            container.foregroundColor = color
        }
    }
    
    // MARK: - Link Creation
    
    func createLink(url: URL, displayText: String? = nil) {
        let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Modern")
        rtLogger.debug("CreateLink: url=\(url.absoluteString) displayText='\(displayText ?? "nil")'")
        
        // Apply link attribute to current selection or insertion point
        attributedText.transformAttributes(in: &textSelection) { container in
            container.link = url
            if displayText != nil {
                // Note: In a full implementation, we would need to replace the text content too
                // For now, just apply the link attribute
            }
        }
    }
    
    func requestLinkCreation() {
        // Get selection information for link creation
        guard let selectedRange = getSelectedNSRange() else { return }
        let selectedText = getSelectedText()
        let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Modern")
        rtLogger.debug("RequestLinkCreation: text='\(selectedText)' range=\(selectedRange.debugDescription)")
        onLinkCreationRequested?(selectedText, selectedRange)
    }
    
    // MARK: - Mention Handling
    
    private func handleTextChange(_ newText: AttributedString) {
        let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Modern")
        let selInfo: String
        switch textSelection.indices(in: newText) {
        case .insertionPoint:
            selInfo = "insertionPoint"
        case .ranges(let set):
            selInfo = "ranges=\(set.ranges.count)"
        }
        rtLogger.debug("HandleChange: selection=\(selInfo)")
        // Check for mention triggers (@)
        let text = String(newText.characters)
        
        // Simple mention detection - look for @ followed by word characters
        if let cursorPosition = getCurrentCursorPosition() {
            let beforeCursor = String(text.prefix(cursorPosition))
            
            if let lastAtIndex = beforeCursor.lastIndex(of: "@") {
                let afterAt = String(beforeCursor.suffix(from: beforeCursor.index(after: lastAtIndex)))
                
                // Check if we have a partial mention (no spaces)
                if !afterAt.contains(" ") && !afterAt.isEmpty {
                    showingMentionSuggestions = true
                    // In a real app, you would fetch suggestions based on `afterAt`
                    mentionSuggestions = ["alice.bsky.social", "bob.bsky.social", "carol.bsky.social"]
                        .filter { $0.localizedCaseInsensitiveContains(afterAt) }
                } else {
                    showingMentionSuggestions = false
                }
            } else {
                showingMentionSuggestions = false
            }
        }
        
        // Detect Genmoji (native support in iOS 26)
        detectGenmoji(in: newText)
    }
    
    func insertMention(_ handle: String) {
        // Find the @ symbol and replace with full mention
        let text = String(attributedText.characters)
        
        if let cursorPosition = getCurrentCursorPosition(),
           let lastAtIndex = text.prefix(cursorPosition).lastIndex(of: "@") {
            
            let atPosition = text.distance(from: text.startIndex, to: lastAtIndex)
            let mentionStart = attributedText.index(attributedText.startIndex, offsetByCharacters: atPosition)
            let mentionEnd = attributedText.index(attributedText.startIndex, offsetByCharacters: cursorPosition)
            let mentionRange = mentionStart..<mentionEnd
            
            let mentionText = "@\(handle)"
            
            // Replace with attributed mention
            var newAttributedText = attributedText
            newAttributedText.replaceSubrange(mentionRange, with: AttributedString(mentionText))
            
            // Add mention attribute using Petrel's RichText system
            let newMentionRange = mentionStart..<newAttributedText.index(mentionStart, offsetByCharacters: mentionText.count)
            newAttributedText[newMentionRange].foregroundColor = .accentColor
            let encodedDID = "did:plc:example".addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? "did:plc:example"
            let mentionURL = URL(string: "mention://\(encodedDID)")!
            newAttributedText[newMentionRange].link = mentionURL
            newAttributedText[newMentionRange].richText.mentionLink = "did:plc:example"
            
            attributedText = newAttributedText
            showingMentionSuggestions = false
        }
    }
    
    // MARK: - Image Paste Handling
    
    private func handleImagePaste(_ providers: [NSItemProvider]) {
        #if os(iOS)
        for provider in providers {
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, error in
                    if let image = object as? UIImage {
                        DispatchQueue.main.async {
                            onImagePasted?(image)
                        }
                    }
                }
            }
        }
        #elseif os(macOS)
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { object, error in
                    if let image = object as? NSImage {
                        DispatchQueue.main.async {
                            onImagePasted?(image)
                        }
                    }
                }
            }
        }
        #endif
    }
    
    // MARK: - Genmoji Detection
    
    private func detectGenmoji(in text: AttributedString) {
        // iOS 26's TextEditor automatically handles Genmoji insertion
        // We can detect them by looking for adaptive image glyphs
        var genmojiData: [Data] = []
        
        // Note: AdaptiveImageGlyph detection would require the actual SwiftUI attribute scope
        // For now, we'll implement a placeholder that could be enhanced with the real API
        if #available(iOS 18.0, *) {
            // In a real implementation, you would enumerate adaptive image glyphs
            // text.enumerateAttribute(\.adaptiveImageGlyph, in: text.startIndex..<text.endIndex, options: []) { glyph, range, _ in
            //     if let adaptiveGlyph = glyph {
            //         genmojiData.append(adaptiveGlyph.imageContent)
            //     }
            // }
            
            // Placeholder implementation - in practice this would detect actual Genmoji
            let textString = String(text.characters)
            if textString.contains("🎨") || textString.contains("✨") {
                // Placeholder: detect emoji that might represent Genmoji
                if let placeholderData = "genmoji_placeholder".data(using: .utf8) {
                    genmojiData.append(placeholderData)
                }
            }
        }
        
        if !genmojiData.isEmpty {
            let rtLogger = Logger(subsystem: "blue.catbird", category: "RichText.Modern")
            rtLogger.debug("Genmoji detected, count=\(genmojiData.count)")
            onGenmojiDetected?(genmojiData)
        }
    }

    // MARK: - Helper Methods

    // Keep only link and custom richText attributes; strip styling attributes but preserve link styling
    private func sanitizeToLinksOnly(_ s: AttributedString) -> AttributedString {
        var out = s
        // Snapshot run ranges to avoid mutating while iterating
        var runRanges: [Range<AttributedString.Index>] = []
        for run in out.runs { runRanges.append(run.range) }
        for range in runRanges {
            // Save allowed attributes
            let link = out[range].link
            let mention = out[range].richText.mentionLink
            let tag = out[range].richText.tagLink
            
            // Clear common styling attributes
            out[range].font = nil
            out[range].strikethroughStyle = nil
            out[range].inlinePresentationIntent = nil
            
            // Clear foreground and underline, but we'll reapply them for links
            out[range].foregroundColor = nil
            out[range].underlineStyle = nil
            
            // Reapply allowed attributes with enhanced styling
            out[range].link = link
            out[range].richText.mentionLink = mention
            out[range].richText.tagLink = tag
            
            // Apply enhanced link styling
            if link != nil {
                out[range].foregroundColor = .accentColor
                out[range].underlineStyle = .single
                // Add subtle background highlight for better visibility
                out[range].backgroundColor = Color.accentColor.opacity(0.1)
            }
            
            // Apply mention styling
            if mention != nil {
                out[range].foregroundColor = .accentColor
                out[range].backgroundColor = Color.accentColor.opacity(0.08)
            }
            
            // Apply tag styling
            if tag != nil {
                out[range].foregroundColor = .secondary
                out[range].backgroundColor = Color.secondary.opacity(0.1)
            }
        }
        return out
    }

    private func summarizeNS(_ ns: NSAttributedString) -> (runs: Int, linkRuns: Int) {
        var runs = 0
        var linkRuns = 0
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, _, _ in
            runs += 1
            if attrs[.link] != nil { linkRuns += 1 }
        }
        return (runs, linkRuns)
    }
    
    // MARK: - Autolink bare domains and URLs
    private func applyAutoLinks() {
        guard !isAutoLinking else { return }
        isAutoLinking = true
        defer { isAutoLinking = false }

        let plain = String(attributedText.characters)
        var new = attributedText

        // 1) NSDataDetector for scheme/full URLs
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let ns = plain as NSString
            let range = NSRange(location: 0, length: ns.length)
            detector.enumerateMatches(in: plain, options: [], range: range) { match, _, _ in
                guard let match = match, let url = match.url else { return }
                let start = new.index(new.startIndex, offsetByCharacters: match.range.location)
                let end = new.index(start, offsetByCharacters: match.range.length)
                let r = start..<end
                if new[r].link == nil {
                    new[r].link = url
                    // Apply enhanced link styling
                    new[r].foregroundColor = .accentColor
                    new[r].underlineStyle = .single
                    new[r].backgroundColor = Color.accentColor.opacity(0.1)
                }
            }
        }

        // 2) Fallback simple domain matcher (no scheme), skip emails/@mentions
        let pattern = "(?i)\\b(?:(?:[a-z0-9-]+\\.)+[a-z]{2,})(?:/[\\w\\-._~:/?#\\[\\]@!$&'()*+,;=%]*)?"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = plain as NSString
            let range = NSRange(location: 0, length: ns.length)
            regex.enumerateMatches(in: plain, options: [], range: range) { m, _, _ in
                guard let m = m else { return }
                let start = new.index(new.startIndex, offsetByCharacters: m.range.location)
                let end = new.index(start, offsetByCharacters: m.range.length)
                let r = start..<end
                if new[r].link != nil { return }
                let text = ns.substring(with: m.range)
                if text.contains("@") { return }
                if let url = URL(string: "https://\(text)") {
                    new[r].link = url
                    // Apply enhanced link styling
                    new[r].foregroundColor = .accentColor
                    new[r].underlineStyle = .single
                    new[r].backgroundColor = Color.accentColor.opacity(0.1)
                }
            }
        }

        if new != attributedText {
            attributedText = new
            // Notify upstream using modern callback
            onTextChanged?(new)
        }
    }
    
    private func getCurrentCursorPosition() -> Int? {
        let indices = textSelection.indices(in: attributedText)
        
        switch indices {
        case .insertionPoint(let index):
            return attributedText.characters.distance(from: attributedText.startIndex, to: index)
        case .ranges(let rangeSet):
            if let firstRange = rangeSet.ranges.first {
                return attributedText.characters.distance(from: attributedText.startIndex, to: firstRange.lowerBound)
            }
            return nil
        }
    }
    
    private func getSelectedText() -> String {
        let selectedSubstring = attributedText[textSelection]
        return String(selectedSubstring.characters)
    }
    
    private func getSelectedNSRange() -> NSRange? {
        let indices = textSelection.indices(in: attributedText)
        
        switch indices {
        case .insertionPoint(let index):
            let location = attributedText.characters.distance(from: attributedText.startIndex, to: index)
            return NSRange(location: location, length: 0)
        case .ranges(let rangeSet):
            // For NSRange conversion, use the first range
            if let firstRange = rangeSet.ranges.first {
                let location = attributedText.characters.distance(from: attributedText.startIndex, to: firstRange.lowerBound)
                let length = attributedText.characters.distance(from: firstRange.lowerBound, to: firstRange.upperBound)
                return NSRange(location: location, length: length)
            }
            return nil
        }
    }

    private func selectionHasNonEmptyRange() -> Bool {
        // Check if selection has non-empty range
        switch textSelection.indices(in: attributedText) {
        case .insertionPoint:
            return false
        case .ranges(let set):
            guard let first = set.ranges.first else { return false }
            return first.lowerBound != first.upperBound
        }
    }
}

// MARK: - Links-only Formatting Definition (iOS 26+/macOS 15+)

@available(iOS 26.0, macOS 15.0, *)
private struct LinksOnlyFormatting: AttributedTextFormattingDefinition {
    // Scope that exposes only the link attribute
    struct Scope: AttributeScope {
        let link: AttributeScopes.FoundationAttributes.LinkAttribute
    }

    var body: some AttributedTextFormattingDefinition<Scope> {
        AllowLinks()
    }

    private struct AllowLinks: AttributedTextValueConstraint {
        typealias Scope = LinksOnlyFormatting.Scope
        typealias AttributeKey = AttributeScopes.FoundationAttributes.LinkAttribute
        func constrain(_ container: inout Attributes) {
            // No-op: allow any URL value for .link
            container.link = container.link
        }
    }
}

// MARK: - Legacy iOS < 26 Fallback

struct LegacyTextEditor: View {
    @Binding var attributedText: NSAttributedString
    @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
    
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((PlatformImage) -> Void)?
    var onGenmojiDetected: (([String]) -> Void)?
    var onTextChanged: ((NSAttributedString) -> Void)?
    var onLinkCreationRequested: ((String, NSRange) -> Void)?
    
    var body: some View {
        // Fallback to existing RichTextEditor for iOS < 26
        RichTextEditor(
            attributedText: $attributedText,
            placeholder: placeholder,
            onImagePasted: { image in
                onImagePasted?(image)
            },
            onGenmojiDetected: { genmojis in
                let genmojiStrings = genmojis.map { String(data: $0.imageData, encoding: .utf8) ?? "" }
                onGenmojiDetected?(genmojiStrings)
            },
            onTextChanged: onTextChanged
        )
    }
}

// MARK: - Convenience Wrapper

struct ModernEnhancedRichTextEditor: View {
    @Binding var attributedText: NSAttributedString
    @Binding var linkFacets: [RichTextFacetUtils.LinkFacet]
    
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((PlatformImage) -> Void)?
    var onGenmojiDetected: (([String]) -> Void)?
    var onTextChanged: ((NSAttributedString) -> Void)?
    var onAttributedTextChanged: ((AttributedString) -> Void)?
    var onLinkCreationRequested: ((String, NSRange) -> Void)?
    
    // Local selection state for modern TextEditor; stored as Any for availability safety
    @State private var modernSelectionStorage: Any? = nil
    
    var body: some View {
        Group {
            if #available(iOS 26.0, macOS 15.0, *) {
                ModernTextEditorWrapper(
                    attributedText: Binding(
                        get: { AttributedString(attributedText) },
                        set: { newValue in
                            attributedText = NSAttributedString(newValue)
                        }
                    ),
                    textSelection: modernSelectionBinding,
                    placeholder: placeholder,
                    onImagePasted: onImagePasted,
                    onGenmojiDetected: { genmojiData in
                        let genmojiStrings = genmojiData.compactMap { String(data: $0, encoding: .utf8) }
                        onGenmojiDetected?(genmojiStrings)
                    },
                    onTextChanged: onAttributedTextChanged,
                    onLinkCreationRequested: onLinkCreationRequested
                )
                .onAppear {
                    // Convert NSAttributedString to AttributedString for new implementation
                    if modernSelectionStorage == nil {
                        // Safe to initialize only on available platforms
                        modernSelectionStorage = AttributedTextSelection()
                    }
                }
            } else {
                // Legacy path avoids any iOS 26+ symbols
                LegacyTextEditor(
                    attributedText: $attributedText,
                    linkFacets: $linkFacets,
                    placeholder: placeholder,
                    onImagePasted: onImagePasted,
                    onGenmojiDetected: onGenmojiDetected,
                    onTextChanged: onTextChanged,
                    onLinkCreationRequested: onLinkCreationRequested
                )
            }
        }
    }
}

@available(iOS 26.0, macOS 15.0, *)
private extension ModernEnhancedRichTextEditor {
    var modernSelectionBinding: Binding<AttributedTextSelection> {
        Binding(
            get: { (modernSelectionStorage as? AttributedTextSelection) ?? AttributedTextSelection() },
            set: { modernSelectionStorage = $0 }
        )
    }
}

@available(iOS 26.0, macOS 15.0, *)
private struct ModernTextEditorWrapper: View {
    @Binding var attributedText: AttributedString
    @Binding var textSelection: AttributedTextSelection
    
    var placeholder: String
    var onImagePasted: ((PlatformImage) -> Void)?
    var onGenmojiDetected: (([Data]) -> Void)?
    var onTextChanged: ((AttributedString) -> Void)?
    var onLinkCreationRequested: ((String, NSRange) -> Void)?
    
    var body: some View {
        ModernTextEditor(
            attributedText: $attributedText,
            textSelection: $textSelection,
            placeholder: placeholder,
            onImagePasted: onImagePasted,
            onGenmojiDetected: onGenmojiDetected,
            onTextChanged: onTextChanged,
            onLinkCreationRequested: onLinkCreationRequested
        )
    }
}

// MARK: - Main EnhancedTextEditor Type for External Reference
@available(iOS 26.0, *)
struct EnhancedTextEditor: View {
    @Binding var attributedText: AttributedString
    @Binding var textSelection: AttributedTextSelection
    
    var placeholder: String = "What's on your mind?"
    var onImagePasted: ((PlatformImage) -> Void)?
    var onGenmojiDetected: (([Data]) -> Void)?
    var onTextChanged: ((AttributedString) -> Void)?
    var onLinkCreationRequested: ((String, NSRange) -> Void)?
    
    var body: some View {
        if #available(iOS 26.0, macOS 15.0, *) {
            ModernTextEditor(
                attributedText: $attributedText,
                textSelection: $textSelection,
                placeholder: placeholder,
                onImagePasted: onImagePasted,
                onGenmojiDetected: onGenmojiDetected,
                onTextChanged: onTextChanged,
                onLinkCreationRequested: onLinkCreationRequested
            )
        } else {
            // For now, just show a simple text editor fallback
            Text("Enhanced text editor requires iOS 26+")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Cross-Platform Image Type Alias

// MARK: - NSAttributedString Sanitizer (links-only)

private extension NSAttributedString {
    /// Returns a copy of the receiver where only the `.link` attribute is preserved
    /// for each attributed run. All other attributes are stripped.
    func ctb_keepOnlyLinkAttribute() -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: self)
        var location = 0
        while location < mutable.length {
            var range = NSRange(location: 0, length: 0)
            let attrs = mutable.attributes(at: location, effectiveRange: &range)
            if let link = attrs[.link] {
                mutable.setAttributes([.link: link], range: range)
            } else {
                mutable.setAttributes([:], range: range)
            }
            location = range.location + range.length
        }
        return mutable
    }
}
