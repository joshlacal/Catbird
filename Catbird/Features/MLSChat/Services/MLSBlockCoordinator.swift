import CatbirdMLSCore
import Foundation
import os.log

/// Protocol abstraction over `GraphManager`'s block/unblock, for testability.
///
/// `MLSBlockCoordinator` talks to this seam instead of `GraphManager`
/// directly so unit tests can assert ordering (block record before group
/// leaves) without a live ATProto client.
protocol BlockPublisher: AnyObject, Sendable {
    func block(did: String) async throws -> Bool
    func unblock(did: String) async throws -> Bool
}

extension GraphManager: BlockPublisher {}

/// Bridges Bluesky social blocks (ATProto) and MLS group membership.
///
/// Contract: `block(did:)` publishes the block record FIRST, then leaves
/// every MLS group that contains the target DID. The ordering matters — a
/// crash between the two steps is recovered at next launch by
/// `MLSBlockReconciler` (Task 7.1): on startup it re-reads the current
/// block list and leaves any still-shared groups.
///
/// `unblock(did:)` is intentionally NOT symmetric: removing a block does
/// not rejoin groups, because MLS requires a fresh invite from an existing
/// member to re-enter a group. Anything else would be cryptographically
/// impossible.
@MainActor
final class MLSBlockCoordinator {
    private let manager: MLSGroupReconcilable
    private let graphManager: BlockPublisher
    private let logger = Logger(subsystem: "blue.catbird", category: "MLSBlockCoordinator")

    init(manager: MLSGroupReconcilable, graphManager: BlockPublisher) {
        self.manager = manager
        self.graphManager = graphManager
    }

    /// Groups the current user would auto-leave if they blocked `did`.
    ///
    /// Intended for pre-flight UI — e.g. a confirmation dialog showing
    /// "Blocking will leave N shared conversations". Enumeration failures
    /// are logged and treated as "no affected conversations" rather than
    /// thrown, so UI can degrade gracefully.
    func affectedConversations(for did: String) async -> [MLSConversationSnapshot] {
        do {
            let all = try await manager.listConversationSnapshots()
            return all.filter { $0.memberDids.contains(did) }
        } catch {
            logger.error("affectedConversations: \(String(describing: error))")
            return []
        }
    }

    /// Publish the block record, then leave every shared MLS group.
    ///
    /// Per-group leave failures are logged and ignored — one failing group
    /// must not abort the rest. Any groups that remain shared after this
    /// call will be picked up by `MLSBlockReconciler` on the next app
    /// launch.
    func block(did: String) async throws {
        let affected = await affectedConversations(for: did)
        _ = try await graphManager.block(did: did)
        for convo in affected {
            do {
                try await manager.leaveConversation(convoId: convo.id)
                logger.info("Left \(convo.id, privacy: .public) after blocking \(did, privacy: .public)")
            } catch {
                logger.error(
                    "Failed to leave \(convo.id, privacy: .public) after blocking \(did, privacy: .public): \(String(describing: error))"
                )
            }
        }
    }

    /// Unblock. Does NOT rejoin groups — MLS requires a fresh invite from
    /// an existing member to re-enter a group.
    func unblock(did: String) async throws {
        _ = try await graphManager.unblock(did: did)
    }
}
