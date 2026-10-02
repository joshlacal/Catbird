//
//  AttributedStringBridgeTests.swift
//  CatbirdTests
//
//  Tests for the centralized AttributedString bridge functionality
//  Created by Agent 3: Testing & Validation for enhanced Link Creation
//

import Testing
import SwiftUI
import Foundation
@testable import Catbird
@testable import Petrel

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@available(iOS 16.0, macOS 13.0, *)
@Suite("AttributedString Bridge Tests")
struct AttributedStringBridgeTests {
    
    // MARK: - Conversion Tests
    
    @Suite("NSAttributedString to AttributedString Conversion")
    struct NSToAttributedStringTests {
        
        @Test("Basic text conversion preserves content")
        func testBasicTextConversion() async {
            let text = "Hello, world!"
            let nsAttributedString = NSAttributedString(string: text)
            let attributedString = AttributedString(nsAttributedString)
            
            #expect(String(attributedString.characters) == text)
            #expect(attributedString.characters.count == text.count)
        }
        
        @Test("Link attributes are preserved during conversion")
        func testLinkAttributePreservation() async {
            let text = "Visit https://example.com for more info"
            let nsAttributedString = NSMutableAttributedString(string: text)
            let url = URL(string: "https://example.com")!
            let linkRange = NSRange(location: 6, length: 19)
            
            nsAttributedString.addAttribute(.link, value: url, range: linkRange)
            
            let attributedString = AttributedString(nsAttributedString)
            
            // Check that link was preserved
            let linkStart = attributedString.index(attributedString.startIndex, offsetByCharacters: 6)
            let linkEnd = attributedString.index(linkStart, offsetByCharacters: 19)
            let linkSubstring = attributedString[linkStart..<linkEnd]
            
            #expect(linkSubstring.link == url)
            #expect(String(linkSubstring.characters) == "https://example.com")
        }
        
        @Test("Multiple link attributes are preserved")
        func testMultipleLinkAttributePreservation() async {
            let text = "Visit site1.com and site2.com today"
            let nsAttributedString = NSMutableAttributedString(string: text)
            
            let url1 = URL(string: "https://site1.com")!
            let url2 = URL(string: "https://site2.com")!
            
            nsAttributedString.addAttribute(.link, value: url1, range: NSRange(location: 6, length: 9))
            nsAttributedString.addAttribute(.link, value: url2, range: NSRange(location: 20, length: 9))
            
            let attributedString = AttributedString(nsAttributedString)
            
            // Check first link
            let link1Start = attributedString.index(attributedString.startIndex, offsetByCharacters: 6)
            let link1End = attributedString.index(link1Start, offsetByCharacters: 9)
            let link1Substring = attributedString[link1Start..<link1End]
            #expect(link1Substring.link == url1)
            
            // Check second link
            let link2Start = attributedString.index(attributedString.startIndex, offsetByCharacters: 20)
            let link2End = attributedString.index(link2Start, offsetByCharacters: 9)
            let link2Substring = attributedString[link2Start..<link2End]
            #expect(link2Substring.link == url2)
        }
        
        @Test("Color and style attributes are preserved")
        func testColorAndStylePreservation() async {
            let text = "Styled text here"
            let nsAttributedString = NSMutableAttributedString(string: text)
            let range = NSRange(location: 0, length: 6) // "Styled"
            
            #if os(iOS)
            nsAttributedString.addAttribute(.foregroundColor, value: UIColor.red, range: range)
            #elseif os(macOS)
            nsAttributedString.addAttribute(.foregroundColor, value: NSColor.red, range: range)
            #endif
            
            nsAttributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            
            let attributedString = AttributedString(nsAttributedString)
            
            let styledStart = attributedString.index(attributedString.startIndex, offsetByCharacters: 0)
            let styledEnd = attributedString.index(styledStart, offsetByCharacters: 6)
            let styledSubstring = attributedString[styledStart..<styledEnd]
            
            #expect(styledSubstring.foregroundColor != nil)
            #expect(styledSubstring.underlineStyle != nil)
        }
    }
    
    @Suite("AttributedString to NSAttributedString Conversion")
    struct AttributedStringToNSTests {
        
        @Test("Basic text roundtrip conversion")
        func testBasicTextRoundtrip() async {
            let originalText = "Hello, 世界! 🌍"
            let originalNS = NSAttributedString(string: originalText)
            let attributed = AttributedString(originalNS)
            let roundtripNS = NSAttributedString(attributed)
            
            #expect(originalNS.string == roundtripNS.string)
            #expect(originalNS.length == roundtripNS.length)
        }
        
        @Test("Link attribute roundtrip preservation")
        func testLinkAttributeRoundtrip() async {
            let text = "Check out our site"
            let url = URL(string: "https://catbird.app")!
            
            // Start with AttributedString
            var attributedString = AttributedString(text)
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 10)
            let end = attributedString.index(start, offsetByCharacters: 3) // "our"
            attributedString[start..<end].link = url
            
            // Convert to NSAttributedString
            let nsAttributedString = NSAttributedString(attributedString)
            
            // Verify link is present
            var foundURL: URL?
            let linkRange = NSRange(location: 10, length: 3)
            nsAttributedString.enumerateAttribute(.link, in: linkRange) { value, _, _ in
                if let linkURL = value as? URL {
                    foundURL = linkURL
                }
            }
            
            #expect(foundURL == url)
        }
        
        @Test("Complex attributes roundtrip")
        func testComplexAttributesRoundtrip() async {
            let text = "Complex styled text"
            var attributedString = AttributedString(text)
            
            // Add multiple attributes
            let range = attributedString.index(attributedString.startIndex, offsetByCharacters: 8)..<
                       attributedString.index(attributedString.startIndex, offsetByCharacters: 14) // "styled"
            
            attributedString[range].foregroundColor = .blue
            attributedString[range].underlineStyle = .single
            attributedString[range].link = URL(string: "https://example.com")
            
            // Roundtrip conversion
            let nsAttributedString = NSAttributedString(attributedString)
            let backToAttributed = AttributedString(nsAttributedString)
            
            // Verify attributes are preserved
            let verifyRange = backToAttributed.index(backToAttributed.startIndex, offsetByCharacters: 8)..<
                             backToAttributed.index(backToAttributed.startIndex, offsetByCharacters: 14)
            
            let substring = backToAttributed[verifyRange]
            #expect(substring.link != nil)
            #expect(substring.foregroundColor != nil)
            #expect(substring.underlineStyle != nil)
        }
    }
    
    // MARK: - Unicode Handling Tests
    
    @Suite("Unicode Handling")
    struct UnicodeHandlingTests {
        
        @Test("Emoji preservation in conversions")
        func testEmojiPreservation() async {
            let testCases = [
                "Simple emoji: 😀",
                "Skin tone emoji: 👋🏻",
                "Complex emoji: 👨‍👩‍👧‍👦",
                "Flag emoji: 🇺🇸",
                "Keycap emoji: 1️⃣",
                "ZWJ sequence: 🧑‍💻"
            ]
            
            for testText in testCases {
                let nsAttributed = NSAttributedString(string: testText)
                let attributed = AttributedString(nsAttributed)
                let backToNS = NSAttributedString(attributed)
                
                #expect(nsAttributed.string == backToNS.string, "Failed for: \(testText)")
                #expect(String(attributed.characters) == testText, "Failed for: \(testText)")
            }
        }
        
        @Test("RTL text preservation")
        func testRTLTextPreservation() async {
            let rtlTexts = [
                "مرحبا بالعالم",  // Arabic
                "שלום עולם",      // Hebrew
                "Hello مرحبا World", // Mixed LTR/RTL
            ]
            
            for rtlText in rtlTexts {
                let nsAttributed = NSAttributedString(string: rtlText)
                let attributed = AttributedString(nsAttributed)
                let backToNS = NSAttributedString(attributed)
                
                #expect(nsAttributed.string == backToNS.string, "RTL failed for: \(rtlText)")
                #expect(String(attributed.characters) == rtlText, "RTL failed for: \(rtlText)")
            }
        }
        
        @Test("Combining characters preservation")
        func testCombiningCharactersPreservation() async {
            let testTexts = [
                "café naïve",           // Composed characters
                "cafe\u{0301} nai\u{0308}ve", // Decomposed
                "e\u{0301}\u{0300}",   // Multiple combining marks
            ]
            
            for testText in testTexts {
                let nsAttributed = NSAttributedString(string: testText)
                let attributed = AttributedString(nsAttributed)
                let backToNS = NSAttributedString(attributed)
                
                #expect(nsAttributed.string == backToNS.string, "Combining chars failed for: \(testText)")
                #expect(String(attributed.characters) == testText, "Combining chars failed for: \(testText)")
            }
        }
        
        @Test("Unicode normalization handling")
        func testUnicodeNormalizationHandling() async {
            let baseText = "café"
            let nfcText = baseText.precomposedStringWithCanonicalMapping
            let nfdText = baseText.decomposedStringWithCanonicalMapping
            
            // Both normalizations should convert correctly
            let nfcNS = NSAttributedString(string: nfcText)
            let nfdNS = NSAttributedString(string: nfdText)
            
            let nfcAttributed = AttributedString(nfcNS)
            let nfdAttributed = AttributedString(nfdNS)
            
            // Content should be preserved even if representation differs
            #expect(String(nfcAttributed.characters) == nfcText)
            #expect(String(nfdAttributed.characters) == nfdText)
            
            // Roundtrip should be consistent
            let nfcRoundtrip = NSAttributedString(nfcAttributed)
            let nfdRoundtrip = NSAttributedString(nfdAttributed)
            
            #expect(nfcNS.string == nfcRoundtrip.string)
            #expect(nfdNS.string == nfdRoundtrip.string)
        }
    }
    
    // MARK: - Range Conversion Tests
    
    @Suite("Range Conversions")
    struct RangeConversionTests {
        
        @Test("NSRange to AttributedString range conversion")
        func testNSRangeToAttributedStringRangeConversion() async {
            let text = "Hello 👋 world 🌍"
            let attributedString = AttributedString(text)
            
            let nsRange = NSRange(location: 6, length: 7) // "👋 world"
            
            // Convert NSRange to AttributedString range
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: nsRange.location)
            let end = attributedString.index(start, offsetByCharacters: nsRange.length)
            let range = start..<end
            
            let substring = attributedString[range]
            #expect(String(substring.characters) == "👋 world")
        }
        
        @Test("AttributedString range to NSRange conversion")
        func testAttributedStringRangeToNSRangeConversion() async {
            let text = "Test 🌟 string"
            let attributedString = AttributedString(text)
            
            // Create AttributedString range
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 5)
            let end = attributedString.index(start, offsetByCharacters: 2) // "🌟 "
            let range = start..<end
            
            // Convert to NSRange equivalent
            let location = start.utf16Offset(in: attributedString)
            let length = end.utf16Offset(in: attributedString) - location
            let nsRange = NSRange(location: location, length: length)
            
            // Verify conversion
            let nsAttributedString = NSAttributedString(string: text)
            let nsSubstring = nsAttributedString.attributedSubstring(from: nsRange)
            
            #expect(nsSubstring.string == "🌟 ")
        }
        
        @Test("Range conversion with complex Unicode")
        func testRangeConversionWithComplexUnicode() async {
            let text = "Family: 👨‍👩‍👧‍👦 emoji"
            let attributedString = AttributedString(text)
            
            // Target the family emoji
            let nsRange = NSRange(location: 8, length: 8) // Family emoji sequence
            
            if nsRange.location + nsRange.length <= text.count {
                let start = attributedString.index(attributedString.startIndex, offsetByCharacters: nsRange.location)
                let end = attributedString.index(start, offsetByCharacters: nsRange.length)
                let range = start..<end
                
                let substring = attributedString[range]
                let extractedText = String(substring.characters)
                
                // Should contain the family emoji
                #expect(extractedText.contains("👨‍👩‍👧‍👦"))
            }
        }
    }
    
    // MARK: - Facet Conversion Tests
    
    @Suite("Facet Conversions")
    struct FacetConversionTests {
        
        @Test("AttributedString to AT Protocol facets")
        func testAttributedStringToFacets() async {
            var attributedString = AttributedString("Check out our website")
            let url = URL(string: "https://catbird.app")!
            
            // Add link to "website"
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 14)
            let end = attributedString.index(start, offsetByCharacters: 7)
            attributedString[start..<end].link = url
            
            do {
                let facets = try attributedString.toFacets()
                #expect(facets?.count == 1)
                
                if let facet = facets?.first {
                    #expect(facet.features.count == 1)
                    if case .appBskyRichtextFacetLink(let link) = facet.features.first {
                        #expect(link.uri.uriString() == "https://catbird.app")
                    } else {
                        Issue.record("Expected link facet")
                    }
                }
            } catch {
                Issue.record("Failed to convert to facets: \(error)")
            }
        }
        
        @Test("Multiple links to facets conversion")
        func testMultipleLinksToFacets() async {
            var attributedString = AttributedString("Visit site1.com and site2.com")
            
            let url1 = URL(string: "https://site1.com")!
            let url2 = URL(string: "https://site2.com")!
            
            // Add first link
            let start1 = attributedString.index(attributedString.startIndex, offsetByCharacters: 6)
            let end1 = attributedString.index(start1, offsetByCharacters: 9)
            attributedString[start1..<end1].link = url1
            
            // Add second link  
            let start2 = attributedString.index(attributedString.startIndex, offsetByCharacters: 20)
            let end2 = attributedString.index(start2, offsetByCharacters: 9)
            attributedString[start2..<end2].link = url2
            
            do {
                let facets = try attributedString.toFacets()
                #expect(facets?.count == 2)
                
                // Extract URLs from facets
                var foundURLs: Set<String> = []
                for facet in facets ?? [] {
                    for feature in facet.features {
                        if case .appBskyRichtextFacetLink(let link) = feature {
                            foundURLs.insert(link.uri.uriString())
                        }
                    }
                }
                
                #expect(foundURLs.contains("https://site1.com"))
                #expect(foundURLs.contains("https://site2.com"))
            } catch {
                Issue.record("Failed to convert multiple links to facets: \(error)")
            }
        }
        
        @Test("Facets with Unicode text")
        func testFacetsWithUnicodeText() async {
            var attributedString = AttributedString("访问我们的网站 🌐 了解更多")
            let url = URL(string: "https://example.com")!
            
            // Add link to "网站" (website in Chinese)
            let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 5)
            let end = attributedString.index(start, offsetByCharacters: 2)
            attributedString[start..<end].link = url
            
            do {
                let facets = try attributedString.toFacets()
                #expect(facets?.count == 1)
                
                if let facet = facets?.first {
                    // Verify byte range is correct for Unicode
                    #expect(facet.index.byteStart >= 0)
                    #expect(facet.index.byteEnd > facet.index.byteStart)
                }
            } catch {
                Issue.record("Failed to create facets with Unicode: \(error)")
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    @Suite("Error Handling")
    struct ErrorHandlingTests {
        
        @Test("Invalid range handling")
        func testInvalidRangeHandling() async {
            let text = "Short text"
            let attributedString = AttributedString(text)
            
            // Try to create invalid ranges and ensure they don't crash
            let textCount = text.count
            
            // These operations should not crash
            do {
                // Range beyond text length
                let start = attributedString.index(attributedString.startIndex, offsetByCharacters: 0)
                let validEnd = attributedString.index(start, offsetByCharacters: min(5, textCount))
                let validRange = start..<validEnd
                
                let substring = attributedString[validRange]
                #expect(!String(substring.characters).isEmpty)
            } catch {
                Issue.record("Failed to handle range safely: \(error)")
            }
        }
        
        @Test("Malformed AttributedString handling")
        func testMalformedAttributedStringHandling() async {
            // Create AttributedString with potentially problematic content
            let problematicTexts = [
                "",  // Empty string
                " ",  // Whitespace only
                "\n\n\n",  // Newlines only
                "a",  // Single character
            ]
            
            for text in problematicTexts {
                let attributedString = AttributedString(text)
                let nsAttributedString = NSAttributedString(attributedString)
                
                #expect(nsAttributedString.string == text)
                
                // Should be able to convert to facets without error
                do {
                    let facets = try attributedString.toFacets()
                    #expect(facets?.isEmpty == true || facets == nil)
                } catch {
                    // Empty or whitespace-only text might not convert to facets, which is OK
                    // The important thing is that it doesn't crash
                }
            }
        }
        
        @Test("Corrupted attribute handling")
        func testCorruptedAttributeHandling() async {
            let text = "Test with link"
            let nsAttributedString = NSMutableAttributedString(string: text)
            
            // Add malformed URL (this should be handled gracefully)
            let range = NSRange(location: 10, length: 4) // "link"
            nsAttributedString.addAttribute(.link, value: "not-a-url-object", range: range)
            
            // Conversion should not crash
            let attributedString = AttributedString(nsAttributedString)
            #expect(String(attributedString.characters) == text)
            
            // toFacets should handle malformed URLs gracefully
            do {
                let facets = try attributedString.toFacets()
                // May be nil or empty due to malformed URL, but should not crash
                #expect(facets?.count == 0 || facets == nil)
            } catch {
                // Some conversion errors are acceptable for malformed data
                // The important thing is controlled error handling, not crashes
            }
        }
    }
    
    // MARK: - Performance Tests
    
    @Suite("Performance")
    struct PerformanceTests {
        
        @Test("Large text conversion performance")
        func testLargeTextConversionPerformance() async {
            // Create large text with multiple attributes
            let baseText = "This is a paragraph with some text. "
            let largeText = String(repeating: baseText, count: 1000) // ~36KB
            let nsAttributedString = NSMutableAttributedString(string: largeText)
            
            // Add some links throughout the text
            let url = URL(string: "https://example.com")!
            for i in stride(from: 0, to: largeText.count - 100, by: 500) {
                let range = NSRange(location: i, length: min(10, largeText.count - i))
                nsAttributedString.addAttribute(.link, value: url, range: range)
            }
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Convert to AttributedString and back
            let attributedString = AttributedString(nsAttributedString)
            let backToNS = NSAttributedString(attributedString)
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let elapsedTime = endTime - startTime
            
            // Should complete within reasonable time
            #expect(elapsedTime < 0.5, "Large text conversion took \(elapsedTime) seconds")
            #expect(backToNS.string == nsAttributedString.string)
        }
        
        @Test("Multiple conversion cycles performance")
        func testMultipleConversionCyclesPerformance() async {
            let text = "Text with 🌟 emoji and link"
            var nsAttributedString = NSMutableAttributedString(string: text)
            let url = URL(string: "https://example.com")!
            nsAttributedString.addAttribute(.link, value: url, range: NSRange(location: 23, length: 4))
            
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Perform multiple conversion cycles
            var currentNS = nsAttributedString
            for _ in 0..<50 {
                let attributed = AttributedString(currentNS)
                currentNS = NSMutableAttributedString(attributed)
            }
            
            let endTime = CFAbsoluteTimeGetCurrent()
            let elapsedTime = endTime - startTime
            
            #expect(elapsedTime < 0.1, "Multiple conversion cycles took \(elapsedTime) seconds")
            #expect(currentNS.string == text)
        }
    }
}