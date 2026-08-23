import XCTest
@testable import Catbird

final class CopilotProposalCoordinatorTests: XCTestCase {
    func testExactImperativeCreatesTypedProposal() {
        XCTAssertEqual(
            CopilotProposalCoordinator.proposal(
                for: "Mute this person",
                context: .profile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice")
            ),
            .mute(actorDID: "did:plc:alice")
        )
    }

    func testQuestionNeverCreatesMutationProposal() {
        XCTAssertNil(
            CopilotProposalCoordinator.proposal(
                for: "Should I mute this person?",
                context: .profile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice")
            )
        )
    }

    func testUnrecognizedLanguageNeverCreatesMutationProposal() {
        XCTAssertNil(
            CopilotProposalCoordinator.proposal(
                for: "Alice is annoying",
                context: .profile(did: "did:plc:alice", handle: "alice.test", displayName: "Alice")
            )
        )
    }
}
