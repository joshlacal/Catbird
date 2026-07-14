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

    @Test("Signature changes when MLS edit metadata changes")
    func signatureChangesWhenEditMetadataChanges() {
        let sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        let original = MLSMessageAdapter(
            id: "m1",
            text: "same text",
            senderDID: "did:plc:me",
            currentUserDID: "did:plc:me",
            sentAt: sentAt
        )
        let edited = MLSMessageAdapter(
            id: "m1",
            text: "same text",
            senderDID: "did:plc:me",
            currentUserDID: "did:plc:me",
            sentAt: sentAt,
            isEdited: true,
            editedAt: sentAt.addingTimeInterval(10)
        )

        #expect(
            UnifiedChatRenderSignature.messageSignature(for: original)
                != UnifiedChatRenderSignature.messageSignature(for: edited)
        )
    }

    @Test("MLS display ordering places not-yet-sequenced messages after confirmed ones")
    func testMLSDisplayOrderingSinksUnsequencedAfterConfirmed() {
        // A message with no server sequence (optimistic local send, or a row whose
        // seq has not loaded) sorts AFTER confirmed/sequenced messages. The server
        // sequence is the sole authority; interleaving un-sequenced messages by
        // timestamp (the previous behaviour) makes the comparator intransitive and
        // corrupts the whole sort. A genuinely seq-less remote row appears at the
        // bottom transiently and jumps to position once its seq loads + re-sort runs.
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

        let sorted = [remoteWithoutOrdering, laterOrderedMessage].sorted(by: MLSMessageAdapter.sortsInDisplayOrder)

        #expect(sorted.map(\.id) == ["ordered-later", "remote-missing-order"])
    }

    @Test("MLS display ordering is a strict weak ordering (transitive) across seq + time")
    func testMLSDisplayOrderingIsTransitive() {
        // Regression for the intransitive comparator that produced visibly
        // out-of-order chat. Server-sequence order and wall-clock order disagree
        // here, and one message is an un-sequenced optimistic send (seq=0) — the
        // exact shape that made the old comparator cycle (A<B by seq, B<C by time,
        // C<A by time) and corrupted Array.sort.
        let a = MLSMessageAdapter(
            id: "a-seq5",
            convoID: "convo-1",
            text: "seq 5, sent t=100",
            senderDID: "did:plc:alice",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 100),
            epoch: 7,
            sequence: 5
        )
        let b = MLSMessageAdapter(
            id: "b-seq10",
            convoID: "convo-1",
            text: "seq 10, sent t=50 (clock skew)",
            senderDID: "did:plc:bob",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 50),
            epoch: 7,
            sequence: 10
        )
        let c = MLSMessageAdapter(
            id: "c-optimistic",
            convoID: "convo-1",
            text: "optimistic local send, no server seq yet",
            senderDID: "did:plc:me",
            currentUserDID: "did:plc:me",
            sentAt: Date(timeIntervalSince1970: 75),
            epoch: nil,
            sequence: nil
        )

        // Canonical order: sequenced by seq (a=5 before b=10), un-sequenced last (c).
        let expected = ["a-seq5", "b-seq10", "c-optimistic"]

        // Every input permutation must yield the SAME order — the defining
        // property of a strict weak ordering that the old comparator lacked.
        let permutations: [[MLSMessageAdapter]] = [
            [a, b, c], [a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a],
        ]
        for permutation in permutations {
            let sorted = permutation.sorted(by: MLSMessageAdapter.sortsInDisplayOrder)
            #expect(sorted.map(\.id) == expected)
        }
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
