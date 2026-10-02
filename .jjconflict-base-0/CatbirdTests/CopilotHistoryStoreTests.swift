import XCTest
@testable import Catbird

final class CopilotHistoryStoreTests: XCTestCase {
    private let accountOne = "did:plc:account-one"
    private let accountTwo = "did:plc:account-two"

    // MARK: - Tests

    func testSaveSameConversationIDUpdatesInsteadOfDuplicating() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let conversationID = UUID()
        let initialTurn = CopilotStoredTurn(
            role: .user,
            text: "Hello",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let initialConversation = CopilotConversation(
            id: conversationID,
            accountDID: accountOne,
            context: .topic(name: "Swift", description: "Language", link: "https://swift.org"),
            turns: [initialTurn],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save(initialConversation)

        let updatedTurn = CopilotStoredTurn(
            role: .assistant,
            text: "Hi there!",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let updatedConversation = CopilotConversation(
            id: conversationID,
            accountDID: accountOne,
            context: .topic(name: "Swift", description: "Language", link: "https://swift.org"),
            turns: [initialTurn, updatedTurn],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try await store.save(updatedConversation)

        let stored = try await store.conversations(for: accountOne)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, conversationID)
        XCTAssertEqual(stored.first?.turns.count, 2)
        XCTAssertEqual(stored.first?.turns.last?.text, "Hi there!")
        XCTAssertEqual(stored.first?.updatedAt, Date(timeIntervalSince1970: 1_700_000_100))
    }

    func testConversationsRemainAccountIsolated() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let conversationOne = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: .search(query: "Catbird"),
            turns: [
                CopilotStoredTurn(role: .user, text: "Search Catbird")
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let conversationTwo = CopilotConversation(
            id: UUID(),
            accountDID: accountTwo,
            context: .profile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice"),
            turns: [
                CopilotStoredTurn(role: .user, text: "Show profile")
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_050)
        )

        try await store.save(conversationOne)
        try await store.save(conversationTwo)

        let accountOneConversations = try await store.conversations(for: accountOne)
        let accountTwoConversations = try await store.conversations(for: accountTwo)

        XCTAssertEqual(accountOneConversations.count, 1)
        XCTAssertEqual(accountOneConversations.first?.id, conversationOne.id)
        XCTAssertEqual(accountOneConversations.first?.accountDID, accountOne)

        XCTAssertEqual(accountTwoConversations.count, 1)
        XCTAssertEqual(accountTwoConversations.first?.id, conversationTwo.id)
        XCTAssertEqual(accountTwoConversations.first?.accountDID, accountTwo)
    }

    func testDeleteConversationRemovesOnlyThatConversation() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let conversationOne = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: .topic(name: "Topic 1", description: nil, link: "https://example.com/1"),
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let conversationTwo = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: .topic(name: "Topic 2", description: nil, link: "https://example.com/2"),
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try await store.save(conversationOne)
        try await store.save(conversationTwo)

        try await store.delete(conversationID: conversationOne.id, accountDID: accountOne)

        let stored = try await store.conversations(for: accountOne)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, conversationTwo.id)
    }

    func testClearRemovesOnlySpecifiedAccount() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let conversationOne = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: .feed(uri: "at://did:plc:custom/feed/one", name: "Feed One"),
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let conversationTwo = CopilotConversation(
            id: UUID(),
            accountDID: accountTwo,
            context: .feed(uri: "at://did:plc:custom/feed/two", name: "Feed Two"),
            turns: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try await store.save(conversationOne)
        try await store.save(conversationTwo)

        await store.clear(accountDID: accountOne)

        let accountOneConversations = try await store.conversations(for: accountOne)
        let accountTwoConversations = try await store.conversations(for: accountTwo)

        XCTAssertTrue(accountOneConversations.isEmpty)
        XCTAssertEqual(accountTwoConversations.count, 1)
        XCTAssertEqual(accountTwoConversations.first?.id, conversationTwo.id)
    }

    func testLatestConversationMatchingExactContextCanBeSelectedFromSortedResults() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let matchingContext = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/100",
            cid: "bafytest100",
            authorDID: "did:plc:alice",
            text: "Hello test post"
        )
        let differentContext = CopilotContext.post(
            uri: "at://did:plc:bob/app.bsky.feed.post/200",
            cid: "bafytest200",
            authorDID: "did:plc:bob",
            text: "Different post"
        )

        let olderMatching = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: matchingContext,
            turns: [CopilotStoredTurn(role: .user, text: "Older turn")],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let middleOther = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: differentContext,
            turns: [CopilotStoredTurn(role: .user, text: "Other turn")],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let newestMatching = CopilotConversation(
            id: UUID(),
            accountDID: accountOne,
            context: matchingContext,
            turns: [CopilotStoredTurn(role: .user, text: "Newest turn")],
            updatedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )

        try await store.save(olderMatching)
        try await store.save(middleOther)
        try await store.save(newestMatching)

        let allConversations = try await store.conversations(for: accountOne)
        let selectedLatest = allConversations.first(where: { $0.context == matchingContext })

        XCTAssertEqual(selectedLatest?.id, newestMatching.id)
        XCTAssertEqual(selectedLatest?.updatedAt, newestMatching.updatedAt)
        XCTAssertEqual(selectedLatest?.turns.first?.text, "Newest turn")

        let nonExistentContext = CopilotContext.search(query: "nonexistent")
        let nonExistentMatch = allConversations.first(where: { $0.context == nonExistentContext })
        XCTAssertNil(nonExistentMatch)
    }

    func testCorruptStoredHistoryThrowsInsteadOfBecomingEmpty() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let corruptData = Data("invalid-json".utf8)
        defaults.set(corruptData, forKey: "copilotHistory.v1.\(accountOne)")

        do {
            _ = try await store.conversations(for: accountOne)
            XCTFail("Expected conversations(for:) to throw for corrupt stored data")
        } catch {
            // Expected error
        }
    }

    func testLegacyPostHistoryIsReachableViaMatchesHistoryContextAndCanBeMigrated() async throws {
        let suiteName = "CopilotHistoryStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CopilotHistoryStore(defaults: defaults)

        let legacyContext = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: nil,
            authorDID: "did:plc:alice",
            text: "Old text"
        )
        let liveContext = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafylivecid123",
            authorDID: "did:plc:alice",
            text: "Updated live post text"
        )

        let convID = UUID()
        let legacyConv = CopilotConversation(
            id: convID,
            accountDID: accountOne,
            context: legacyContext,
            turns: [
                CopilotStoredTurn(role: .user, text: "Explain this post"),
                CopilotStoredTurn(role: .assistant, text: "Here is the explanation")
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await store.save(legacyConv)

        let all = try await store.conversations(for: accountOne)
        let matching = all.filter { $0.context.matchesHistoryContext(liveContext) }

        XCTAssertEqual(matching.count, 1)
        let loaded = try XCTUnwrap(matching.first)
        XCTAssertEqual(loaded.id, convID)
        XCTAssertEqual(loaded.turns.count, 2)

        // Migrate to live context
        let migrated = CopilotConversation(
            id: loaded.id,
            accountDID: loaded.accountDID,
            context: liveContext,
            turns: loaded.turns,
            updatedAt: loaded.updatedAt
        )
        try await store.save(migrated)

        let updatedAll = try await store.conversations(for: accountOne)
        XCTAssertEqual(updatedAll.count, 1)
        let updatedConv = try XCTUnwrap(updatedAll.first)
        XCTAssertEqual(updatedConv.id, convID)
        XCTAssertEqual(updatedConv.context, liveContext)
    }
}
