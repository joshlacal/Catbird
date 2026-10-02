import XCTest
@testable import Catbird

final class CopilotProposalCoordinatorTests: XCTestCase {
    private let accountDID = "did:plc:self"
    private let profileContext = CopilotContext.profile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice")
    private let postContext = CopilotContext.post(
        uri: "at://did:plc:alice/app.bsky.feed.post/123",
        cid: "bafyreih7abc123",
        authorDID: "did:plc:alice",
        text: "Hello world"
    )
    private let ownPostContext = CopilotContext.post(
        uri: "at://did:plc:self/app.bsky.feed.post/789",
        cid: "bafyreih7own789",
        authorDID: "did:plc:self",
        text: "My own post"
    )
    private let threadContext = CopilotContext.thread(anchorURI: "at://did:plc:alice/app.bsky.feed.post/456")
    private let feedContext = CopilotContext.feed(uri: "at://did:plc:custom/app.bsky.feed.generator/popular", name: "Popular")
    private let searchContext = CopilotContext.search(query: "swift")

    // MARK: - Profile Context Action Tokens & Dispositions

    func testProfileActorActionTokensMapToExpectedProposalsAndDispositions() throws {
        let reversibleTokens: [String] = ["followActor", "unfollowActor", "muteActor", "unmuteActor"]
        for token in reversibleTokens {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: nil,
                context: profileContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .inlineConfirmation)
        }

        let dedicatedTokens: [String] = ["blockActor", "unblockActor", "reportActor", "addActorToList"]
        for token in dedicatedTokens {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: nil,
                context: profileContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .dedicatedFlow)
        }
    }

    // MARK: - Post Context Action Tokens & Dispositions

    func testPostActionTokensMapToExpectedProposalsAndDispositions() throws {
        let reversibleTokens: [String] = [
            "likePost",
            "unlikePost",
            "repostPost",
            "unrepostPost",
            "bookmarkPost",
            "unbookmarkPost",
            "hidePost",
            "unhidePost"
        ]
        for token in reversibleTokens {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: nil,
                context: postContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .inlineConfirmation)
        }

        let dedicatedTokensWithPayload: [(token: String, payload: String)] = [
            ("prepareReply", "Replying to post"),
            ("prepareQuote", "Quoting post")
        ]
        for (token, payload) in dedicatedTokensWithPayload {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: payload,
                context: postContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .dedicatedFlow)
        }

        let reportProposal = try CopilotProposalCoordinator.proposal(
            action: "reportPost",
            payload: nil,
            context: postContext,
            accountDID: accountDID
        )
        XCTAssertNotNil(reportProposal)
        XCTAssertEqual(reportProposal?.disposition, .dedicatedFlow)

        // deletePost returns nil when post authorDID != accountDID
        let deleteForeignPostProposal = try CopilotProposalCoordinator.proposal(
            action: "deletePost",
            payload: nil,
            context: postContext,
            accountDID: accountDID
        )
        XCTAssertNil(deleteForeignPostProposal, "deletePost must return nil when authorDID != accountDID")

        // delete own post maps
        let deleteOwnPostProposal = try CopilotProposalCoordinator.proposal(
            action: "deletePost",
            payload: nil,
            context: ownPostContext,
            accountDID: accountDID
        )
        XCTAssertEqual(
            deleteOwnPostProposal,
            .deletePost(uri: "at://did:plc:self/app.bsky.feed.post/789", cid: "bafyreih7own789")
        )
        XCTAssertEqual(deleteOwnPostProposal?.disposition, .dedicatedFlow)
    }

    // MARK: - Thread Context Action Tokens & Dispositions

    func testThreadActionTokensMapToExpectedProposalsAndDispositions() throws {
        let tokens: [String] = ["muteThread", "unmuteThread"]
        for token in tokens {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: nil,
                context: threadContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .inlineConfirmation)
        }
    }

    // MARK: - Feed Context Action Tokens & Dispositions

    func testFeedActionTokensMapToExpectedProposalsAndDispositions() throws {
        let tokens: [String] = ["saveFeed", "unsaveFeed", "pinFeed", "unpinFeed"]
        for token in tokens {
            let proposal = try CopilotProposalCoordinator.proposal(
                action: token,
                payload: nil,
                context: feedContext,
                accountDID: accountDID
            )
            XCTAssertNotNil(proposal, "Expected valid proposal for token: \(token)")
            XCTAssertEqual(proposal?.disposition, .inlineConfirmation)
        }
    }

    // MARK: - Smart Filters and Post Drafts

    func testSmartFilterAndPostDraftActionTokens() throws {
        let filterProposal = try CopilotProposalCoordinator.proposal(
            action: "createSmartFilter",
            payload: "mute reposts from bots",
            context: searchContext,
            accountDID: accountDID
        )
        XCTAssertNotNil(filterProposal)
        XCTAssertEqual(filterProposal?.disposition, .inlineConfirmation)

        let filterID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let smartFilterContext = CopilotContext.smartFilter(id: filterID, name: "Spam Guard")

        // enable/disable Smart Filter returns nil from profile/search/feed contexts
        for nonFilterContext in [profileContext, searchContext, feedContext, postContext] {
            XCTAssertNil(
                try CopilotProposalCoordinator.proposal(
                    action: "enableSmartFilter",
                    payload: filterID.uuidString,
                    context: nonFilterContext,
                    accountDID: accountDID
                ),
                "enableSmartFilter must return nil for non-smartFilter context"
            )
            XCTAssertNil(
                try CopilotProposalCoordinator.proposal(
                    action: "disableSmartFilter",
                    payload: filterID.uuidString,
                    context: nonFilterContext,
                    accountDID: accountDID
                ),
                "disableSmartFilter must return nil for non-smartFilter context"
            )
            XCTAssertNil(
                try CopilotProposalCoordinator.proposal(
                    action: "setSmartFilterEnabled",
                    payload: filterID.uuidString,
                    context: nonFilterContext,
                    accountDID: accountDID
                ),
                "setSmartFilterEnabled must return nil for non-smartFilter context"
            )
        }

        // enable/disable maps only from .smartFilter context and derives ID from context, ignoring payload
        let enableProposal = try CopilotProposalCoordinator.proposal(
            action: "enableSmartFilter",
            payload: "different-or-ignored-payload",
            context: smartFilterContext,
            accountDID: accountDID
        )
        XCTAssertEqual(enableProposal, .setSmartFilterEnabled(id: filterID, enabled: true))
        XCTAssertEqual(enableProposal?.disposition, .inlineConfirmation)

        let disableProposal = try CopilotProposalCoordinator.proposal(
            action: "disableSmartFilter",
            payload: nil,
            context: smartFilterContext,
            accountDID: accountDID
        )
        XCTAssertEqual(disableProposal, .setSmartFilterEnabled(id: filterID, enabled: false))
        XCTAssertEqual(disableProposal?.disposition, .inlineConfirmation)

        let setEnabledProposal = try CopilotProposalCoordinator.proposal(
            action: "setSmartFilterEnabled",
            payload: "ignored-id",
            context: smartFilterContext,
            accountDID: accountDID
        )
        XCTAssertEqual(setEnabledProposal, .setSmartFilterEnabled(id: filterID, enabled: true))
        XCTAssertEqual(setEnabledProposal?.disposition, .inlineConfirmation)

        let draftProposal = try CopilotProposalCoordinator.proposal(
            action: "preparePostDraft",
            payload: "A brand new draft post",
            context: searchContext,
            accountDID: accountDID
        )
        XCTAssertNotNil(draftProposal)
        XCTAssertEqual(draftProposal?.disposition, .dedicatedFlow)
    }

    // MARK: - Target Derivation

    func testTargetsDeriveFromContextNeverPayload() throws {
        let proposal = try CopilotProposalCoordinator.proposal(
            action: "followActor",
            payload: "did:plc:maliciousBob",
            context: profileContext,
            accountDID: accountDID
        )
        guard case .followActor(let targetDID)? = proposal else {
            XCTFail("Expected .followActor proposal")
            return
        }
        XCTAssertEqual(targetDID, "did:plc:alice")

        let postProposal = try CopilotProposalCoordinator.proposal(
            action: "likePost",
            payload: "at://did:plc:bob/app.bsky.feed.post/999",
            context: postContext,
            accountDID: accountDID
        )
        guard case .likePost(let uri, let cid)? = postProposal else {
            XCTFail("Expected .likePost proposal")
            return
        }
        XCTAssertEqual(uri, "at://did:plc:alice/app.bsky.feed.post/123")
        XCTAssertEqual(cid, "bafyreih7abc123")
    }

    // MARK: - Context Incompatibility & Unknown Actions

    func testIncompatibleContextReturnsNil() throws {
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "followActor", payload: nil, context: feedContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "likePost", payload: nil, context: profileContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "muteThread", payload: nil, context: searchContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "saveFeed", payload: nil, context: postContext, accountDID: accountDID))
    }

    func testUnknownActionTokenReturnsNil() throws {
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "destroyUniverse", payload: nil, context: profileContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "", payload: nil, context: postContext, accountDID: accountDID))
    }

    func testEmptyRequiredPayloadReturnsNil() throws {
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "preparePostDraft", payload: nil, context: searchContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "preparePostDraft", payload: "   ", context: searchContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "createSmartFilter", payload: "", context: searchContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "prepareReply", payload: "", context: postContext, accountDID: accountDID))
        XCTAssertNil(try CopilotProposalCoordinator.proposal(action: "prepareQuote", payload: " \n\t ", context: postContext, accountDID: accountDID))
    }

    // MARK: - Validation

    func testValidationPassesForMatchingContextAndAccount() throws {
        let proposal = try XCTUnwrap(
            CopilotProposalCoordinator.proposal(
                action: "likePost",
                payload: nil,
                context: postContext,
                accountDID: accountDID
            )
        )
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                proposal,
                context: postContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )
    }

    func testValidationThrowsAccountChangedWhenActiveAccountDiffers() throws {
        let proposal = try XCTUnwrap(
            CopilotProposalCoordinator.proposal(
                action: "likePost",
                payload: nil,
                context: postContext,
                accountDID: accountDID
            )
        )
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                proposal,
                context: postContext,
                expectedAccountDID: accountDID,
                currentAccountDID: "did:plc:anotherAccount"
            )
        ) { error in
            guard case CopilotProposalError.accountChanged = error else {
                XCTFail("Expected .accountChanged, got \(error)")
                return
            }
        }
    }

    func testValidationThrowsStaleTargetWhenTargetDiffersFromContext() throws {
        let mismatchedDIDProposal = CopilotProposal.followActor(actorDID: "did:plc:other")
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                mismatchedDIDProposal,
                context: profileContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            guard case CopilotProposalError.staleTarget = error else {
                XCTFail("Expected .staleTarget for mismatched actor DID, got \(error)")
                return
            }
        }

        let mismatchedURIProposal = CopilotProposal.likePost(
            uri: "at://did:plc:other/app.bsky.feed.post/999",
            cid: "bafyreih7abc123"
        )
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                mismatchedURIProposal,
                context: postContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            guard case CopilotProposalError.staleTarget = error else {
                XCTFail("Expected .staleTarget for mismatched post URI, got \(error)")
                return
            }
        }
    }

    func testPostDeleteProposalWithMatchingContextPassesValidation() throws {
        let deleteProposal = try XCTUnwrap(
            CopilotProposalCoordinator.proposal(
                action: "deletePost",
                payload: nil,
                context: ownPostContext,
                accountDID: accountDID
            )
        )
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                deleteProposal,
                context: ownPostContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )
    }

    func testDedicatedFlowDispositionRemainsDedicated() throws {
        let deleteProposal = try XCTUnwrap(
            CopilotProposalCoordinator.proposal(
                action: "deletePost",
                payload: nil,
                context: ownPostContext,
                accountDID: accountDID
            )
        )
        XCTAssertEqual(deleteProposal.disposition, .dedicatedFlow)
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                deleteProposal,
                context: ownPostContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )
    }

    // MARK: - Comprehensive Context Validation

    func testThreadValidation() throws {
        let threadProposal = CopilotProposal.muteThread(uri: "at://did:plc:alice/app.bsky.feed.post/456")
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                threadProposal,
                context: threadContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )

        let mismatchedThreadProposal = CopilotProposal.muteThread(uri: "at://did:plc:other/app.bsky.feed.post/999")
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                mismatchedThreadProposal,
                context: threadContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            XCTAssertEqual(error as? CopilotProposalError, .staleTarget)
        }
    }

    func testFeedValidation() throws {
        let feedProposal = CopilotProposal.saveFeed(uri: "at://did:plc:custom/app.bsky.feed.generator/popular")
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                feedProposal,
                context: feedContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )

        let mismatchedFeedProposal = CopilotProposal.saveFeed(uri: "at://did:plc:other/app.bsky.feed.generator/other")
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                mismatchedFeedProposal,
                context: feedContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            XCTAssertEqual(error as? CopilotProposalError, .staleTarget)
        }
    }

    func testContextIndependentProposalsPassValidation() throws {
        let draftProposal = CopilotProposal.preparePostDraft(text: "Draft content")
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                draftProposal,
                context: profileContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )
    }

    func testSmartFilterValidation() throws {
        let filterID = UUID()
        let matchingContext = CopilotContext.smartFilter(id: filterID, name: "Spam Guard")
        let filterToggleProposal = CopilotProposal.setSmartFilterEnabled(id: filterID, enabled: true)
        XCTAssertNoThrow(
            try CopilotProposalCoordinator.validate(
                filterToggleProposal,
                context: matchingContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        )

        let mismatchedFilterProposal = CopilotProposal.setSmartFilterEnabled(id: UUID(), enabled: true)
        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                mismatchedFilterProposal,
                context: matchingContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            XCTAssertEqual(error as? CopilotProposalError, .staleTarget)
        }

        XCTAssertThrowsError(
            try CopilotProposalCoordinator.validate(
                filterToggleProposal,
                context: feedContext,
                expectedAccountDID: accountDID,
                currentAccountDID: accountDID
            )
        ) { error in
            XCTAssertEqual(error as? CopilotProposalError, .staleTarget)
        }
    }
    // MARK: - Deterministic IDs

    func testDeterministicProposalIDs() {
        let draft1 = CopilotProposal.preparePostDraft(text: "Same content")
        let draft2 = CopilotProposal.preparePostDraft(text: "Same content")
        XCTAssertEqual(draft1.id, draft2.id)
        XCTAssertEqual(draft1.id, "draft:Same content")

        let reply = CopilotProposal.prepareReply(uri: "at://post/1", cid: "cid1", text: "Replying")
        XCTAssertEqual(reply.id, "reply:at://post/1:cid1:Replying")

        let follow = CopilotProposal.followActor(actorDID: "did:plc:alice")
        XCTAssertEqual(follow.id, "follow:did:plc:alice")
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        XCTAssertFalse(CopilotProposalError.accountChanged.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CopilotProposalError.staleTarget.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CopilotProposalError.requiresDedicatedFlow.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CopilotProposalError.unsupported.errorDescription?.isEmpty ?? true)
        XCTAssertFalse(CopilotProposalError.failed.errorDescription?.isEmpty ?? true)
    }
}
