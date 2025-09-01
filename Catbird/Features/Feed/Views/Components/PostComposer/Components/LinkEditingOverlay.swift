//
//  LinkEditingOverlay.swift
//  Catbird
//
//  Created by Claude Code on 1/2/25.
//

import SwiftUI
import Foundation

@available(iOS 26.0, macOS 15.0, *)
struct LinkEditingOverlay: View {
    let attributedText: AttributedString
    let textSelection: AttributedTextSelection?
    let onEditLink: (String, NSRange) -> Void
    
    @State private var hoveredLinkRange: Range<AttributedString.Index>? = nil
    @State private var tappedLinkRange: Range<AttributedString.Index>? = nil
    
    var body: some View {
        // Overlay invisible buttons over detected links for tap-to-edit functionality
        ZStack {
            ForEach(Array(linkRanges.enumerated()), id: \.offset) { index, linkInfo in
                linkEditButton(for: linkInfo)
            }
            
            // Show editing indicator if a link is being hovered/focused
            if let hoveredRange = hoveredLinkRange {
                linkHoverIndicator(for: hoveredRange)
            }
        }
    }
    
    // MARK: - Helper Views
    
    @ViewBuilder
    private func linkEditButton(for linkInfo: LinkInfo) -> some View {
        Button(action: {
            editLink(linkInfo)
        }) {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .overlay(
            // Visual feedback for tappable link
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                .opacity(hoveredLinkRange == linkInfo.range ? 0.5 : 0)
                .animation(.easeInOut(duration: 0.2), value: hoveredLinkRange)
        )
        #if os(macOS)
        .onHover { isHovered in
            withAnimation(.easeInOut(duration: 0.2)) {
                hoveredLinkRange = isHovered ? linkInfo.range : nil
            }
        }
        #endif
    }
    
    @ViewBuilder
    private func linkHoverIndicator(for range: Range<AttributedString.Index>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
                .appFont(size: 12)
                .foregroundColor(.accentColor)
            
            Text("Tap to edit link")
                .appFont(AppTextRole.caption2)
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule()
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
        )
        .opacity(hoveredLinkRange != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: hoveredLinkRange)
        // Position this indicator appropriately relative to the hovered link
        .offset(y: -30) // Position above the link
    }
    
    // MARK: - Helper Properties and Methods
    
    private var linkRanges: [LinkInfo] {
        var ranges: [LinkInfo] = []
        
        // Enumerate through all runs looking for links
        for run in attributedText.runs {
            if let url = run.link {
                let linkText = String(attributedText[run.range].characters)
                ranges.append(LinkInfo(
                    range: run.range,
                    url: url,
                    text: linkText
                ))
            }
        }
        
        return ranges
    }
    
    private func editLink(_ linkInfo: LinkInfo) {
        let nsRange = NSRange(
            location: attributedText.characters.distance(from: attributedText.startIndex, to: linkInfo.range.lowerBound),
            length: attributedText.characters.distance(from: linkInfo.range.lowerBound, to: linkInfo.range.upperBound)
        )
        
        onEditLink(linkInfo.text, nsRange)
    }
    
    // MARK: - Supporting Types
    
    private struct LinkInfo {
        let range: Range<AttributedString.Index>
        let url: URL
        let text: String
    }
}

// MARK: - Legacy Support for iOS < 26

struct LegacyLinkEditingOverlay: View {
    let attributedText: NSAttributedString
    let onEditLink: (String, NSRange) -> Void
    
    @State private var hoveredLinkRange: NSRange? = nil
    
    var body: some View {
        ZStack {
            ForEach(Array(linkRanges.enumerated()), id: \.offset) { index, linkInfo in
                Button(action: {
                    onEditLink(linkInfo.text, linkInfo.range)
                }) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                                .opacity(hoveredLinkRange == linkInfo.range ? 0.5 : 0)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                #if os(macOS)
                .onHover { isHovered in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hoveredLinkRange = isHovered ? linkInfo.range : nil
                    }
                }
                #endif
            }
        }
    }
    
    private var linkRanges: [LegacyLinkInfo] {
        var ranges: [LegacyLinkInfo] = []
        
        attributedText.enumerateAttribute(.link, in: NSRange(location: 0, length: attributedText.length)) { value, range, _ in
            if let url = value as? URL {
                let linkText = attributedText.attributedSubstring(from: range).string
                ranges.append(LegacyLinkInfo(
                    range: range,
                    url: url,
                    text: linkText
                ))
            }
        }
        
        return ranges
    }
    
    private struct LegacyLinkInfo {
        let range: NSRange
        let url: URL
        let text: String
    }
}

