import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Catbird

/// Holds every lookup until its test releases it, even after cancellation. This deliberately
/// models an uncooperative OS callback so generation fences, rather than timing, are exercised.
actor AgeAccessControlledChecker: AgeRegulatoryChecking {
    private(set) var callCount = 0
    private(set) var nativePromptCount = 0
    private var pending: [Int: CheckedContinuation<PlatformAgeSignal, Never>] = [:]
    private var entered: [(Int, CheckedContinuation<Void, Never>)] = []

    func preflight() async -> PlatformAgeSignal {
        await withCheckedContinuation { continuation in
            callCount += 1
            pending[callCount] = continuation
            let ready = entered.filter { $0.0 <= callCount }
            entered.removeAll { $0.0 <= callCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { entered.append((count, $0)) }
    }

    func resolve(_ call: Int, with signal: PlatformAgeSignal) {
        guard let continuation = pending.removeValue(forKey: call) else {
            Issue.record("No pending synthetic preflight for call \(call)")
            return
        }
        continuation.resume(returning: signal)
    }

    #if canImport(UIKit)
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? {
        await recordUnexpectedNativePrompt()
        throw AgeAccessSyntheticError.unexpectedNativePrompt
    }

    private func recordUnexpectedNativePrompt() { nativePromptCount += 1 }
    #endif
}

enum AgeAccessSyntheticError: Error { case declined, unexpectedNativePrompt }

@MainActor
private final class AgeAccessCheckpoint {
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func mark() {
        reached = true
        let ready = waiters
        waiters.removeAll()
        for waiter in ready { waiter.resume() }
    }
    func wait() async {
        if reached { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Returns only after the joining task has entered refreshRequirements. There is no suspension
/// between the marker and that call, so an existing AppState startup lookup is joined reliably.
@MainActor
func ageAccessJoinedRefresh(_ access: PlatformAgeAccess) async -> Task<Void, Never> {
    let checkpoint = AgeAccessCheckpoint()
    let task = Task { @MainActor in
        checkpoint.mark()
        await access.refreshRequirements()
    }
    await checkpoint.wait()
    return task
}

@MainActor
private final class AgeAccessPrompt {
    private(set) var calls = 0
    private let checkpoint = AgeAccessCheckpoint()
    private var pending: CheckedContinuation<AgeBand?, Error>?

    func request() async throws -> AgeBand? {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            checkpoint.mark()
        }
    }
    func waitUntilPresented() async { await checkpoint.wait() }
    func resolve(_ result: Result<AgeBand?, Error>) {
        guard let continuation = pending else {
            Issue.record("No pending synthetic age prompt")
            return
        }
        pending = nil
        continuation.resume(with: result)
    }
}

@Suite("PlatformAgeAccessTests", .timeLimit(.minutes(1)))
@MainActor
struct PlatformAgeAccessTests {
    private func finishLookup(
        _ access: PlatformAgeAccess, _ checker: AgeAccessControlledChecker,
        call: Int = 1, signal: PlatformAgeSignal
    ) async {
        let refresh = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(call)
        await checker.resolve(call, with: signal)
        await refresh.value
    }

    private func expectBlocked(_ access: PlatformAgeAccess) {
        let operations: [AgeRestrictedOperation] = [
            .generalContent, .directMessaging, .groupMessaging, .custom("synthetic-write"), .matureContent
        ]
        for operation in operations {
            #expect(!access.allows(operation))
            do {
                try access.require(operation)
                Issue.record("Covered operation unexpectedly allowed: \(operation)")
            } catch {
                #expect(error as? PlatformAgeAccess.AccessError == .restricted(operation))
            }
        }
        #expect(access.restrictsMatureContent)
        #expect(access.signal.ageBand == nil)
    }

    @Test("Passive lookup blocks covered use until no-requirement completion, with no prompt")
    func noRequirementDoesNotPrompt() async throws {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        access.startPreflight()
        let joined = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(1)
        #expect(access.isCheckingRequirement)
        expectBlocked(access)
        var prompts = 0
        await access.request(using: { prompts += 1; return .adult }, isCurrent: { true })
        await checker.resolve(1, with: .none)
        await joined.value
        await access.request(using: { prompts += 1; return .adult }, isCurrent: { true })
        #expect(prompts == 0)
        #expect(await checker.callCount == 1)
        #expect(await checker.nativePromptCount == 0)
        #expect(!access.isCheckingRequirement)
        #expect(!access.requiresCheck)
        #expect(!access.restrictsMatureContent)
        #expect(access.signal == .none)
        try access.require(.generalContent)
    }

    @Test("A later passive lookup preserves neutral access until a positive requirement arrives")
    func neutralRefreshPreservesAccessUntilRequirementChanges() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .none)
        #expect(access.allows(.generalContent))
        #expect(!access.restrictsMatureContent)
        let previousRevision = access.revision
        var notifications: [UInt64] = []
        access.decisionDidChange = { notifications.append(access.revision) }
        defer { access.decisionDidChange = nil }

        let refresh = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(2)
        #expect(access.isCheckingRequirement)
        // This is a refresh of a completed neutral decision, not initial admission.
        // No spurious access change should unmount the covered root or a report draft.
        #expect(access.allows(.generalContent))
        #expect(access.allows(.directMessaging))
        #expect(access.allows(.matureContent))
        #expect(!access.restrictsMatureContent)
        #expect(!access.requiresCheck)
        #expect(access.revision == previousRevision)
        #expect(notifications.isEmpty)

        await checker.resolve(2, with: .init(requirement: .ageCheckRequired))
        await refresh.value
        #expect(!access.isCheckingRequirement)
        #expect(access.requiresCheck)
        expectBlocked(access)
        #expect(access.revision > previousRevision)
        #expect(notifications == [access.revision])
        #expect(await checker.nativePromptCount == 0)
    }

    @Test("Affirmative requirement obtains a decision before a covered action")
    func promptBeforeCoveredUse() async throws {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        expectBlocked(access)
        #expect(access.requiresCheck)
        let prompt = AgeAccessPrompt()
        var performed = 0
        let request = Task { @MainActor in
            await access.request(using: { try await prompt.request() }, isCurrent: { true })
            if access.allows(.generalContent) {
                do {
                    try access.require(.generalContent)
                    performed += 1
                } catch {
                    Issue.record("An allowed covered operation unexpectedly failed its guard")
                }
            }
        }
        await prompt.waitUntilPresented()
        #expect(access.isRequesting)
        #expect(performed == 0)
        expectBlocked(access)
        prompt.resolve(.success(.adult))
        await request.value
        #expect(prompt.calls == 1)
        #expect(performed == 1)
        #expect(!access.isRequesting)
        #expect(!access.requiresCheck)
        #expect(access.allows(.generalContent))
        #expect(!access.restrictsMatureContent)
        #expect(access.signal.requirement == .ageCheckRequired)
        #expect(access.signal.ageBand == nil)
    }

    @Test("Missing, invalid, under-13 and threshold-straddling prompt evidence stays restricted",
          arguments: [nil, AgeBand(), AgeBand.under13,
                      AgeBand(lowerBound: -1, upperBound: 18),
                      AgeBand(lowerBound: 18, upperBound: 12),
                      AgeBand(lowerBound: 12, upperBound: 17),
                      AgeBand(lowerBound: nil, upperBound: 17),
                      AgeBand(lowerBound: 13, upperBound: -1)] as [AgeBand?])
    func insufficientPromptEvidence(_ band: AgeBand?) async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired, ageBand: band))
        expectBlocked(access)
        var prompts = 0
        await access.request(using: { prompts += 1; return band }, isCurrent: { true })
        #expect(prompts == 1)
        #expect(!access.isRequesting)
        #expect(access.requiresCheck)
        expectBlocked(access)
    }

    @Test("A thrown prompt error remains retryable and never retains an age response")
    func promptFailureCanRetry() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        var prompts = 0
        await access.request(using: { prompts += 1; throw AgeAccessSyntheticError.declined }, isCurrent: { true })
        expectBlocked(access)
        #expect(!access.isRequesting)
        await access.request(using: { prompts += 1; return .teen }, isCurrent: { true })
        #expect(prompts == 2)
        #expect(access.allows(.generalContent))
        #expect(access.allows(.directMessaging))
        #expect(!access.requiresCheck)
        #expect(access.restrictsMatureContent)
        #expect(!access.allows(.matureContent))
        #expect(access.signal.ageBand == nil)
    }

    @Test("Synthetic preflight bands become decisions without retaining bounds",
          arguments: [AgeBand.under13, .teen, .adult])
    func preflightBandIsConsumedLocally(_ band: AgeBand) async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired, ageBand: band))
        #expect(access.signal.ageBand == nil)
        #expect(access.allows(.generalContent) == !band.isUnder13)
        #expect(access.restrictsMatureContent == !band.isAdult)
        #expect(await checker.nativePromptCount == 0)
    }

    @Test("Unavailable first lookup creates no obligation; unavailable refresh preserves one")
    func unavailableNeverClearsKnownRequirement() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .unavailable))
        #expect(access.allows(.generalContent))
        #expect(!access.requiresCheck)
        #expect(access.signal.requirement == .unavailable)
        await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired, ageBand: .adult))
        #expect(access.allows(.generalContent))
        let requiredRefresh = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(3)
        #expect(access.isCheckingRequirement)
        expectBlocked(access) // An established requirement still clamps while being refreshed.
        await checker.resolve(3, with: .init(requirement: .unavailable))
        await requiredRefresh.value
        #expect(access.signal.requirement == .ageCheckRequired)
        #expect(access.requiresCheck)
        expectBlocked(access)
    }

    @Test("A suspended account discards an uncooperative old preflight after a new decision")
    func stalePreflightCannotReplaceNewDecision() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        let old = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(1)
        access.suspend()
        await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
        let revision = access.revision
        await checker.resolve(1, with: .init(requirement: .none, ageBand: .adult))
        await old.value
        #expect(access.revision == revision)
        #expect(access.signal.requirement == .ageCheckRequired)
        expectBlocked(access)
    }

    @Test("An old deny cannot replace a resumed account's completed allow")
    func staleDenyCannotReplaceNewAllow() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        let old = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(1)
        access.suspend()
        access.resume()
        await finishLookup(access, checker, call: 2, signal: .none)
        let revision = access.revision
        await checker.resolve(1, with: .init(requirement: .ageCheckRequired, ageBand: .under13))
        await old.value
        #expect(access.revision == revision)
        #expect(access.signal == .none)
        #expect(access.allows(.generalContent))
    }

    @Test("Account suspension invalidates success and foreground retry requires a new decision")
    func suspensionRequiresFreshDecision() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired, ageBand: .adult))
        #expect(access.allows(.generalContent))
        access.suspend()
        #expect(access.requiresCheck)
        expectBlocked(access)
        var prompts = 0
        await access.request(using: { prompts += 1; return .adult }, isCurrent: { true })
        #expect(prompts == 0)
        access.retry()
        let joined = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(2)
        expectBlocked(access)
        await checker.resolve(2, with: .init(requirement: .ageCheckRequired))
        await joined.value
        expectBlocked(access)
        await access.request(using: { prompts += 1; return .teen }, isCurrent: { true })
        #expect(prompts == 1)
        #expect(access.allows(.generalContent))
        #expect(access.restrictsMatureContent)
    }

    @Test("A suspended account with no age obligation still rejects covered use until resumed")
    func suspensionAlsoClosesNoRequirementAccount() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .none)
        #expect(access.allows(.generalContent))
        access.suspend()
        #expect(!access.requiresCheck)
        expectBlocked(access)
        access.resume()
        let joined = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(2)
        expectBlocked(access)
        await checker.resolve(2, with: .none)
        await joined.value
        #expect(access.allows(.generalContent))
        #expect(!access.restrictsMatureContent)
    }

    @Test("A dismissed scene's late response cannot grant access")
    func staleScenePromptIsDiscarded() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        let prompt = AgeAccessPrompt()
        var current = true
        let request = Task { @MainActor in
            await access.request(using: { try await prompt.request() }, isCurrent: { current })
        }
        await prompt.waitUntilPresented()
        current = false
        let revision = access.revision
        prompt.resolve(.success(.adult))
        await request.value
        #expect(access.revision == revision)
        #expect(!access.isRequesting)
        expectBlocked(access)
    }

    @Test("Account A's late prompt cannot change account B or reopen A after suspension")
    func accountSwitchFencesPrompt() async {
        let checkerA = AgeAccessControlledChecker()
        let accountA = PlatformAgeAccess(checker: checkerA)
        await finishLookup(accountA, checkerA, signal: .init(requirement: .ageCheckRequired))
        let prompt = AgeAccessPrompt()
        let request = Task { @MainActor in
            await accountA.request(using: { try await prompt.request() }, isCurrent: { true })
        }
        await prompt.waitUntilPresented()
        accountA.suspend()
        let checkerB = AgeAccessControlledChecker()
        let accountB = PlatformAgeAccess(checker: checkerB)
        await finishLookup(accountB, checkerB, signal: .none)
        let revisionA = accountA.revision
        let revisionB = accountB.revision
        prompt.resolve(.success(.adult))
        await request.value
        #expect(accountA.revision == revisionA)
        #expect(accountB.revision == revisionB)
        #expect(accountB.signal == .none)
        #expect(accountB.allows(.generalContent))
        expectBlocked(accountA)
    }

    @Test("Duplicate windows share passive lookup and do not replace the active prompt")
    func duplicateWindowsCoalesce() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        access.startPreflight()
        access.startPreflight()
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        #expect(await checker.callCount == 1)
        let prompt = AgeAccessPrompt()
        let first = Task { @MainActor in
            await access.request(using: { try await prompt.request() }, isCurrent: { true })
        }
        await prompt.waitUntilPresented()
        var secondPromptCalls = 0
        await access.request(using: { secondPromptCalls += 1; return .adult }, isCurrent: { true })
        await access.refreshRequirements()
        #expect(await checker.callCount == 1)
        #expect(secondPromptCalls == 0)
        #expect(access.isRequesting)
        prompt.resolve(.success(.teen))
        await first.value
        #expect(prompt.calls == 1)
        #expect(access.allows(.generalContent))
        #expect(access.restrictsMatureContent)
    }

    @Test("Cancelling one passive waiter leaves the shared lookup usable")
    func passiveWaiterCancellationIsLocal() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        let first = await ageAccessJoinedRefresh(access)
        let second = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(1)
        first.cancel()
        await checker.resolve(1, with: .none)
        await first.value
        await second.value
        #expect(await checker.callCount == 1)
        #expect(access.allows(.generalContent))
        #expect(access.signal == .none)
    }

    @Test("Cancelling the originating prompt fences its late success and permits retry")
    func promptCancellationIsFenced() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        #expect(access.claimAutomaticRequest())
        let prompt = AgeAccessPrompt()
        let request = Task { @MainActor in
            await access.request(using: { try await prompt.request() }, isCurrent: { true })
        }
        await prompt.waitUntilPresented()
        request.cancel()
        // A fresh passive lookup can finish while the cancelled OS call ignores cancellation.
        // This advances the generation synchronously and proves the presentation latch survives.
        await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
        #expect(access.isRequesting)
        var retryPrompts = 0
        await access.request(using: { retryPrompts += 1; return .adult }, isCurrent: { true })
        #expect(retryPrompts == 0)
        expectBlocked(access)
        prompt.resolve(.success(.adult))
        await request.value
        #expect(!access.isRequesting)
        #expect(!access.claimAutomaticRequest())
        expectBlocked(access)
        await access.request(using: { retryPrompts += 1; return .teen }, isCurrent: { true })
        #expect(retryPrompts == 1)
        #expect(access.allows(.generalContent))
        #expect(access.signal.ageBand == nil)
    }

    @Test("Suspend and resume preserve the outstanding prompt latch until the old call returns")
    func suspendedPromptCannotOverlapAfterResume() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        let prompt = AgeAccessPrompt()
        let old = Task { @MainActor in
            await access.request(using: { try await prompt.request() }, isCurrent: { true })
        }
        await prompt.waitUntilPresented()
        access.suspend()
        #expect(access.isRequesting)
        expectBlocked(access)
        access.resume()
        await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
        var newPrompts = 0
        await access.request(using: { newPrompts += 1; return .adult }, isCurrent: { true })
        #expect(newPrompts == 0)
        #expect(access.isRequesting)
        let revision = access.revision
        prompt.resolve(.success(.adult))
        await old.value
        #expect(access.revision == revision)
        #expect(!access.isRequesting)
        expectBlocked(access)
        await access.request(using: { newPrompts += 1; return .adult }, isCurrent: { true })
        #expect(newPrompts == 1)
        #expect(access.allows(.generalContent))
        #expect(access.signal.ageBand == nil)
    }

    @Test("One automatic claim is shared across scenes and survives decline, errors and refresh")
    func automaticAttemptIsAccountScoped() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        #expect(!access.claimAutomaticRequest())
        let lookup = await ageAccessJoinedRefresh(access)
        await checker.waitForCalls(1)
        #expect(!access.claimAutomaticRequest())
        await checker.resolve(1, with: .init(requirement: .ageCheckRequired))
        await lookup.value
        let revision = access.revision
        #expect(access.claimAutomaticRequest())
        #expect(!access.claimAutomaticRequest()) // A second or newly attached scene shares the claim.
        #expect(access.revision == revision) // Presentation bookkeeping grants no access.
        await access.request(using: { nil }, isCurrent: { true })
        #expect(!access.claimAutomaticRequest())
        await access.request(using: { throw AgeAccessSyntheticError.declined }, isCurrent: { true })
        #expect(!access.claimAutomaticRequest())
        await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
        #expect(!access.claimAutomaticRequest())
        await finishLookup(access, checker, call: 3, signal: .init(requirement: .unavailable))
        #expect(!access.claimAutomaticRequest())
        expectBlocked(access)
        // Explicit Retry calls request directly; the consumed automatic claim must not block it.
        await access.request(using: { .teen }, isCurrent: { true })
        #expect(access.allows(.generalContent))
        #expect(access.signal.ageBand == nil)
    }

    @Test("A manual-first decline or error consumes the shared automatic attempt", arguments: [false, true])
    func manualFirstAttemptPreventsAnotherSceneAutomaticPrompt(throwsError: Bool) async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
        var prompts = 0
        // Deliberately do not call claimAutomaticRequest: this is the user's first explicit Retry.
        await access.request(using: {
            prompts += 1
            if throwsError { throw AgeAccessSyntheticError.declined }
            return nil
        }, isCurrent: { true })
        #expect(prompts == 1)
        #expect(access.requiresCheck)
        #expect(!access.claimAutomaticRequest()) // Another scene must not repeat the attempt.
        expectBlocked(access)
        await access.request(using: { prompts += 1; return .teen }, isCurrent: { true })
        #expect(prompts == 2) // A consumed automatic claim must not disable explicit Retry.
        #expect(access.allows(.generalContent))
        #expect(access.restrictsMatureContent)
        #expect(access.signal.ageBand == nil)
    }

    @Test("Only a neutral decision, completed ordinary permission or account suspension resets the claim")
    func automaticAttemptResetBoundaries() async {
        for reset in 0..<3 {
            let checker = AgeAccessControlledChecker()
            let access = PlatformAgeAccess(checker: checker)
            await finishLookup(access, checker, signal: .init(requirement: .ageCheckRequired))
            #expect(access.claimAutomaticRequest())
            switch reset {
            case 0:
                await finishLookup(access, checker, call: 2, signal: .none)
                #expect(!access.claimAutomaticRequest()) // No obligation is not an automatic prompt.
                await finishLookup(access, checker, call: 3, signal: .init(requirement: .ageCheckRequired))
            case 1:
                await access.request(using: { .adult }, isCurrent: { true })
                #expect(!access.claimAutomaticRequest())
                await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
            default:
                access.suspend()
                #expect(!access.claimAutomaticRequest()) // A suspended account cannot claim UI.
                access.resume()
                await finishLookup(access, checker, call: 2, signal: .init(requirement: .ageCheckRequired))
            }
            #expect(access.claimAutomaticRequest())
            #expect(!access.claimAutomaticRequest())
            #expect(access.signal.ageBand == nil)
            expectBlocked(access)
        }
    }

    @Test("Effective decision revisions notify observers; informational flag never prompts")
    func revisionAndInformationalFlag() async {
        let checker = AgeAccessControlledChecker()
        let access = PlatformAgeAccess(checker: checker)
        var observed: [UInt64] = []
        access.decisionDidChange = { observed.append(access.revision) }
        defer { access.decisionDidChange = nil }
        access.startPreflight()
        #expect(observed == [1])
        await finishLookup(access, checker, signal: .init(significantChangeConsentRequired: true))
        #expect(observed == [1, 2])
        #expect(access.signal.significantChangeConsentRequired)
        #expect(access.signal.ageBand == nil)
        #expect(access.allows(.generalContent))
        var prompts = 0
        await access.request(using: { prompts += 1; return .adult }, isCurrent: { true })
        #expect(prompts == 0)
        #expect(access.revision == 2)
        #expect(observed == [1, 2])
    }
}
