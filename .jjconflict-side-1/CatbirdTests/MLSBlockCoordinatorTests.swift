import Testing
@testable import Catbird
import CatbirdMLSCore
import Foundation

@Suite("MLSBlockCoordinator")
struct MLSBlockCoordinatorTests {
    @Test("affectedConversations returns groups containing the target")
    @MainActor
    func affectedConversations_matchesMembership() async throws {
        let fake = FakeEnumerator(snapshots: [
            .init(id: "c1", memberDids: ["did:plc:alice", "did:plc:bob"]),
            .init(id: "c2", memberDids: ["did:plc:alice", "did:plc:charlie"]),
        ])
        let graph = FakeBlockPublisher()
        let coord = MLSBlockCoordinator(manager: fake, graphManager: graph)

        let affected = await coord.affectedConversations(for: "did:plc:bob")
        #expect(affected.map(\.id) == ["c1"])
    }

    @Test("block publishes first, then leaves affected groups")
    @MainActor
    func block_publishesThenLeaves() async throws {
        let fake = FakeEnumerator(snapshots: [
            .init(id: "c1", memberDids: ["did:plc:me", "did:plc:bob"]),
            .init(id: "c2", memberDids: ["did:plc:me", "did:plc:bob"]),
        ])
        let graph = FakeBlockPublisher()
        let coord = MLSBlockCoordinator(manager: fake, graphManager: graph)

        try await coord.block(did: "did:plc:bob")

        #expect(graph.blocked == ["did:plc:bob"])
        #expect(fake.leftIds.sorted() == ["c1", "c2"])
        #expect(graph.blockTimestamp! < fake.firstLeaveTimestamp!)
    }

    @Test("unblock does NOT rejoin groups")
    @MainActor
    func unblock_doesNotRejoin() async throws {
        let fake = FakeEnumerator(snapshots: [])
        let graph = FakeBlockPublisher()
        let coord = MLSBlockCoordinator(manager: fake, graphManager: graph)

        try await coord.unblock(did: "did:plc:bob")
        #expect(graph.unblocked == ["did:plc:bob"])
        #expect(fake.leftIds.isEmpty)
    }

    @Test("leave failures on one group don't abort others")
    @MainActor
    func block_tolerantToIndividualLeaveFailures() async throws {
        let fake = FakeEnumerator(
            snapshots: [
                .init(id: "c1", memberDids: ["me", "bob"]),
                .init(id: "c2", memberDids: ["me", "bob"]),
            ],
            leaveFailures: ["c1"]
        )
        let graph = FakeBlockPublisher()
        let coord = MLSBlockCoordinator(manager: fake, graphManager: graph)

        try await coord.block(did: "bob")
        #expect(graph.blocked == ["bob"])
        #expect(fake.leftIds == ["c2"]) // c1 failed, c2 still executed
    }
}

// MARK: - Fakes

private final class FakeEnumerator: MLSGroupReconcilable, @unchecked Sendable {
    private(set) var snapshots: [MLSConversationSnapshot]
    private(set) var leftIds: [String] = []
    private var firstLeaveAt: Date?
    private let failFor: Set<String>

    init(snapshots: [MLSConversationSnapshot], leaveFailures: Set<String> = []) {
        self.snapshots = snapshots
        self.failFor = leaveFailures
    }

    var firstLeaveTimestamp: Date? { firstLeaveAt }

    func listConversationSnapshots() async throws -> [MLSConversationSnapshot] { snapshots }

    func leaveConversation(convoId: String) async throws {
        if firstLeaveAt == nil { firstLeaveAt = Date() }
        if failFor.contains(convoId) {
            struct TestError: Error {}
            throw TestError()
        }
        leftIds.append(convoId)
        snapshots.removeAll { $0.id == convoId }
    }
}

private final class FakeBlockPublisher: BlockPublisher, @unchecked Sendable {
    private(set) var blocked: [String] = []
    private(set) var unblocked: [String] = []
    private(set) var blockTimestamp: Date?

    func block(did: String) async throws -> Bool {
        blocked.append(did)
        blockTimestamp = Date()
        return true
    }

    func unblock(did: String) async throws -> Bool {
        unblocked.append(did)
        return true
    }
}
