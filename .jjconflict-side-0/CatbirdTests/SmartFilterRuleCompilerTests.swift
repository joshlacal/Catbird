import XCTest
@testable import Catbird

final class SmartFilterRuleCompilerTests: XCTestCase {
    func testCompilesStructuralReplyRule() throws {
        let rule = try SmartFilterRuleCompiler.compileDeterministically(
            "Don't show replies from this person",
            accountDID: "did:plc:me",
            targetActorDID: "did:plc:alice"
        )

        XCTAssertEqual(rule.postKinds, [.reply])
        XCTAssertEqual(rule.actorRoles, [.contentAuthor])
        XCTAssertTrue(rule.semanticGroups.isEmpty)
        XCTAssertEqual(rule.action, .hide)
    }

    func testCompilesToneRule() throws {
        let rule = try SmartFilterRuleCompiler.compileDeterministically(
            "Collapse angry or hostile posts from this person",
            accountDID: "did:plc:me",
            targetActorDID: "did:plc:alice"
        )

        XCTAssertEqual(rule.action, .collapse)
        XCTAssertEqual(
            rule.semanticGroups,
            [SemanticPredicateGroup(alternatives: [.tone(.anger), .tone(.hostility)])]
        )
    }

    func testRejectsUnsupportedSubjectiveRule() {
        XCTAssertThrowsError(
            try SmartFilterRuleCompiler.compileDeterministically(
                "Don't show me whenever this guy is smug and annoying",
                accountDID: "did:plc:me",
                targetActorDID: "did:plc:alice"
            )
        )
    }
}
