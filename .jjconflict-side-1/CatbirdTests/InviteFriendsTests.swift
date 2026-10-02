import Foundation
import Testing
import UIKit
@testable import Catbird

@MainActor
struct InviteFriendsTests {
    
    // MARK: - G66: Canonical URL, Share, QR Generation & Scanner Validation
    
    @Test("Canonical URL drives display, share, QR generation and scanner validation")
    func canonicalURLDrivesDisplayShareQRAndScanner() async {
        // 1. Canonical invite URL generation and @ stripping
        let handleWithAt = "@alice.bsky.social"
        let urlWithAt = InviteURLHelper.canonicalInviteURL(for: handleWithAt)
        #expect(urlWithAt?.absoluteString == "https://bsky.app/profile/alice.bsky.social")
        
        let plainHandle = "bob.test"
        let urlPlain = InviteURLHelper.canonicalInviteURL(for: plainHandle)
        #expect(urlPlain?.absoluteString == "https://bsky.app/profile/bob.test")
        
        let handleWithSpaces = "   @charlie.pm   "
        let urlSpaces = InviteURLHelper.canonicalInviteURL(for: handleWithSpaces)
        #expect(urlSpaces?.absoluteString == "https://bsky.app/profile/charlie.pm")
        
        // 2. Empty handle rejection
        #expect(InviteURLHelper.canonicalInviteURL(for: "") == nil)
        #expect(InviteURLHelper.canonicalInviteURL(for: "   ") == nil)
        #expect(InviteURLHelper.canonicalInviteURL(for: "@") == nil)
        #expect(InviteURLHelper.canonicalInviteURL(for: "@@@") == nil)
        
        // 3. QR Code Generator output
        let qrImage = InviteURLHelper.generateQRCode(from: "https://bsky.app/profile/alice.bsky.social", size: 200)
        #expect(qrImage != nil)
        #expect(qrImage!.size.width > 0)
        #expect(qrImage!.size.height > 0)
        
        // Empty payload handling
        #expect(InviteURLHelper.generateQRCode(from: "") != nil)
        
        // 4. All six themes exist with valid colors and dark/light classification
        let allThemes = InviteTheme.allCases
        #expect(allThemes.count == 6)
        #expect(allThemes.map(\.rawValue) == ["Dawn", "Sunlight", "Day", "Dusk", "Twilight", "Night"])
        
        // Dark vs light theme classifications
        #expect(InviteTheme.dawn.isDark == false)
        #expect(InviteTheme.sunlight.isDark == false)
        #expect(InviteTheme.day.isDark == false)
        #expect(InviteTheme.dusk.isDark == true)
        #expect(InviteTheme.twilight.isDark == true)
        #expect(InviteTheme.night.isDark == true)
        
        for theme in allThemes {
            #expect(theme.gradientColors.count >= 2)
            #expect(!theme.id.isEmpty)
        }
        
        // 5. Valid HTTPS, HTTP, and schemeless profile URLs
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/profile/alice.bsky.social") == "alice.bsky.social")
        #expect(InviteURLHelper.parseProfilePayload("http://bsky.app/profile/bob.bsky.social") == "bob.bsky.social")
        #expect(InviteURLHelper.parseProfilePayload("bsky.app/profile/charlie.pm") == "charlie.pm")
        #expect(InviteURLHelper.parseProfilePayload("www.bsky.app/profile/david.test") == "david.test")
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/profile/did:plc:ragtjsm2j2vknwk2uhgahppm") == "did:plc:ragtjsm2j2vknwk2uhgahppm")
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/profile/@eric.bsky.social") == "eric.bsky.social")
        
        // 6. Rejection of lookalike hosts and non-profile paths
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app.attacker.com/profile/alice") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://evil-bsky.app/profile/alice") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://example.com/profile/alice") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/settings") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/search?q=test") == nil)
        #expect(InviteURLHelper.parseProfilePayload("https://bsky.app/profile/") == nil)
        #expect(InviteURLHelper.parseProfilePayload("not a url at all") == nil)
        #expect(InviteURLHelper.parseProfilePayload("") == nil)
    }
}
