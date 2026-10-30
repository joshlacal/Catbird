import Foundation
import Testing
import Petrel
@testable import Catbird

struct AskCatbirdToolPolicyTests {
    @Test func acceptsPostIdentityAndSharedBlueskyLink() throws {
        let uri = "at://did:plc:example/app.bsky.feed.post/3example"
        #expect(try AskCatbirdToolPolicy.postURI("  \(uri)\n").uriString() == uri)
        #expect(try AskCatbirdToolPolicy.postURI(
            "https://bsky.app/profile/alice.bsky.social/post/3example?ref=share"
        ).uriString() == "at://alice.bsky.social/app.bsky.feed.post/3example")
    }

    @Test(arguments: [
        "https://example.com/profile/alice.bsky.social/post/3example",
        "https://bsky.app/profile/alice.bsky.social",
        "at://did:plc:example/app.bsky.feed.generator/feed",
        "at://did:plc:example/app.bsky.feed.post/",
        "at://did:plc:example/app.bsky.feed.post/post/extra",
        "https://bsky.app@evil.example/profile/alice.bsky.social/post/post"
    ])
    func rejectsNonPostReferences(_ input: String) {
        #expect(throws: (any Error).self) {
            try AskCatbirdToolPolicy.postURI(input)
        }
    }

    @Test func longAncestorChainCannotExcludeRequestedPost() {
        let depths = Array(-30 ... 0) + [1, 2, 3]
        let selected = depths.sorted {
            AskCatbirdToolPolicy.precedes(depth: $0, otherDepth: $1)
        }.prefix(6)
        #expect(Array(selected) == [0, -1, 1, -2, 2, -3])
    }

    @Test func historyLeavesRoomForTheFetchedResult() async throws {
        let turns = (0 ..< 4).map { index in
            CopilotStoredTurn(
                id: UUID(),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "History turn \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        }
        // Without read-result headroom, both pairs fit (1000 + 2500 < 4096),
        // but the subsequent 1024-token tool response would overflow.
        let selection = try await CopilotContextBudget.selectHistory(
            turns: turns,
            modelContextSize: 4096,
            reservedTokenCount: 1000 + AskCatbirdToolPolicy.onDeviceToolResultTokenReserve,
            candidateTokenCount: { 100 + $0.count * 600 }
        )
        #expect(selection.fits)
        #expect(selection.retainedTurns.map(\.id) == Array(turns.suffix(2)).map(\.id))
        let remainingAfterPromptAndAnswer = selection.tokenLimit - 1000
            - (100 + selection.retainedTurns.count * 600)
        #expect(remainingAfterPromptAndAnswer >= AskCatbirdToolPolicy.onDeviceToolResultTokenReserve)
    }

    @Test func invalidReferenceErrorDoesNotExposeMachineIdentity() {
        let error = BlueskyAgentError.invalidThreadURI("at://private/invalid")
        #expect(!error.localizedDescription.contains("at://"))
    }
}

#if canImport(FoundationModels)
struct AskCatbirdThreadFormatterTests {
    private static var formatterAvailable: Bool {
        if #available(iOS 26.0, macOS 26.0, *) { return true }
        return false
    }

    @Test(.enabled(if: formatterAvailable), arguments: [2, 3])
    func includesEveryShortThreadPostWithFullTextAndReplyIdentity(_ count: Int) throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let fullText = String(repeating: "z", count: 240) + "\nThe ending matters."
        let items = try (0 ..< count).map { index in
            try item(index: index, depth: index, text: fullText + " \(index)")
        }
        // Exercise the same plain JSONDecoder used by Petrel's endpoint, including
        // its record union decoding, before testing the actual tool formatter.
        let wireData = try JSONEncoder().encode(AppBskyUnspeccedGetPostThreadV2.Output(thread: items, hasOtherReplies: false))
        let decoded = try JSONDecoder().decode(AppBskyUnspeccedGetPostThreadV2.Output.self, from: wireData)
        let transcript = try AskCatbirdThreadFormatter.format(decoded)
        let payload = try payload(transcript.text)
        let rows = try #require(payload["posts"] as? [[String: Any]])
        #expect(rows.count == count)
        #expect(payload["omittedReturnedItems"] as? Int == 0)
        #expect(payload["serverReportsAdditionalContext"] as? Bool == false)
        for index in 0 ..< count {
            let row = try #require(rows.first { $0["id"] as? String == uri(index) })
            #expect(row["author"] as? String == "@alice.bsky.social")
            #expect(row["text"] as? String == fullText + " \(index)")
            #expect(row["textTruncated"] as? Bool == false)
            if index > 0 {
                #expect(row["replyTo"] as? String == uri(index - 1))
                #expect(row["root"] as? String == uri(0))
            }
        }
        #expect(transcript.sources.count == count)
    }

    @Test(.enabled(if: formatterAvailable)) func longThreadPreservesFocusAndDisclosesOmissions() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let items = try (0 ..< 9).map { index in
            try item(index: index, depth: index - 7, text: String(repeating: "x", count: 250))
        }
        let transcript = try AskCatbirdThreadFormatter.format(.init(thread: items, hasOtherReplies: true))
        let payload = try payload(transcript.text)
        let rows = try #require(payload["posts"] as? [[String: Any]])
        #expect(rows.count == 6)
        #expect(rows.first?["id"] as? String == uri(7))
        #expect(rows.first?["role"] as? String == "focus")
        #expect(rows.first?["textTruncated"] as? Bool == true)
        #expect(payload["omittedReturnedItems"] as? Int == 3)
        #expect(payload["serverReportsAdditionalContext"] as? Bool == true)
    }

    @Test(.enabled(if: formatterAvailable)) func unreadableFocusDoesNotReturnNeighborsAsTheAnswer() throws {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let emptyFocus = try item(index: 0, depth: 0, text: "")
        let reply = try item(index: 1, depth: 1, text: "Neighbor must not replace focus")
        #expect(throws: (any Error).self) {
            try AskCatbirdThreadFormatter.format(.init(thread: [emptyFocus, reply], hasOtherReplies: false))
        }
    }

    private func payload(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func uri(_ index: Int) -> String {
        "at://alice.bsky.social/app.bsky.feed.post/post\(index)"
    }

    private func item(index: Int, depth: Int, text: String) throws -> AppBskyUnspeccedGetPostThreadV2.ThreadItem {
        let cid = try CID.parse("bafyreie5cvw4ly5exbmswkevvohgmc4uh5u5axhmxj3apcgu5wmlmj7x7i")
        let postURI = try ATProtocolURI(uriString: uri(index))
        let reply: AppBskyFeedPost.ReplyRef?
        if index > 0 {
            reply = try .init(
                root: .init(uri: ATProtocolURI(uriString: uri(0)), cid: cid),
                parent: .init(uri: ATProtocolURI(uriString: uri(index - 1)), cid: cid)
            )
        } else {
            reply = nil
        }
        let post = try AppBskyFeedDefs.PostView(
            uri: postURI,
            cid: cid,
            author: .init(did: DID(didString: "did:plc:example"), handle: Handle(handleString: "alice.bsky.social")),
            record: .knownType(AppBskyFeedPost(text: text, reply: reply, createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000)))),
            indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
        )
        return .init(uri: postURI, depth: depth, value: .appBskyUnspeccedDefsThreadItemPost(.init(
            post: post, moreParents: false, moreReplies: 0, opThread: true,
            hiddenByThreadgate: false, mutedByViewer: false
        )))
    }
}
#endif
