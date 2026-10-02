//
//  LinkCreationTests.swift
//  CatbirdTests
//
//  Tests for link creation functionality in Post Composer
//

import Testing
import SwiftUI
import Foundation
@testable import Catbird
@testable import Petrel

@available(iOS 16.0, macOS 13.0, *)
@Suite("Link Creation Tests")
struct LinkCreationTests {
    
    // MARK: - Basic Range Conversion Tests
    
    @Suite("Range Conversions")
    struct RangeConversionTests {
        
        @Test("NSAttributedString to AttributedString conversion preserves links")
        func testBasicNSAttributedStringConversion() async {
            // Given: NSAttributedString with link
            let text = "Check out https://example.com for more info"
            let nsAttributedString = NSMutableAttributedString(string: text)
            let url = URL(string: "https://example.com")!
            let linkRange = NSRange(location: 10, length: 19) // "https://example.com"
            nsAttributedString.addAttribute(.link, value: url, range: linkRange)
            
            // When: Convert to AttributedString using Foundation's built-in conversion
            let attributedString = AttributedString(nsAttributedString)
            
            // Then: Link should be preserved
            let linkStart = attributedString.index(attributedString.startIndex, offsetByCharacters: 10)
            let linkEnd = attributedString.index(linkStart, offsetByCharacters: 19)
            let linkSubstring = attributedString[linkStart..<linkEnd]
            
            #expect(linkSubstring.link == url)
            #expect(String(linkSubstring.characters) == "https://example.com")
        }
        
        @Test("NSRange to AttributedString range manual conversion")
        func testNSRangeToAttributedStringRangeManualConversion() async {
            // Given: AttributedString with Unicode text
            let text = "Hello 👋 world 🌍 test"
            let attributedString = AttributedString(text)
            let nsRange = NSRange(location: 6, length: 7) // "👋 world"
            
            // When: Manually convert NSRange to AttributedString range
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: nsRange.location)
            let end = attributedString.index(start, offsetByCharacters: nsRange.length)
            let attrRange = start..<end
            
            // Then: Range should contain correct text
            let substring = attributedString[attrRange]
            #expect(String(substring.characters) == "👋 world")
        }
        
        @Test("Byte range calculation with Unicode text")
        func testByteRangeCalculationWithUnicode() async {
            // Given: Text with various Unicode characters
            let text = "Hello 👋🏻 café 🇺🇸 world"
            let nsRange = NSRange(location: 6, length: 8) // "👋🏻 café"
            
            // When: Calculate byte range manually
            let startIndex = text.index(text.startIndex, offsetBy: nsRange.location)
            let endIndex = text.index(startIndex, offsetBy: nsRange.length)
            let substring = String(text[startIndex..<endIndex])
            
            let prefixText = String(text.prefix(nsRange.location))
            let byteStart = Data(prefixText.utf8).count
            let byteEnd = byteStart + Data(substring.utf8).count
            
            // Then: Byte range should be accurate for UTF-8
            let utf8Data = Data(text.utf8)
            let extractedData = utf8Data[byteStart..<byteEnd]
            let extractedString = String(data: extractedData, encoding: .utf8)
            #expect(extractedString == "👋🏻 café")
            #expect(byteEnd > byteStart)
            #expect(byteStart >= 0)
            #expect(byteEnd <= utf8Data.count)
        }
    }
    
    // MARK: - Selection Handling Tests
    
    @Suite("Selection Handling")
    struct SelectionHandlingTests {
        
        @available(iOS 26.0, macOS 15.0, *)
        @Test("Selection info extraction from AttributedTextSelection")
        func testSelectionInfoFromAttributedTextSelection() async {
            // Given: AttributedString and selection
            let text = "Select this text for link"
            let attributedString = AttributedString(text)
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 7)
            let end = attributedString.index(start, offsetByCharacters: 4) // "this"
            let selection = AttributedTextSelection(start..<end)
            
            // When: Extract selection indices
            let indices = selection.indices(in: attributedString)
            
            // Then: Should indicate selection
            switch indices {
            case .ranges(let rangeSet):
                if let firstRange = rangeSet.ranges.first {
                    let selectedText = String(attributedString[firstRange].characters)
                    #expect(selectedText == "this")
                }
            case .insertionPoint:
                Issue.record("Expected range selection, got insertion point")
            }
        }
        
        @Test("Basic NSRange selection handling")
        func testBasicNSRangeSelection() async {
            // Given: NSAttributedString and range
            let text = "Select this text for link"
            let nsAttributedString = NSAttributedString(string: text)
            let nsRange = NSRange(location: 7, length: 4) // "this"
            
            // When: Extract selected text
            let selectedText = nsAttributedString.attributedSubstring(from: nsRange).string
            
            // Then: Should extract correct text
            #expect(selectedText == "this")
            #expect(nsRange.location == 7)
            #expect(nsRange.length == 4)
        }
        
        @Test("Empty selection handling")
        func testEmptySelectionHandling() async {
            // Given: NSAttributedString and empty range (cursor position)
            let text = "Cursor here"
            let nsRange = NSRange(location: 6, length: 0)
            
            // When: Check if selection is empty
            let hasSelection = nsRange.length > 0
            
            // Then: Should indicate no selection
            #expect(hasSelection == false)
            #expect(nsRange.location == 6)
            #expect(nsRange.length == 0)
        }
    }
    
    // MARK: - Link Creation Tests
    
    @Suite("Link Creation")
    struct LinkCreationTests {
        
        @Test("Manual link insertion with AttributedString")
        func testManualLinkInsertion() async {
            // Given: AttributedString and URL
            var attributedString = AttributedString("Check out our website")
            let url = URL(string: "https://catbird.app")!
            let displayText = "Catbird"
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 10)
            let end = attributedString.index(start, offsetByCharacters: 3) // "our"
            let range = start..<end
            
            // When: Manually insert link
            var linkString = AttributedString(displayText)
            linkString.link = url
            linkString.foregroundColor = .accentColor
            linkString.underlineStyle = .single
            
            attributedString.replaceSubrange(range, with: linkString)
            
            // Then: Link should be inserted successfully
            #expect(String(attributedString.characters).contains("Catbird"))
            
            // Verify link attribute
            let linkStart = attributedString.index(attributedString.startIndex, offsetByCharacters: 10)
            let linkEnd = attributedString.index(linkStart, offsetByCharacters: displayText.count)
            let linkSubstring = attributedString[linkStart..<linkEnd]
            #expect(linkSubstring.link == url)
        }
        
        @Test("Link creation with Unicode text")
        func testLinkCreationWithUnicodeText() async {
            // Given: AttributedString with Unicode
            var attributedString = AttributedString("Visit 🌟 awesome site 🚀")
            let url = URL(string: "https://unicode-test.com")!
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 7)
            let end = attributedString.index(start, offsetByCharacters: 7) // "awesome"
            let range = start..<end
            
            // When: Insert link with Unicode handling
            var linkString = AttributedString("amazing")
            linkString.link = url
            linkString.foregroundColor = .accentColor
            
            attributedString.replaceSubrange(range, with: linkString)
            
            // Then: Should handle Unicode correctly
            let finalText = String(attributedString.characters)
            #expect(finalText.contains("🌟"))
            #expect(finalText.contains("🚀"))
            #expect(finalText.contains("amazing"))
        }
        
        @Test("NSAttributedString link insertion")
        func testNSAttributedStringLinkInsertion() async {
            // Given: NSAttributedString
            let text = "Check out our website"
            let mutableAttributedString = NSMutableAttributedString(string: text)
            let url = URL(string: "https://catbird.app")!
            let linkRange = NSRange(location: 10, length: 3) // "our"
            
            // When: Add link attribute
            mutableAttributedString.addAttribute(.link, value: url, range: linkRange)
            
            #if os(iOS)
            mutableAttributedString.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: linkRange)
            #elseif os(macOS)
            mutableAttributedString.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: linkRange)
            #endif
            
            // Then: Link should be applied
            var foundLink: URL?
            mutableAttributedString.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if let linkValue = value as? URL {
                    foundLink = linkValue
                }
            }
            
            #expect(foundLink == url)
            #expect(mutableAttributedString.string == text)
        }
    }
    
    // MARK: - RichTextFacetUtils Tests
    
    @Suite("RichTextFacetUtils")
    struct RichTextFacetUtilsTests {
        
        @Test("Create facets from link facets")
        func testCreateFacetsFromLinkFacets() async {
            // Given: Text with link facets
            let text = "Visit https://example.com for more info"
            let url = URL(string: "https://example.com")!
            let linkFacet = RichTextFacetUtils.LinkFacet(
                range: NSRange(location: 6, length: 19),
                url: url,
                displayText: "https://example.com"
            )
            
            // When: Create facets
            let facets = RichTextFacetUtils.createFacets(from: [linkFacet], in: text)
            
            // Then: Should create valid AppBskyRichtextFacet
            #expect(facets.count == 1)
            
            let facet = facets[0]
            #expect(facet.features.count == 1)
            
            if case .appBskyRichtextFacetLink(let link) = facet.features[0] {
                #expect(link.uri.uriString() == "https://example.com")
            } else {
                Issue.record("Expected link facet feature")
            }
        }
        
        @Test("Update facets for text change")
        func testUpdateFacetsForTextChange() async {
            // Given: Link facets and text change
            let originalText = "Visit https://example.com today"
            let newText = "Please visit https://example.com today"
            let url = URL(string: "https://example.com")!
            
            let linkFacet = RichTextFacetUtils.LinkFacet(
                range: NSRange(location: 6, length: 19), // "https://example.com"
                url: url,
                displayText: "https://example.com"
            )
            
            // Text change: inserted "Please " at beginning
            let editedRange = NSRange(location: 0, length: 0)
            let changeLength = 7 // "Please " added
            
            // When: Update facets
            let updatedFacets = RichTextFacetUtils.updateFacetsForTextChange(
                linkFacets: [linkFacet],
                in: editedRange,
                changeLength: changeLength,
                originalText: originalText,
                newText: newText
            )
            
            // Then: Facet range should be adjusted
            #expect(updatedFacets.count == 1)
            let updatedFacet = updatedFacets[0]
            #expect(updatedFacet.range.location == 13) // 6 + 7
            #expect(updatedFacet.range.length == 19) // Same length
            #expect(updatedFacet.url == url)
        }
        
        @Test("Validate and standardize URL")
        func testValidateAndStandardizeURL() async {
            // Test various URL formats
            let testCases: [(input: String, expected: String?)] = [
                ("example.com", "https://example.com"),
                ("https://example.com", "https://example.com"),
                ("http://example.com", "http://example.com"),
                ("ftp://example.com", "ftp://example.com"),
                ("  https://example.com  ", "https://example.com"), // Trimming
                ("invalid url", nil),
                ("", nil)
            ]
            
            for testCase in testCases {
                // When: Validate and standardize
                let result = RichTextFacetUtils.validateAndStandardizeURL(testCase.input)
                
                // Then: Should match expected
                if let expectedURL = testCase.expected {
                    #expect(result?.absoluteString == expectedURL)
                } else {
                    #expect(result == nil)
                }
            }
        }
    }
    
    // MARK: - Integration Tests
    
    @Suite("Integration Tests")
    struct IntegrationTests {
        
        @Test("End-to-end link creation flow")
        func testEndToEndLinkCreation() async {
            // Given: Text with potential link
            let text = "Check out our website"
            let url = URL(string: "https://catbird.app")!
            
            // When: Create attributed string with link
            var attributedString = AttributedString(text)
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 10)
            let end = attributedString.index(start, offsetByCharacters: 3) // "our"
            let range = start..<end
            
            var linkString = AttributedString("Catbird")
            linkString.link = url
            linkString.foregroundColor = .accentColor
            
            attributedString.replaceSubrange(range, with: linkString)
            
            // Then: Should create facets correctly
            do {
                let facets = try attributedString.toFacets()
                #expect(facets?.count == 1)
                
                if let facet = facets?.first {
                    #expect(facet.features.count == 1)
                    if case .appBskyRichtextFacetLink(let link) = facet.features.first {
                        #expect(link.uri.uriString() == "https://catbird.app")
                    }
                }
            } catch {
                Issue.record("Failed to convert to facets: \(error)")
            }
        }
        
        @Test("Cross-platform compatibility")
        func testCrossPlatformCompatibility() async {
            // Test that conversions work consistently across platforms
            let text = "Platform test 🔗 link"
            let nsAttributedString = NSAttributedString(string: text)
            
            // Convert to AttributedString and back
            let attributedString = AttributedString(nsAttributedString)
            let backToNS = NSAttributedString(attributedString)
            
            // Should preserve text content
            #expect(nsAttributedString.string == backToNS.string)
            #expect(String(attributedString.characters) == nsAttributedString.string)
        }
    }
}

// MARK: - Test Helpers

// MARK: - Test Helper Extensions

extension NSRange {
    var debugDescription: String {
        return "NSRange(location: \(location), length: \(length))"
    }
}

// MARK: - Mock Classes for Testing

/// Mock delegate for testing link creation requests
class MockLinkCreationDelegate: LinkCreationDelegate {
    var requestedText: String = ""
    var requestedRange: NSRange = NSRange()
    var requestCount: Int = 0
    
    func requestLinkCreation(for text: String, in range: NSRange) {
        requestedText = text
        requestedRange = range
        requestCount += 1
    }
    
    func reset() {
        requestedText = ""
        requestedRange = NSRange()
        requestCount = 0
    }
}

// MARK: - Test Data Generators

struct TestDataGenerator {
    static func createLargeTextWithLinks(linkCount: Int = 10) -> (text: String, facets: [RichTextFacetUtils.LinkFacet]) {
        let baseText = "This is paragraph text with content. "
        let text = String(repeating: baseText, count: 50)
        
        var facets: [RichTextFacetUtils.LinkFacet] = []
        let url = URL(string: "https://example.com")!
        
        for i in 0..<linkCount {
            let position = i * 100 + 10
            if position + 10 < text.count {
                let range = NSRange(location: position, length: 10)
                let facet = RichTextFacetUtils.LinkFacet(
                    range: range,
                    url: url,
                    displayText: "link\(i)"
                )
                facets.append(facet)
            }
        }
        
        return (text, facets)
    }
    
    static func createUnicodeTestCases() -> [(description: String, text: String, expectedCharCount: Int)] {
        return [
            ("Simple ASCII", "Hello World", 11),
            ("Emoji", "Hello 👋 World", 13),
            ("Complex Emoji", "Hello 👨‍👩‍👧‍👦 World", 13),
            ("RTL Arabic", "Hello مرحبا World", 17),
            ("Mixed Scripts", "Hello こんにちは World", 18),
            ("Combining Characters", "cafe\u{0301}", 5),
            ("Flag Emoji", "Hello 🇺🇸 World", 13)
        ]
    }
}

// MARK: - Performance Measurement Helpers

struct PerformanceMeasurement {
    static func measureTime<T>(operation: () throws -> T) rethrows -> (result: T, timeElapsed: TimeInterval) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try operation()
        let endTime = CFAbsoluteTimeGetCurrent()
        return (result, endTime - startTime)
    }
    
    static func measureAsyncTime<T>(operation: () async throws -> T) async rethrows -> (result: T, timeElapsed: TimeInterval) {
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = try await operation()
        let endTime = CFAbsoluteTimeGetCurrent()
        return (result, endTime - startTime)
    }
}

// MARK: - Platform-specific Color Helper

struct PlatformColor {
    #if os(iOS)
    static let platformSystemBlue = UIColor.systemBlue
    #elseif os(macOS)
    static let platformSystemBlue = NSColor.systemBlue
    #endif
}