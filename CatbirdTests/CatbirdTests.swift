//
//  CatbirdTests.swift
//  CatbirdTests
//
//  Created by Josh LaCalamito on 2/14/25.
//

import Testing
import Catbird
import Petrel

struct CatbirdTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }
    
    // MARK: - Content Warning Tests
    
    @Test("Content warning system properly handles NSFW labels") 
    func testContentWarningForNSFWLabels() async throws {
        // Create a test label for NSFW content
        let nsfwLabel = ComAtprotoLabelDefs.Label(
            src: try DID(didString: "did:plc:test"),
            uri: "at://test.example/app.bsky.feed.post/1",
            cid: nil,
            val: "nsfw",
            neg: nil,
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        
        // Test that ContentLabelManager correctly identifies NSFW content for warnings
        let visibility = ContentLabelManager.getContentVisibility(labels: [nsfwLabel])
        
        // NSFW content should trigger warning by default
        #expect(visibility == .warn, "NSFW content should trigger warning visibility")
    }
    
    @Test("Content warning system handles empty labels") 
    func testContentWarningForNoLabels() async throws {
        // Test that content without labels shows normally
        let visibility = ContentLabelManager.getContentVisibility(labels: nil)
        
        // Content without labels should show normally
        #expect(visibility == .show, "Content without labels should show normally")
    }
    
    @Test("Content warning system properly blurs initially") 
    func testContentWarningInitialBlurState() async throws {
        // Create a test label for graphic content
        let graphicLabel = ComAtprotoLabelDefs.Label(
            src: try DID(didString: "did:plc:test"),
            uri: "at://test.example/app.bsky.feed.post/1",
            cid: nil,
            val: "graphic",
            cts: ATProtocolDate(date: Date()),
            exp: nil,
            sig: nil
        )
        
        // Test that ContentLabelManager correctly determines initial blur state
        let shouldBlur = ContentLabelManager.shouldInitiallyBlur(labels: [graphicLabel])
        
        // Graphic content should be initially blurred
        #expect(shouldBlur == true, "Graphic content should be initially blurred")
    }

}
