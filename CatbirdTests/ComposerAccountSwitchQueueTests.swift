import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Scene-bound account-switch handoffs")
struct ComposerAccountSwitchQueueTests {
  private let alice = "did:plc:alice"
  private let bob = "did:plc:bob"
  private let carol = "did:plc:carol"

  @Test("Only the originating scene can claim the exact ready account and token once")
  func exactClaim() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    let attempt = try accepted(queue.begin(
      to: bob, transfer: snapshot, authenticatedAccountDID: alice, isTransitioning: false
    ))
    let envelope = try #require(attempt.reopen)
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil, "An in-flight attempt is not ready")
    #expect(queue.finish(id: attempt.id, authenticatedAccountDID: bob)
      == .switched(accountDID: bob, reopenID: envelope.id))

    let revision = queue.revision
    #expect(queue.claim(id: envelope.id, sourceSceneID: UUID(), accountDID: bob,
      authenticatedAccountDID: bob) == nil)
    #expect(queue.claim(id: UUID(), sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil)
    #expect(queue.claim(id: envelope.id, sourceSceneID: snapshot.claim.sceneID, accountDID: alice,
      authenticatedAccountDID: alice) == nil)
    #expect(queue.claim(id: envelope.id, sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: nil) == nil, "Launching or restricted lifecycle is not ready")
    #expect(queue.revision == revision, "Rejected observers cannot mutate another scene's item")

    let claimed = try #require(queue.claim(id: envelope.id, sourceSceneID: snapshot.claim.sceneID,
      accountDID: bob, authenticatedAccountDID: bob))
    #expect(claimed.draft == snapshot.draft)
    #expect(claimed.sourceSceneID == snapshot.claim.sceneID)
    #expect(claimed.accountDID == bob)
    #expect(claimed.id != snapshot.claim.token)
    #expect(queue.claim(id: envelope.id, sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil, "A second observer loses the synchronous claim")
  }

  @Test("Overlapping switch rejection preserves the first target and body")
  func overlappingSwitches() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot(text: "First scene")
    let attempt = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    let revision = queue.revision
    expectRejected(queue.begin(to: carol, transfer: makeSnapshot(text: "Second scene"),
      authenticatedAccountDID: alice, isTransitioning: false), as: .busy)
    #expect(queue.revision == revision)
    _ = queue.finish(id: attempt.id, authenticatedAccountDID: bob)
    let pending = try #require(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID,
      accountDID: bob, authenticatedAccountDID: bob))
    #expect(pending.draft.postText == "First scene")
    #expect(pending.id == attempt.reopen?.id)
  }

  @Test("External transition and same-account selection never stage a transfer")
  func rejectedAdmission() {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    expectRejected(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: true), as: .busy)
    expectRejected(queue.begin(to: alice, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false), as: .unchanged)
    #expect(queue.revision == 0)
    #expect(!queue.isSwitching)
    if case .rejected(.failed) = queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: carol, isTransitioning: false) {
      #expect(queue.revision == 0)
    } else {
      Issue.record("A snapshot from another account must be rejected")
    }
  }

  @Test("Failure and mismatched authentication never publish a reopen")
  func failedAuthentication() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    let failed = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    queue.fail(id: failed.id)
    #expect(!queue.isSwitching)
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil)

    let mismatched = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    if case .failed = queue.finish(id: mismatched.id, authenticatedAccountDID: carol) {
      #expect(!queue.isSwitching)
    } else {
      Issue.record("Authentication for another account cannot succeed")
    }
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil)
  }

  @Test("Cancelled and stale callbacks cannot finish or erase a newer attempt")
  func staleCompletion() throws {
    let queue = ComposerAccountSwitchQueue()
    let old = try accepted(queue.begin(to: bob, transfer: makeSnapshot(),
      authenticatedAccountDID: alice, isTransitioning: false))
    queue.invalidate()
    let snapshot = makeSnapshot(text: "New transfer")
    let newer = try accepted(queue.begin(to: carol, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    let revision = queue.revision
    queue.fail(id: old.id)
    #expect(queue.finish(id: old.id, authenticatedAccountDID: bob) == .cancelled)
    #expect(queue.isSwitching)
    #expect(queue.revision == revision)
    #expect(queue.finish(id: newer.id, authenticatedAccountDID: carol)
      == .switched(accountDID: carol, reopenID: newer.reopen?.id))
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID, accountDID: carol,
      authenticatedAccountDID: carol)?.draft.postText == "New transfer")
  }

  @Test("Cancellation before retirement admission prevents commit and reopen")
  func cancellationBeforeCommit() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    let attempt = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    queue.requestCancellation(id: attempt.id)
    #expect(!queue.canContinue(id: attempt.id))
    #expect(!queue.beginCommit(id: attempt.id))
    #expect(queue.finish(id: attempt.id, authenticatedAccountDID: bob) == .cancelled)
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob) == nil)
  }

  @Test("Cancellation after retirement admission preserves a verified successful commit")
  func cancellationAfterCommit() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    let attempt = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    #expect(queue.beginCommit(id: attempt.id))
    queue.requestCancellation(id: attempt.id)
    #expect(queue.canContinue(id: attempt.id))
    #expect(queue.hasBegunCommit(id: attempt.id))
    #expect(queue.finish(id: attempt.id, authenticatedAccountDID: bob)
      == .switched(accountDID: bob, reopenID: attempt.reopen?.id))
    let pending = try #require(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID,
      accountDID: bob, authenticatedAccountDID: bob))
    #expect(pending.draft == snapshot.draft)
    #expect(queue.claim(id: pending.id, sourceSceneID: UUID(), accountDID: bob,
      authenticatedAccountDID: bob) == nil, "Committed cancellation cannot broaden scene ownership")
    #expect(queue.claim(id: pending.id, sourceSceneID: snapshot.claim.sceneID, accountDID: bob,
      authenticatedAccountDID: bob)?.id == pending.id)
  }

  @Test("A later no-draft switch and account ABA cannot resurrect an old handoff")
  func noDraftAndAccountABA() throws {
    let queue = ComposerAccountSwitchQueue()
    let snapshot = makeSnapshot()
    let first = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    let oldID = try #require(first.reopen?.id)
    _ = queue.finish(id: first.id, authenticatedAccountDID: bob)
    let back = try accepted(queue.begin(to: alice, transfer: nil,
      authenticatedAccountDID: bob, isTransitioning: false))
    #expect(queue.finish(id: back.id, authenticatedAccountDID: alice)
      == .switched(accountDID: alice, reopenID: nil))
    let again = try accepted(queue.begin(to: bob, transfer: snapshot,
      authenticatedAccountDID: alice, isTransitioning: false))
    _ = queue.finish(id: again.id, authenticatedAccountDID: bob)
    #expect(queue.claim(id: oldID, sourceSceneID: snapshot.claim.sceneID,
      accountDID: bob, authenticatedAccountDID: bob) == nil)
    #expect(queue.pendingReopen(sourceSceneID: snapshot.claim.sceneID,
      accountDID: bob, authenticatedAccountDID: bob)?.id == again.reopen?.id)
  }

  @Test("Logout waits for every admitted authentication operation before proceeding")
  func logoutOperationBarrier() async {
    let barrier = AccountSwitchOperationBarrier()
    var events: [String] = []
    barrier.begin()
    barrier.begin()
    let operations = Task { @MainActor in
      events.append("authentication settled")
      barrier.end()
      await Task.yield()
      events.append("rollback settled")
      barrier.end()
    }
    await barrier.waitUntilIdle()
    events.append("credentials cleared")
    await operations.value
    #expect(events == ["authentication settled", "rollback settled", "credentials cleared"])
    // Waiting again is immediate; completion does not leave a stale continuation behind.
    await barrier.waitUntilIdle()
  }

  @Test("Logout retains and retires the admitted source after launching hides its lifecycle")
  func logoutRetainsSwitchSource() throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: project.appendingPathComponent("Catbird/Core/State/AppStateManager.swift"),
      encoding: .utf8)
    let switchStart = try #require(source.range(of: "func switchAccount("))
    let switchBody = String(source[switchStart.lowerBound...])
    let capture = try #require(switchBody.range(of: "admittedSwitchSource = (attempt.id, source)"))
    let launching = try #require(switchBody.range(of: "lifecycle = .launching"))
    #expect(capture.lowerBound < launching.lowerBound)
    #expect(switchBody.contains("if admittedSwitchSource?.attemptID == attempt.id { admittedSwitchSource = nil }"))

    let logoutStart = try #require(source.range(of: "func logout(isManual: Bool = true) async {"))
    let logoutEnd = try #require(source.range(of: "// MARK: - Account Restriction", range: logoutStart.upperBound..<source.endIndex))
    let logout = String(source[logoutStart.lowerBound..<logoutEnd.lowerBound])
    let retainedSource = try #require(logout.range(of: "let interruptedSwitchSource = admittedSwitchSource?.state"))
    let revoke = try #require(logout.range(of: "composerSwitchQueue.invalidate()"))
    let settle = try #require(logout.range(of: "await accountSwitchOperationBarrier.waitUntilIdle()"))
    let retire = try #require(logout.range(of: "try await currentState.retireAfterAccountSwitch()"))
    let evict = try #require(logout.range(of: "authenticatedStates.removeValue(forKey: currentUserDID)"))
    let clearAuth = try #require(logout.range(of: "await authManager.logout(isManual: isManual)"))
    #expect(retainedSource.lowerBound < revoke.lowerBound)
    #expect(revoke.lowerBound < settle.lowerBound)
    #expect(settle.lowerBound < retire.lowerBound)
    #expect(retire.lowerBound < evict.lowerBound)
    #expect(evict.lowerBound < clearAuth.lowerBound)
    #expect(logout.contains("let loggingOutState = lifecycle.appState ?? interruptedSwitchSource"))
    #expect(logout.contains("if currentState === interruptedSwitchSource"))
  }

  @Test("Rollback retains a restricted source lifecycle without resuming normal services")
  func restrictedSourceRecovery() throws {
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: project.appendingPathComponent("Catbird/Core/State/AppStateManager.swift"),
      encoding: .utf8)
    let start = try #require(source.range(of: "private func recoverFromSwitchFailure("))
    let end = try #require(source.range(of: "func pendingComposerReopen(", range: start.upperBound..<source.endIndex))
    let recovery = String(source[start.lowerBound..<end.lowerBound])
    #expect(recovery.contains("if let previousLifecycle, let previousState = previousLifecycle.appState"))
    #expect(!recovery.contains("lifecycle = .authenticated(previousState)"))
    let restoration = try #require(recovery.range(of: "lifecycle = previousLifecycle"))
    let normalServiceGuard = try #require(recovery.range(of: "if previousLifecycle.isAuthenticated"))
    let resume = try #require(recovery.range(of: "try await previousState.resumeAfterInterruptedAccountSwitch(using: client)"))
    #expect(restoration.lowerBound < normalServiceGuard.lowerBound)
    #expect(normalServiceGuard.lowerBound < resume.lowerBound)
    // Updating the retained client reconstructs Full's MLS graph. Rollback must
    // retain the original graph and reject a different client before publishing it.
    #expect(!recovery.contains("previousState.updateClient("))
    let identity = try #require(recovery.range(of: "previousState.atProtoClient === client"))
    #expect(identity.lowerBound < restoration.lowerBound)
    #expect(identity.lowerBound < resume.lowerBound)

    let reactivationStart = try #require(source.range(of: "func reactivateAccount(appState: AppState) async throws {"))
    let reactivationEnd = try #require(source.range(of: "/// Updates lifecycle state directly", range: reactivationStart.upperBound..<source.endIndex))
    let reactivation = String(source[reactivationStart.lowerBound..<reactivationEnd.lowerBound])
    let active = try #require(reactivation.range(of: "session.active == true"))
    let reopenServices = try #require(reactivation.range(of: "try await appState.resumeAfterInterruptedAccountSwitch(using: client)"))
    let publish = try #require(reactivation.range(of: "setLifecycle(.authenticated(appState))"))
    let initialize = try #require(reactivation.range(of: "await appState.initialize()"))
    #expect(active.lowerBound < reopenServices.lowerBound)
    #expect(reopenServices.lowerBound < publish.lowerBound)
    #expect(publish.lowerBound < initialize.lowerBound)
    #expect(reactivation.contains("accountSwitchOperationBarrier.begin()"))
    #expect(reactivation.contains("accountSwitchOperationBarrier.end()"))
    #expect(reactivation.contains("guard !isLoggingOut, lifecycle.appState === appState"))
  }

  private func accepted(_ admission: ComposerAccountSwitchQueue.Admission) throws
    -> ComposerAccountSwitchQueue.Attempt {
    guard case .accepted(let attempt) = admission else {
      Issue.record("Expected switch admission")
      throw ExpectedAdmission.missing
    }
    return attempt
  }

  private func expectRejected(_ admission: ComposerAccountSwitchQueue.Admission, as outcome: AccountSwitchOutcome) {
    if case .rejected(let actual) = admission { #expect(actual == outcome) }
    else { Issue.record("Expected switch rejection") }
  }

  private enum ExpectedAdmission: Error { case missing }

  private func makeSnapshot(text: String = "Preserved source draft") -> ComposerEditingSnapshot {
    ComposerEditingSnapshot(
      claim: ComposerDraftClaim(sceneID: UUID(), accountDID: alice, token: UUID()),
      revision: 7,
      draft: PostComposerDraft(postText: text, mediaItems: [], videoItem: nil, selectedGif: nil,
        selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [], isThreadMode: false,
        currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil),
      savedDraftID: UUID()
    )
  }
}
