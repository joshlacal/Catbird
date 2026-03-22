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

    @Test("MLS display ordering does not sink missing metadata to the end")
    func testMLSDisplayOrderingFallsBackWithoutSinkingMessage() {
        let remoteWithoutOrdering = MLSMessageAdapter(
            id: "remote-missing-order",
            convoID: "convo-1",
            text: "Earlier remote message",
            senderDID: "did:plc:alice",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 100),
            epoch: nil,
            sequence: nil
        )

        let laterOrderedMessage = MLSMessageAdapter(
            id: "ordered-later",
            convoID: "convo-1",
            text: "Later ordered message",
            senderDID: "did:plc:bob",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 200),
            epoch: 4,
            sequence: 12
        )

        let sorted = [laterOrderedMessage, remoteWithoutOrdering].sorted(by: MLSMessageAdapter.sortsInDisplayOrder)

        #expect(sorted.map(\.id) == ["remote-missing-order", "ordered-later"])
    }

    @Test("MLS display ordering keeps confirmed epoch and sequence authoritative")
    func testMLSDisplayOrderingUsesConfirmedEpochAndSequence() {
        let laterTimestampLowerSequence = MLSMessageAdapter(
            id: "seq-1",
            convoID: "convo-1",
            text: "First by MLS order",
            senderDID: "did:plc:alice",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 300),
            epoch: 8,
            sequence: 1
        )

        let earlierTimestampHigherSequence = MLSMessageAdapter(
            id: "seq-2",
            convoID: "convo-1",
            text: "Second by MLS order",
            senderDID: "did:plc:bob",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 200),
            epoch: 8,
            sequence: 2
        )

        let sorted = [earlierTimestampHigherSequence, laterTimestampLowerSequence].sorted(by: MLSMessageAdapter.sortsInDisplayOrder)

        #expect(sorted.map(\.id) == ["seq-1", "seq-2"])
    }
}
