//
//  UnifiedChatRenderSignatureTests.swift
//  CatbirdTests
//

import Foundation
import Testing
@testable import Catbird

struct UnifiedChatRenderSignatureTests {
    private struct TestMessage: UnifiedChatMessage {
        var id: String
        var text: String
        var senderID: String
        var senderDisplayName: String?
        var senderAvatarURL: URL?
        var sentAt: Date
        var isFromCurrentUser: Bool
        var reactions: [UnifiedReaction]
        var embed: UnifiedEmbed?
        var sendState: MessageSendState
    }
    
    @Test("Signature changes when reaction emoji changes (count same)")
    func testSignatureChangesWhenReactionEmojiChanges() {
        let base = TestMessage(
            id: "m1",
            text: "Hello",
            senderID: "did:plc:alice",
            senderDisplayName: "Alice",
            senderAvatarURL: nil,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFromCurrentUser: false,
            reactions: [
                UnifiedReaction(messageID: "m1", emoji: "👍", senderDID: "did:plc:bob", isFromCurrentUser: false, reactedAt: nil)
            ],
            embed: nil,
            sendState: .sent
        )
        
        let swappedEmoji = TestMessage(
            id: "m1",
            text: "Hello",
            senderID: "did:plc:alice",
            senderDisplayName: "Alice",
            senderAvatarURL: nil,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFromCurrentUser: false,
            reactions: [
                UnifiedReaction(messageID: "m1", emoji: "❤️", senderDID: "did:plc:bob", isFromCurrentUser: false, reactedAt: nil)
            ],
            embed: nil,
            sendState: .sent
        )
        
        let baseSignature = UnifiedChatRenderSignature.messageSignature(for: base)
        let swappedSignature = UnifiedChatRenderSignature.messageSignature(for: swappedEmoji)
        
        #expect(baseSignature != swappedSignature)
    }
    
    @Test("Reactions signature is stable across ordering")
    func testReactionsSignatureStableAcrossOrdering() {
        let r1 = UnifiedReaction(messageID: "m1", emoji: "👍", senderDID: "a", isFromCurrentUser: false, reactedAt: nil)
        let r2 = UnifiedReaction(messageID: "m1", emoji: "👍", senderDID: "b", isFromCurrentUser: false, reactedAt: nil)
        let r3 = UnifiedReaction(messageID: "m1", emoji: "❤️", senderDID: "c", isFromCurrentUser: false, reactedAt: nil)
        
        let signature1 = UnifiedChatRenderSignature.reactionsSignature(for: [r1, r2, r3])
        let signature2 = UnifiedChatRenderSignature.reactionsSignature(for: [r3, r2, r1])
        
        #expect(signature1 == signature2)
    }
    
    @Test("Reactions signature changes when current-user reacted changes")
    func testReactionsSignatureChangesWhenCurrentUserReactedChanges() {
        let otherUser = UnifiedReaction(messageID: "m1", emoji: "👍", senderDID: "did:plc:other", isFromCurrentUser: false, reactedAt: nil)
        let currentUser = UnifiedReaction(messageID: "m1", emoji: "👍", senderDID: "did:plc:me", isFromCurrentUser: true, reactedAt: nil)
        
        let signatureOther = UnifiedChatRenderSignature.reactionsSignature(for: [otherUser])
        let signatureCurrent = UnifiedChatRenderSignature.reactionsSignature(for: [currentUser])
        
        #expect(signatureOther != signatureCurrent)
    }
}

