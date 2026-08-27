import XCTest
@testable import Catbird

final class CopilotContextCodableTests: XCTestCase {
    func testLegacyV1PostContextWithoutCIDDecodesWithNilCID() throws {
        let legacyJSON = """
        {
          "post": {
            "uri": "at://did:plc:alice/app.bsky.feed.post/123",
            "authorDID": "did:plc:alice",
            "text": "Hello world"
          }
        }
        """

        let decoder = JSONDecoder()
        let context = try decoder.decode(CopilotContext.self, from: Data(legacyJSON.utf8))

        guard case .post(let uri, let cid, let authorDID, let text) = context else {
            XCTFail("Expected .post context")
            return
        }

        XCTAssertEqual(uri, "at://did:plc:alice/app.bsky.feed.post/123")
        XCTAssertNil(cid)
        XCTAssertEqual(authorDID, "did:plc:alice")
        XCTAssertEqual(text, "Hello world")
    }

    func testCurrentPostContextRoundTripsWithCID() throws {
        let original = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CopilotContext.self, from: data)

        XCTAssertEqual(decoded, original)
        if case .post(let uri, let cid, let authorDID, let text) = decoded {
            XCTAssertEqual(uri, "at://did:plc:alice/app.bsky.feed.post/123")
            XCTAssertEqual(cid, "bafyreih7abc123")
            XCTAssertEqual(authorDID, "did:plc:alice")
            XCTAssertEqual(text, "Hello world")
        } else {
            XCTFail("Expected .post context")
        }
    }

    func testPostActionProposalCannotBeCreatedWhenPostCIDIsNil() throws {
        let legacyPostWithoutCID = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: nil,
            authorDID: "did:plc:alice",
            text: "Hello world"
        )

        let thirdPartyPostActions = [
            "likePost",
            "unlikePost",
            "repostPost",
            "unrepostPost",
            "bookmarkPost",
            "unbookmarkPost",
            "hidePost",
            "unhidePost",
            "reportPost",
            "prepareReply",
            "prepareQuote"
        ]

        for action in thirdPartyPostActions {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: action,
                payload: action.starts(with: "prepare") ? "Draft content" : nil,
                context: legacyPostWithoutCID,
                accountDID: "did:plc:self"
            )
            XCTAssertNil(proposal, "Action \(action) must not produce a proposal when post CID is nil")
        }

        let ownLegacyPostWithoutCID = CopilotContext.post(
            uri: "at://did:plc:self/app.bsky.feed.post/789",
            cid: nil,
            authorDID: "did:plc:self",
            text: "My own post without CID"
        )
        let deleteProposal = try CopilotProposalCoordinator.proposal(
            action: "deletePost",
            payload: nil,
            context: ownLegacyPostWithoutCID,
            accountDID: "did:plc:self"
        )
        XCTAssertNil(deleteProposal, "deletePost must not produce a proposal when post CID is nil")
    }

    func testMatchesHistoryContextMatchesLegacyPostWithoutCIDToCurrentPostSymmetrically() {
        let legacyPost = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: nil,
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        let currentPost = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        let differentURIPost = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/456",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        let differentAuthorPost = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:bob",
            text: "Hello world"
        )

        XCTAssertTrue(legacyPost.matchesHistoryContext(currentPost))
        XCTAssertTrue(currentPost.matchesHistoryContext(legacyPost))

        XCTAssertFalse(legacyPost.matchesHistoryContext(differentURIPost))
        XCTAssertFalse(differentURIPost.matchesHistoryContext(legacyPost))

        XCTAssertFalse(legacyPost.matchesHistoryContext(differentAuthorPost))
        XCTAssertFalse(differentAuthorPost.matchesHistoryContext(legacyPost))
    }

    func testMatchesHistoryContextWithDifferentNonNilCIDsDoNotMatch() {
        let post1 = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc111",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        let post2 = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc222",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )

        XCTAssertFalse(post1.matchesHistoryContext(post2))
        XCTAssertFalse(post2.matchesHistoryContext(post1))
    }

    func testMatchesHistoryContextIgnoresDisplayTextDifferencesInPostContext() {
        let post1 = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        let post2 = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Different display text"
        )

        XCTAssertTrue(post1.matchesHistoryContext(post2))
        XCTAssertTrue(post2.matchesHistoryContext(post1))
    }

    func testMatchesHistoryContextNonPostContextsUseEquality() {
        let topic1 = CopilotContext.topic(name: "Swift", description: "Language", link: "https://swift.org")
        let topic2 = CopilotContext.topic(name: "Swift", description: "Language", link: "https://swift.org")
        let topic3 = CopilotContext.topic(name: "Rust", description: "Language", link: "https://rust-lang.org")

        XCTAssertTrue(topic1.matchesHistoryContext(topic2))
        XCTAssertTrue(topic2.matchesHistoryContext(topic1))
        XCTAssertFalse(topic1.matchesHistoryContext(topic3))

        let thread1 = CopilotContext.thread(anchorURI: "at://did:plc:alice/app.bsky.feed.post/123")
        let thread2 = CopilotContext.thread(anchorURI: "at://did:plc:alice/app.bsky.feed.post/123")
        let thread3 = CopilotContext.thread(anchorURI: "at://did:plc:alice/app.bsky.feed.post/456")

        XCTAssertTrue(thread1.matchesHistoryContext(thread2))
        XCTAssertFalse(thread1.matchesHistoryContext(thread3))

        let post = CopilotContext.post(
            uri: "at://did:plc:alice/app.bsky.feed.post/123",
            cid: "bafyreih7abc123",
            authorDID: "did:plc:alice",
            text: "Hello world"
        )
        XCTAssertFalse(post.matchesHistoryContext(thread1))
        XCTAssertFalse(thread1.matchesHistoryContext(post))
    }
}
