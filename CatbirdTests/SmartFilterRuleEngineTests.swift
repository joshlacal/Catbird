import XCTest
@testable import Catbird

final class SmartFilterRuleEngineTests: XCTestCase {
    func testStructuralReplyRuleHidesMatchingAuthorWithoutSemanticWork() {
        let rule = FeedFilterRule(
            accountDID: "did:plc:me",
            rawText: "Don't show replies from Alice",
            targetActorDID: "did:plc:alice",
            actorRoles: [.contentAuthor],
            postKinds: [.reply],
            action: .hide
        )
        let candidate = FeedFilterCandidate(
            cid: "bafyreicandidate",
            authorDID: "did:plc:alice",
            repostActorDID: nil,
            kind: .reply,
            text: "A reply",
            authoredAltText: []
        )

        XCTAssertEqual(
            FeedRuleEngine.evaluate(candidate, rules: [rule], semanticFeatures: nil),
            .hidden(ruleID: rule.id)
        )
    }

    func testSemanticCandidateIsPendingUntilFeaturesExist() {
        let rule = FeedFilterRule(
            accountDID: "did:plc:me",
            rawText: "Collapse angry posts from Alice",
            targetActorDID: "did:plc:alice",
            actorRoles: [.contentAuthor],
            postKinds: [.original],
            semanticGroups: [SemanticPredicateGroup(alternatives: [.tone(.anger), .tone(.hostility)])],
            action: .collapse
        )
        let candidate = FeedFilterCandidate(
            cid: "bafyreicandidate",
            authorDID: "did:plc:alice",
            repostActorDID: nil,
            kind: .original,
            text: "This is infuriating",
            authoredAltText: []
        )

        XCTAssertEqual(
            FeedRuleEngine.evaluate(candidate, rules: [rule], semanticFeatures: nil),
            .pending(ruleIDs: [rule.id])
        )
        XCTAssertEqual(
            FeedRuleEngine.evaluate(
                candidate,
                rules: [rule],
                semanticFeatures: PostSemanticFeatures(tones: [.anger])
            ),
            .collapsed(ruleID: rule.id)
        )
    }

    func testBroadBehaviorCannotHide() {
        let rule = FeedFilterRule(
            accountDID: "did:plc:me",
            rawText: "Hide Alice being sarcastic",
            targetActorDID: "did:plc:alice",
            actorRoles: [.contentAuthor],
            postKinds: [.original],
            semanticGroups: [SemanticPredicateGroup(alternatives: [.behavior(.sarcasm)])],
            action: .hide
        )

        XCTAssertEqual(rule.effectiveAction, .collapse)
    }

    func testUnrelatedActorIsUnaffected() {
        let rule = FeedFilterRule(
            accountDID: "did:plc:me",
            rawText: "Don't show Alice's reposts",
            targetActorDID: "did:plc:alice",
            actorRoles: [.repostActor],
            postKinds: [.repost],
            action: .hide
        )
        let candidate = FeedFilterCandidate(
            cid: "bafyreicandidate",
            authorDID: "did:plc:bob",
            repostActorDID: "did:plc:carol",
            kind: .repost,
            text: "Hello",
            authoredAltText: []
        )

        XCTAssertEqual(
            FeedRuleEngine.evaluate(candidate, rules: [rule], semanticFeatures: nil),
            .unaffected
        )
    }

    func testMustShowPositivePostDoesNotMatchAngerRule() {
        let rule = FeedFilterRule(
            accountDID: "did:plc:me",
            rawText: "Hide angry posts from Alice",
            targetActorDID: "did:plc:alice",
            actorRoles: [.contentAuthor],
            postKinds: [.original],
            semanticGroups: [SemanticPredicateGroup(alternatives: [.tone(.anger)])],
            action: .hide
        )
        let candidate = FeedFilterCandidate(
            cid: "bafypositive",
            authorDID: "did:plc:alice",
            repostActorDID: nil,
            kind: .original,
            text: "This makes me so happy",
            authoredAltText: []
        )

        XCTAssertEqual(
            FeedRuleEngine.evaluate(
                candidate,
                rules: [rule],
                semanticFeatures: PostSemanticFeatures(tones: [.positive])
            ),
            .unaffected
        )
    }
}
