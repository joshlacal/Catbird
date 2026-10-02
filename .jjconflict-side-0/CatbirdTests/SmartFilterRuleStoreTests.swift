import XCTest
@testable import Catbird

final class SmartFilterRuleStoreTests: XCTestCase {
    func testRulesAreScopedByAccount() async throws {
        let suiteName = "SmartFilterRuleStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SmartFilterRuleStore(defaults: defaults)
        let rule = FeedFilterRule(
            accountDID: "did:plc:one",
            rawText: "Hide reposts",
            targetActorDID: "did:plc:alice",
            actorRoles: [.repostActor],
            postKinds: [.repost],
            action: .hide
        )

        try await store.save(rule)

        let firstAccountRules = await store.rules(for: "did:plc:one")
        let secondAccountRules = await store.rules(for: "did:plc:two")
        XCTAssertEqual(firstAccountRules, [rule])
        XCTAssertTrue(secondAccountRules.isEmpty)
    }
}
