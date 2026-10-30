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
        var replyContext: UnifiedMessageReplyContext? = nil
        var isSystemMessage: Bool = false
        var systemEvent: UnifiedSystemEvent? = nil
        var systemGroupEvents: [UnifiedSystemEvent]? = nil
        var isSystemGroup: Bool = false
        var isExpanded: Bool = false
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

    @Test("Signature changes when reply context is added or modified")
    func signatureChangesWhenReplyContextChanges() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        var msgWithoutReply = TestMessage(
            id: "m1",
            text: "Hello",
            senderID: "did:plc:alice",
            senderDisplayName: "Alice",
            senderAvatarURL: nil,
            sentAt: sentAt,
            isFromCurrentUser: false,
            reactions: [],
            embed: nil,
            sendState: .sent
        )
        let sig1 = UnifiedChatRenderSignature.messageSignature(for: msgWithoutReply)

        var msgWithReply = msgWithoutReply
        msgWithReply.replyContext = UnifiedMessageReplyContext(
            kind: .message(id: "orig1", senderDID: "did:plc:bob", senderDisplayName: "Bob", text: "Prior message"),
            referencedMessageID: "orig1",
            senderDisplayName: "Bob",
            previewText: "Prior message",
            isTappable: true
        )
        let sig2 = UnifiedChatRenderSignature.messageSignature(for: msgWithReply)

        #expect(sig1 != sig2)
    }

    @Test("Signature changes when system group expands or changes count")
    func signatureChangesWhenSystemGroupChanges() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let event1 = UnifiedSystemEvent(
            id: "e1",
            kind: .memberJoined(memberDID: "did:plc:alice", role: "member"),
            sentAt: sentAt,
            messageText: "Alice joined",
            iconName: "person.badge.plus"
        )
        let event2 = UnifiedSystemEvent(
            id: "e2",
            kind: .memberJoined(memberDID: "did:plc:bob", role: "member"),
            sentAt: sentAt,
            messageText: "Bob joined",
            iconName: "person.badge.plus"
        )

        let collapsedGroup = BlueskyMessageAdapter(
            systemGroupEvents: [event1, event2],
            groupID: "group1",
            isExpanded: false
        )
        let expandedGroup = BlueskyMessageAdapter(
            systemGroupEvents: [event1, event2],
            groupID: "group1",
            isExpanded: true
        )

        let sigCollapsed = UnifiedChatRenderSignature.messageSignature(for: collapsedGroup)
        let sigExpanded = UnifiedChatRenderSignature.messageSignature(for: expandedGroup)

        #expect(sigCollapsed != sigExpanded)
    }

}
