//
//  AttributedStringBridge.swift
//  Catbird
//
//  Centralized utility for handling AttributedString ↔ NSAttributedString conversions
//  and Unicode-aware byte range calculations for AT Protocol facets
//

import Foundation
import SwiftUI
import Petrel
import os

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Centralized bridge for handling AttributedString conversions and range calculations
/// with proper Unicode support for AT Protocol facet serialization
@available(iOS 16.0, macOS 13.0, *)
struct AttributedStringBridge {
    private static let logger = Logger(subsystem: "blue.catbird", category: "AttributedStringBridge")
    
    // MARK: - Conversion Methods
    
    /// Convert NSAttributedString to AttributedString with link preservation
    static func toAttributedString(_ nsAttributedString: NSAttributedString) -> AttributedString {
        logger.debug("Converting NSAttributedString to AttributedString, length: \(nsAttributedString.length)")
        
        // Use Foundation's built-in conversion which preserves most attributes
        var attributedString = AttributedString(nsAttributedString)
        
        // Ensure link attributes are properly converted using Petrel's RichText system
        var hasLinks = false
        nsAttributedString.enumerateAttribute(.link, in: NSRange(location: 0, length: nsAttributedString.length)) { value, range, _ in
            if let url = value as? URL {
                hasLinks = true
                let start = attributedString.index(attributedString.startIndex, offsetByCharacters: range.location)
                let end = attributedString.index(start, offsetByCharacters: range.length)
                let attrRange = start..<end
                
                // Apply Petrel's RichText link attributes
                attributedString[attrRange].link = url
                attributedString[attrRange].foregroundColor = .accentColor
                
                // Check if this is a mention link
                if url.scheme == "mention", let encodedDID = url.host {
                    let didString = encodedDID.removingPercentEncoding ?? encodedDID
                    attributedString[attrRange].richText.mentionLink = didString
                }
            }
        }
        
        if hasLinks {
            logger.debug("Converted NSAttributedString with links preserved")
        }
        
        return attributedString
    }
    
    /// Convert AttributedString to NSAttributedString with link preservation
    static func toNSAttributedString(_ attributedString: AttributedString) -> NSAttributedString {
        logger.debug("Converting AttributedString to NSAttributedString, length: \(attributedString.characters.count)")
        
        // Use Foundation's built-in conversion
        let nsAttributedString = NSAttributedString(attributedString)
        
        // Verify link preservation
        var linkCount = 0
        nsAttributedString.enumerateAttribute(.link, in: NSRange(location: 0, length: nsAttributedString.length)) { value, _, _ in
            if value != nil { linkCount += 1 }
        }
        
        if linkCount > 0 {
            logger.debug("Converted AttributedString with \(linkCount) link runs preserved")
        }
        
        return nsAttributedString
    }
    
    // MARK: - Range Conversion Methods
    
    /// Convert NSRange to AttributedString range with Unicode-aware calculations
    static func nsRangeToAttributedStringRange(_ nsRange: NSRange, in attributedString: AttributedString) -> Range<AttributedString.Index>? {
        guard nsRange.location != NSNotFound,
              nsRange.location >= 0,
              nsRange.location + nsRange.length <= attributedString.characters.count else {
            logger.error("Invalid NSRange: \(nsRange.debugDescription) for string length \(attributedString.characters.count)")
            return nil
        }
        
        let start = attributedString.index(attributedString.startIndex, offsetByCharacters: nsRange.location)
        let end = attributedString.index(start, offsetByCharacters: nsRange.length)
        
        return start..<end
    }
    
    /// Convert AttributedString range to NSRange with Unicode-aware calculations
    static func attributedStringRangeToNSRange(_ range: Range<AttributedString.Index>, in attributedString: AttributedString) -> NSRange? {
        let location = attributedString.characters.distance(from: attributedString.startIndex, to: range.lowerBound)
        let length = attributedString.characters.distance(from: range.lowerBound, to: range.upperBound)
        
        guard location >= 0, length >= 0, location + length <= attributedString.characters.count else {
            logger.error("Invalid AttributedString range conversion: location=\(location), length=\(length), stringLength=\(attributedString.characters.count)")
            return nil
        }
        
        return NSRange(location: location, length: length)
    }
    
    /// Calculate byte range for AT Protocol facets using Petrel's UTF-8 helpers
    static func calculateByteRange(from nsRange: NSRange, in text: String) -> (byteStart: Int, byteEnd: Int)? {
        logger.debug("Calculating byte range for NSRange: \(nsRange.debugDescription) in text length: \(text.count)")
        
        guard nsRange.location != NSNotFound,
              nsRange.location >= 0,
              nsRange.location + nsRange.length <= text.count else {
            logger.error("Invalid NSRange for byte calculation: \(nsRange.debugDescription)")
            return nil
        }
        
        // Use Petrel's UTF-8 aware string helpers for accurate byte calculations
        let utf8Data = Data(text.utf8)
        
        // Find character indices
        let startCharIndex = text.index(text.startIndex, offsetBy: nsRange.location)
        let endCharIndex = text.index(startCharIndex, offsetBy: nsRange.length)
        
        // Calculate UTF-8 byte offsets
        let prefixText = String(text[..<startCharIndex])
        let rangeText = String(text[startCharIndex..<endCharIndex])
        
        let byteStart = Data(prefixText.utf8).count
        let byteEnd = byteStart + Data(rangeText.utf8).count
        
        logger.debug("Calculated byte range: start=\(byteStart), end=\(byteEnd)")
        return (byteStart: byteStart, byteEnd: byteEnd)
    }
    
    /// Calculate character range from UTF-8 byte offsets using Petrel's helpers
    static func characterRangeFromByteRange(byteStart: Int, byteEnd: Int, in text: String) -> NSRange? {
        logger.debug("Converting byte range \(byteStart)..<\(byteEnd) to character range in text length: \(text.count)")
        
        guard byteStart >= 0, byteEnd >= byteStart else {
            logger.error("Invalid byte range: \(byteStart)..<\(byteEnd)")
            return nil
        }
        
        let utf8Data = Data(text.utf8)
        guard byteEnd <= utf8Data.count else {
            logger.error("Byte range \(byteStart)..<\(byteEnd) exceeds UTF-8 data length: \(utf8Data.count)")
            return nil
        }
        
        // Extract byte subranges
        let prefixData = utf8Data.prefix(byteStart)
        let rangeData = utf8Data.dropFirst(byteStart).prefix(byteEnd - byteStart)
        
        // Convert to strings to find character counts
        guard let prefixString = String(data: prefixData, encoding: .utf8),
              let rangeString = String(data: rangeData, encoding: .utf8) else {
            logger.error("Failed to convert byte ranges to strings")
            return nil
        }
        
        let charStart = prefixString.count
        let charLength = rangeString.count
        
        logger.debug("Converted to character range: location=\(charStart), length=\(charLength)")
        return NSRange(location: charStart, length: charLength)
    }
    
    // MARK: - Selection Helper Methods
    
    /// Extract selection information from AttributedTextSelection (iOS 26+)
    @available(iOS 26.0, macOS 15.0, *)
    static func getSelectionInfo(from selection: AttributedTextSelection, in attributedString: AttributedString) -> SelectionInfo {
        let indices = selection.indices(in: attributedString)
        
        switch indices {
        case .insertionPoint(let index):
            let location = attributedString.characters.distance(from: attributedString.startIndex, to: index)
            return SelectionInfo(
                hasSelection: false,
                nsRange: NSRange(location: location, length: 0),
                selectedText: "",
                attributedRange: index..<index
            )
            
        case .ranges(let rangeSet):
            guard let firstRange = rangeSet.ranges.first else {
                return SelectionInfo(
                    hasSelection: false,
                    nsRange: NSRange(location: 0, length: 0),
                    selectedText: "",
                    attributedRange: attributedString.startIndex..<attributedString.startIndex
                )
            }
            
            let location = attributedString.characters.distance(from: attributedString.startIndex, to: firstRange.lowerBound)
            let length = attributedString.characters.distance(from: firstRange.lowerBound, to: firstRange.upperBound)
            let selectedText = String(attributedString[firstRange].characters)
            
            return SelectionInfo(
                hasSelection: length > 0,
                nsRange: NSRange(location: location, length: length),
                selectedText: selectedText,
                attributedRange: firstRange
            )
        }
    }
    
    /// Extract selection information from NSRange (legacy editors)
    static func getSelectionInfo(from nsRange: NSRange, in nsAttributedString: NSAttributedString) -> SelectionInfo {
        let hasSelection = nsRange.length > 0
        let selectedText = hasSelection ? nsAttributedString.attributedSubstring(from: nsRange).string : ""
        
        // Convert to AttributedString range for consistency
        let attributedString = AttributedString(nsAttributedString)
        let attributedRange: Range<AttributedString.Index>
        
        if hasSelection, let range = nsRangeToAttributedStringRange(nsRange, in: attributedString) {
            attributedRange = range
        } else {
            let insertionIndex = attributedString.index(attributedString.startIndex, offsetByCharacters: nsRange.location)
            attributedRange = insertionIndex..<insertionIndex
        }
        
        return SelectionInfo(
            hasSelection: hasSelection,
            nsRange: nsRange,
            selectedText: selectedText,
            attributedRange: attributedRange
        )
    }
    
    // MARK: - Link Creation Helpers
    
    /// Create link with proper AttributedString styling using Petrel's RichText system
    static func createLinkAttributedString(url: URL, displayText: String) -> AttributedString {
        var linkString = AttributedString(displayText)
        
        // Apply Petrel's RichText link attributes
        linkString.link = url
        linkString.foregroundColor = .accentColor
        linkString.underlineStyle = .single
        
        logger.debug("Created link AttributedString: url=\(url.absoluteString), text='\(displayText)'")
        return linkString
    }
    
    /// Validate and insert link into AttributedString with proper facet handling
    static func insertLink(url: URL, displayText: String?, at range: Range<AttributedString.Index>, in attributedString: inout AttributedString) -> Bool {
        let linkText = displayText ?? shortenURLForDisplay(url)
        let linkAttributedString = createLinkAttributedString(url: url, displayText: linkText)
        
        // Validate range
        guard range.lowerBound >= attributedString.startIndex,
              range.upperBound <= attributedString.endIndex else {
            logger.error("Invalid range for link insertion")
            return false
        }
        
        // Insert the link
        attributedString.replaceSubrange(range, with: linkAttributedString)
        logger.debug("Inserted link successfully: url=\(url.absoluteString), text='\(linkText)'")
        return true
    }
    
    /// Create shortened URL display text (domain + truncated path)
    private static func shortenURLForDisplay(_ url: URL) -> String {
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
}

/// Selection information structure for unified handling
struct SelectionInfo {
    let hasSelection: Bool
    let nsRange: NSRange
    let selectedText: String
    let attributedRange: Range<AttributedString.Index>
}

// MARK: - Error Types

enum AttributedStringBridgeError: Error, LocalizedError {
    case invalidRange(description: String)
    case conversionFailed(description: String)
    case unicodeHandlingError(description: String)
    
    var errorDescription: String? {
        switch self {
        case .invalidRange(let description):
            return "Invalid range: \(description)"
        case .conversionFailed(let description):
            return "Conversion failed: \(description)"
        case .unicodeHandlingError(let description):
            return "Unicode handling error: \(description)"
        }
    }
}