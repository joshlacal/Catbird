@testable import Catbird
import CatbirdMLSCore
import SwiftUI
import XCTest

@MainActor
final class MLSForegroundResumeContractTests: XCTestCase {
    private enum TestError: Error {
        case preparationFailed
    }

    func testForegroundResumeRunsStorageThenManagerThenProjectionAndBackup() async {
        var events: [String] = []

        let result = await MLSForegroundResumeCoordinator.run(
            managerAvailable: true,
            resumeStillCurrent: { true },
            prepareStorage: {
                events.append("prepare")
            },
            resumeManager: {
                events.append("resume")
                return .resumed
            },
            reassertSuspensionAfterStaleResume: {},
            reloadProjection: {
                events.append("projection")
            },
            performBackup: {
                events.append("backup")
            }
        )

        XCTAssertEqual(result, .resumed)
        XCTAssertEqual(events, ["prepare", "resume", "projection", "backup"])
    }

    func testForegroundPreparationFailureLeavesMLSClosedAndShortCircuitsDownstreamWork() async {
        var events: [String] = []

        let result = await MLSForegroundResumeCoordinator.run(
            managerAvailable: true,
            resumeStillCurrent: { true },
            prepareStorage: {
                events.append("prepare")
                throw TestError.preparationFailed
            },
            resumeManager: {
                events.append("resume")
                return .resumed
            },
            reassertSuspensionAfterStaleResume: {},
            reloadProjection: {
                events.append("projection")
            },
            performBackup: {
                events.append("backup")
            }
        )

        XCTAssertEqual(result, .preparationFailed)
        XCTAssertEqual(events, ["prepare"])
    }

    func testFailedManagerResumeSkipsProjectionAndBackup() async {
        var events: [String] = []

        let result = await MLSForegroundResumeCoordinator.run(
            managerAvailable: true,
            resumeStillCurrent: { true },
            prepareStorage: {
                events.append("prepare")
            },
            resumeManager: {
                events.append("resume")
                return .failedStillSuspended
            },
            reassertSuspensionAfterStaleResume: {},
            reloadProjection: {
                events.append("projection")
            },
            performBackup: {
                events.append("backup")
            }
        )

        XCTAssertEqual(result, .failedStillSuspended)
        XCTAssertEqual(events, ["prepare", "resume"])
    }

    func testMissingManagerSkipsAllForegroundMLSWork() async {
        var events: [String] = []

        let result = await MLSForegroundResumeCoordinator.run(
            managerAvailable: false,
            resumeStillCurrent: { true },
            prepareStorage: {
                events.append("prepare")
            },
            resumeManager: {
                events.append("resume")
                return .resumed
            },
            reassertSuspensionAfterStaleResume: {},
            reloadProjection: {
                events.append("projection")
            },
            performBackup: {
                events.append("backup")
            }
        )

        XCTAssertEqual(result, .managerUnavailable)
        XCTAssertEqual(events, [])
    }

    func testBackgroundTaskDefersForEitherGlobalSuspensionGate() {
        XCTAssertFalse(
            MLSBackgroundRefreshManager.shouldDeferForLifecycleSuspension(
                clientSuspended: false,
                coreSuspended: false
            )
        )
        XCTAssertTrue(
            MLSBackgroundRefreshManager.shouldDeferForLifecycleSuspension(
                clientSuspended: true,
                coreSuspended: false
            )
        )
        XCTAssertTrue(
            MLSBackgroundRefreshManager.shouldDeferForLifecycleSuspension(
                clientSuspended: false,
                coreSuspended: true
            )
        )
    }

    func testBackgroundRefreshPreparesBeforeNormalClose() async {
        let state = MLSBackgroundRefreshTerminationState()
        var events: [String] = []

        let outcome = await MLSBackgroundRefreshCloseCoordinator.run(
            state: state,
            suspendManager: {
                events.append("suspend")
                return true
            },
            prepareRustRuntime: {
                events.append("prepare")
                return true
            },
            closePreparedRuntime: {
                events.append("close")
            }
        )

        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(events, ["suspend", "prepare", "close"])
    }

    func testBackgroundRefreshPreparationFailureSkipsNormalClose() async {
        let state = MLSBackgroundRefreshTerminationState()
        var events: [String] = []

        let outcome = await MLSBackgroundRefreshCloseCoordinator.run(
            state: state,
            suspendManager: {
                events.append("suspend")
                return true
            },
            prepareRustRuntime: {
                events.append("prepare")
                return false
            },
            closePreparedRuntime: {
                events.append("close")
            }
        )

        XCTAssertEqual(outcome, .preparationFailed)
        XCTAssertEqual(events, ["suspend", "prepare"])
    }

    func testBackgroundRefreshExpirationSuppressesDeferredNormalCloseAndCompletion() async {
        let state = MLSBackgroundRefreshTerminationState()
        let preparationStarted = expectation(description: "background preparation started")
        var preparationContinuation: CheckedContinuation<Void, Never>?
        var events: [String] = []

        let closeTask = Task { @MainActor in
            await MLSBackgroundRefreshCloseCoordinator.run(
                state: state,
                suspendManager: {
                    events.append("suspend")
                    return true
                },
                prepareRustRuntime: {
                    events.append("prepare")
                    preparationStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        preparationContinuation = continuation
                    }
                    return true
                },
                closePreparedRuntime: {
                    events.append("normal-close")
                }
            )
        }

        await fulfillment(of: [preparationStarted])
        XCTAssertTrue(state.claimExpiration())
        events.append("forced-close")
        XCTAssertTrue(state.claimGRDBEnd())
        XCTAssertTrue(state.claimTaskCompletion())
        XCTAssertFalse(state.claimExpiration())
        XCTAssertFalse(state.claimGRDBEnd())
        XCTAssertFalse(state.claimTaskCompletion())
        preparationContinuation?.resume()

        let outcome = await closeTask.value
        XCTAssertEqual(outcome, .expired)
        XCTAssertEqual(events, ["suspend", "prepare", "forced-close"])
    }

    func testBackgroundRefreshCompletionSuppressesLateExpiration() {
        let state = MLSBackgroundRefreshTerminationState()

        XCTAssertTrue(state.claimTaskCompletion())
        XCTAssertFalse(state.claimExpiration())
        XCTAssertFalse(state.claimTaskCompletion())
    }

    func testForegroundAndBackgroundSourcesHaveNoRawGateClearBypass() throws {
        let foregroundSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let foregroundBody = try XCTUnwrap(
            functionBody(
                signature: "func resumeMLSAfterReturningToForeground(transitionToken: UInt64) async",
                in: foregroundSource
            )
        )
        XCTAssertFalse(foregroundBody.contains("clearSuspensionFlag"))
        XCTAssertFalse(foregroundBody.contains("resumeFromSuspension"))
        XCTAssertTrue(foregroundBody.contains("resumeMLSOperations"))
        XCTAssertTrue(foregroundBody.contains("reloadMLSProjectionFromDisk"))
        XCTAssertTrue(
            foregroundSource.contains(
                "if (oldPhase == .background || oldPhase == .inactive), newPhase == .active"
            )
        )
        let staleResumeBody = try XCTUnwrap(
            functionBody(signature: "reassertSuspensionAfterStaleResume:", in: foregroundBody)
        )
        XCTAssertTrue(staleResumeBody.contains("MLSClient.interruptAllContexts()"))
        XCTAssertTrue(staleResumeBody.contains("MLSCoreContext.interruptAllContexts()"))
        XCTAssertFalse(staleResumeBody.contains("suspendMLSOperations"))
        XCTAssertFalse(staleResumeBody.contains("emergencyCloseAllContexts"))
        XCTAssertFalse(staleResumeBody.contains("markRustRuntimeClosedForSuspend"))

        let backgroundSource = try source(
            relativePath: "Catbird/Services/MLS/MLSBackgroundRefreshManager.swift"
        )
        let backgroundBody = try XCTUnwrap(
            functionBody(signature: "private func handleBackgroundRefresh(task: BGProcessingTask) async", in: backgroundSource)
        )
        XCTAssertFalse(backgroundBody.contains("clearSuspensionFlag"))
        XCTAssertFalse(backgroundBody.contains("resumeMLSOperations"))
        XCTAssertTrue(backgroundBody.contains("shouldDeferForLifecycleSuspension"))
        XCTAssertTrue(backgroundBody.contains("setTaskCompleted(success: false)"))
        XCTAssertTrue(backgroundBody.contains("manager.suspendMLSOperations()"))
        XCTAssertTrue(backgroundBody.contains("manager.prepareRustRuntimeForSuspensionAfterDrain(timeout: 5)"))

        let backgroundCloseBody = try XCTUnwrap(
            functionBody(signature: "closePreparedRuntime:", in: backgroundBody)
        )
        let clientClose = try XCTUnwrap(
            backgroundCloseBody.range(of: "MLSClient.emergencyCloseAllContexts(")
        )
        let runtimeMark = try XCTUnwrap(
            backgroundCloseBody.range(of: "manager.markRustRuntimeClosedForSuspend(")
        )
        XCTAssertLessThan(clientClose.lowerBound, runtimeMark.lowerBound)
        XCTAssertFalse(backgroundCloseBody.contains("MLSCoreContext.emergencyCloseAllContexts()"))
        XCTAssertFalse(backgroundCloseBody.contains("await"))

        let expirationBody = try XCTUnwrap(
            functionBody(signature: "let expire: @Sendable () -> Void", in: backgroundBody)
        )
        XCTAssertTrue(expirationBody.contains("terminationState.claimExpiration()"))
        XCTAssertTrue(expirationBody.contains("MLSClient.emergencyCloseAllContexts("))
        XCTAssertTrue(expirationBody.contains("markBackgroundRefreshRustRuntimeClosedSynchronously("))
        XCTAssertTrue(expirationBody.contains("terminationState.claimTaskCompletion()"))
    }

    func testAppStateSeparatesAuthoritativeReloadFromProjectionReload() throws {
        let appStateSource = try source(relativePath: "Catbird/Core/State/AppState.swift")
        let authoritativeBody = try XCTUnwrap(
            functionBody(signature: "func reloadMLSStateFromDisk() async", in: appStateSource)
        )
        let projectionBody = try XCTUnwrap(
            functionBody(signature: "func reloadMLSProjectionFromDisk() async", in: appStateSource)
        )

        XCTAssertTrue(authoritativeBody.contains("manager.reloadStateFromDisk"))
        XCTAssertTrue(authoritativeBody.contains("reloadMLSProjectionFromDisk"))
        XCTAssertFalse(projectionBody.contains("manager.reloadStateFromDisk"))
        XCTAssertTrue(projectionBody.contains("loadMLSConversations"))
    }

    func testSuspensionClosePreparesBeforeClosingRuntime() async {
        var events: [String] = []

        let outcome = await MLSSuspensionCloseCoordinator.run(
            rustPathAvailable: true,
            transitionStillCurrent: { true },
            prepareRustRuntime: {
                events.append("prepare")
                return true
            },
            closePreparedRuntime: {
                events.append("close")
            }
        )

        XCTAssertEqual(outcome, .closed)
        XCTAssertEqual(events, ["prepare", "close"])
    }

    func testSuspensionPreparationFailureSkipsNormalClose() async {
        var events: [String] = []

        let outcome = await MLSSuspensionCloseCoordinator.run(
            rustPathAvailable: true,
            transitionStillCurrent: { true },
            prepareRustRuntime: {
                events.append("prepare")
                return false
            },
            closePreparedRuntime: {
                events.append("close")
            }
        )

        XCTAssertEqual(outcome, .preparationFailed)
        XCTAssertEqual(events, ["prepare"])
    }

    func testUnavailableRustPathSkipsPreparationAndNormalClose() async {
        var events: [String] = []

        let outcome = await MLSSuspensionCloseCoordinator.run(
            rustPathAvailable: false,
            transitionStillCurrent: { true },
            prepareRustRuntime: {
                events.append("prepare")
                return true
            },
            closePreparedRuntime: {
                events.append("close")
            }
        )

        XCTAssertEqual(outcome, .rustPathUnavailable)
        XCTAssertEqual(events, [])
    }

    func testNewerForegroundDuringPreparationCannotClosePreparedRuntime() async {
        var transitionCurrent = true
        var preparationContinuation: CheckedContinuation<Void, Never>?
        let preparationStarted = expectation(description: "Rust suspension preparation started")
        var events: [String] = []

        let closeTask = Task { @MainActor in
            await MLSSuspensionCloseCoordinator.run(
                rustPathAvailable: true,
                transitionStillCurrent: { transitionCurrent },
                prepareRustRuntime: {
                    events.append("prepare")
                    preparationStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        preparationContinuation = continuation
                    }
                    return true
                },
                closePreparedRuntime: {
                    events.append("close")
                }
            )
        }

        await fulfillment(of: [preparationStarted])
        transitionCurrent = false
        preparationContinuation?.resume()

        let outcome = await closeTask.value
        XCTAssertEqual(outcome, .staleTransition)
        XCTAssertEqual(events, ["prepare"])
    }

    func testSceneSuspensionCapturesRustAvailabilityBeforeGRDBAndClosesOnlyAfterPrepare() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let body = try XCTUnwrap(
            functionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                in: appSource
            )
        )

        let suspendRange = try XCTUnwrap(
            body.range(of: "rustPathAvailable = manager.suspendMLSOperations()")
        )
        let grdbRange = try XCTUnwrap(
            body.range(of: "GRDBSuspensionCoordinator.setLifecycleSuspended(")
        )
        XCTAssertLessThan(suspendRange.lowerBound, grdbRange.lowerBound)
        XCTAssertTrue(body.contains("manager.prepareRustRuntimeForSuspensionAfterDrain(timeout: 5)"))

        let closeBody = try XCTUnwrap(
            functionBody(signature: "closePreparedRuntime:", in: body)
        )
        let clientClose = try XCTUnwrap(closeBody.range(of: "MLSClient.emergencyCloseAllContexts("))
        let runtimeMark = try XCTUnwrap(closeBody.range(of: "manager.markRustRuntimeClosedForSuspend("))
        XCTAssertLessThan(clientClose.lowerBound, runtimeMark.lowerBound)
        XCTAssertFalse(closeBody.contains("MLSCoreContext.emergencyCloseAllContexts()"))
        XCTAssertFalse(closeBody.contains("await"))
        XCTAssertTrue(
            body.contains(
                "if newPhase == .inactive || newPhase == .background {\n" +
                    "        // WAL health snapshot BEFORE suspension"
            )
        )
        XCTAssertFalse(
            body.contains(
                "if oldPhase == .active, newPhase == .inactive || newPhase == .background"
            )
        )
    }

    func testScenePhaseHandlerDeclaresMainActorIsolation() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")

        XCTAssertTrue(
            appSource.contains(
                "  @MainActor\n" +
                    "  func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)"
            )
        )
    }

    func testSuspensionExpirationPathsUseSharedOneShotCloseClaim() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let body = try XCTUnwrap(
            functionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                in: appSource
            )
        )
        let sceneExpiration = try XCTUnwrap(
            functionBody(signature: "beginBackgroundTask(withName: \"ScenePhaseTransition\")", in: body)
        )
        let closeExpiration = try XCTUnwrap(
            functionBody(signature: "CatbirdBackgroundTask(name: \"MLSSuspensionClose\")", in: body)
        )

        for expirationBody in [sceneExpiration, closeExpiration] {
            XCTAssertTrue(expirationBody.contains("forceCloseSceneSuspensionSynchronously("))
            XCTAssertFalse(expirationBody.contains("MLSClient.emergencyCloseAllContexts("))
            XCTAssertFalse(expirationBody.contains("MLSCoreContext.emergencyCloseAllContexts()"))
            XCTAssertFalse(expirationBody.contains("markRustRuntimeClosedForSuspend("))
        }
    }

    func testContextFreeExpirationPreservesExactOwnerForForegroundResume() async {
        let owner = MLSContextFreeLifecycleSuspensionOwner()
        owner.markSuspensionInProgress(reason: "manager-free background")

        XCTAssertTrue(
            owner.emergencyCloseAllContextsIfOwned(reason: "manager-free expiration")
        )
        XCTAssertTrue(MLSClient.isSuspensionInProgress)
        XCTAssertTrue(MLSCoreContext.isSuspensionInProgress)

        let resumed = await owner.resumeSuspensionIfOwnedAndContextFree()
        XCTAssertTrue(resumed)
        XCTAssertFalse(MLSClient.isSuspensionInProgress)
        XCTAssertFalse(MLSCoreContext.isSuspensionInProgress)
    }

    func testRotatedContextFreeOwnerCannotCloseOrReleaseSuccessor() async {
        let staleOwner = MLSContextFreeLifecycleSuspensionOwner()
        staleOwner.markSuspensionInProgress(reason: "older background")

        let currentOwner = MLSContextFreeLifecycleSuspensionOwner()
        currentOwner.markSuspensionInProgress(reason: "newer background")

        XCTAssertFalse(
            staleOwner.emergencyCloseAllContextsIfOwned(reason: "stale expiration")
        )
        let staleReleased = await staleOwner.resumeSuspensionIfOwnedAndContextFree()
        XCTAssertFalse(staleReleased)
        XCTAssertTrue(MLSClient.isSuspensionInProgress)
        XCTAssertTrue(MLSCoreContext.isSuspensionInProgress)

        XCTAssertTrue(
            currentOwner.emergencyCloseAllContextsIfOwned(reason: "current expiration")
        )
        let currentReleased = await currentOwner.resumeSuspensionIfOwnedAndContextFree()
        XCTAssertTrue(currentReleased)
        XCTAssertFalse(MLSClient.isSuspensionInProgress)
        XCTAssertFalse(MLSCoreContext.isSuspensionInProgress)
    }

    func testSceneTransitionCapturesContextFreeOwnerBeforeExpirationClosures() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let sceneHandler = try XCTUnwrap(
            functionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                in: appSource
            )
        )
        let ownerCapture = try XCTUnwrap(
            sceneHandler.range(
                of: "contextFreeSuspensionOwner = "
                    + "appStateManager.contextFreeMLSSuspensionOwner"
            )
        )
        let firstExpiration = try XCTUnwrap(
            sceneHandler.range(of: "beginBackgroundTask(withName: \"ScenePhaseTransition\")")
        )
        let asynchronousLifecycleTask = try XCTUnwrap(
            sceneHandler.range(of: "Task { @MainActor in")
        )

        XCTAssertLessThan(ownerCapture.lowerBound, firstExpiration.lowerBound)
        XCTAssertLessThan(ownerCapture.lowerBound, asynchronousLifecycleTask.lowerBound)

        let forceClose = try XCTUnwrap(
            functionBody(signature: "func forceCloseSceneSuspensionSynchronously(", in: appSource)
        )
        let managerClose = try XCTUnwrap(
            functionBody(signature: "if let manager", in: forceClose)
        )
        let contextFreeStart = try XCTUnwrap(
            forceClose.range(of: "} else {\n      guard")
        )
        let sceneCloseMark = try XCTUnwrap(
            forceClose.range(
                of: "MLSForegroundResumeCoordinator.markRustRuntimeClosedForSuspension("
            )
        )
        let contextFreeClose = String(
            forceClose[contextFreeStart.upperBound ..< sceneCloseMark.lowerBound]
        )
        XCTAssertTrue(managerClose.contains("MLSClient.interruptAllContexts()"))
        XCTAssertTrue(managerClose.contains("MLSCoreContext.interruptAllContexts()"))
        XCTAssertTrue(managerClose.contains("MLSClient.emergencyCloseAllContexts("))
        XCTAssertTrue(contextFreeClose.contains("contextFreeSuspensionOwner"))
        XCTAssertTrue(contextFreeClose.contains(".emergencyCloseAllContextsIfOwned("))
        XCTAssertFalse(contextFreeClose.contains("interruptAllContexts"))
        XCTAssertFalse(contextFreeClose.contains("MLSClient.emergencyCloseAllContexts("))
    }

    func testSceneExpirationHandlersRaceForExactlyOneCloseAndMark() {
        let transitionToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        let closeClaim = MLSSceneSuspensionCloseClaim(
            transitionToken: transitionToken,
            expectedPhase: .background
        )
        var closeCount = 0
        var markCount = 0

        for _ in 0..<2 where closeClaim.claimExpirationIfCurrent() {
            closeCount += 1
            markCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(markCount, 1)
    }

    func testStaleSceneExpirationCannotCloseNewerForegroundRuntime() {
        let transitionToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        let closeClaim = MLSSceneSuspensionCloseClaim(
            transitionToken: transitionToken,
            expectedPhase: .background
        )
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)

        XCTAssertFalse(closeClaim.claimExpirationIfCurrent())
    }

    func testNormalSceneCloseSuppressesLateExpirationCloseAndMark() {
        let transitionToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
        let closeClaim = MLSSceneSuspensionCloseClaim(
            transitionToken: transitionToken,
            expectedPhase: .inactive
        )
        var closeCount = 0
        var markCount = 0

        if closeClaim.claimNormalCloseIfCurrent() {
            closeCount += 1
            markCount += 1
        }
        if closeClaim.claimExpirationIfCurrent() {
            closeCount += 1
            markCount += 1
        }

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(markCount, 1)
    }

    func testBackgroundBeforeFirstChatUsesOwnedContextFreeSuspensionLifecycle() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let appStateManagerSource = try source(
            relativePath: "Catbird/Core/State/AppStateManager.swift"
        )
        let sceneHandler = try XCTUnwrap(
            functionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                in: appSource
            )
        )
        let foregroundResume = try XCTUnwrap(
            functionBody(
                signature: "private func resumeMLSAfterReturningToForeground(transitionToken: UInt64) async",
                in: appSource
            )
        )

        XCTAssertTrue(
            appStateManagerSource.contains(
                "var contextFreeMLSSuspensionOwner = "
                    + "MLSContextFreeLifecycleSuspensionOwner()"
            )
        )
        XCTAssertTrue(
            appStateManagerSource.contains("func beginContextFreeMLSSuspension(")
        )
        XCTAssertFalse(
            appSource.contains(
                "private let contextFreeMLSSuspensionOwner = "
                    + "MLSContextFreeLifecycleSuspensionOwner()"
            )
        )
        XCTAssertTrue(
            sceneHandler.contains(
                "appStateManager.beginContextFreeMLSSuspension("
            )
        )
        XCTAssertTrue(
            foregroundResume.contains(
                "appStateManager.contextFreeMLSSuspensionOwner"
            )
        )
        XCTAssertTrue(foregroundResume.contains(".resumeSuspensionIfOwnedAndContextFree()"))
        XCTAssertTrue(
            foregroundResume.contains(
                "MLSForegroundResumeCoordinator."
                    + "isCurrentActiveTransition(transitionToken)"
            )
        )
        XCTAssertFalse(foregroundResume.contains("MLSClient.clearSuspension"))
        XCTAssertFalse(foregroundResume.contains("MLSCoreContext.clearSuspensionFlag"))
    }

    func testCurrentContextFreeResumeReleasesExactlyOnce() async {
        var releaseCount = 0

        let outcome = await MLSForegroundResumeCoordinator.runContextFree(
            resumeStillCurrent: { true },
            releaseOwnedSuspension: {
                releaseCount += 1
                return true
            }
        )

        XCTAssertEqual(outcome, .resumed)
        XCTAssertEqual(releaseCount, 1)
    }

    func testStaleContextFreeResumeDoesNotInvokeOwnerRelease() async {
        var releaseCount = 0

        let outcome = await MLSForegroundResumeCoordinator.runContextFree(
            resumeStillCurrent: { false },
            releaseOwnedSuspension: {
                releaseCount += 1
                return true
            }
        )

        XCTAssertEqual(outcome, .staleTransition)
        XCTAssertEqual(releaseCount, 0)
    }

    func testNewerBackgroundDuringContextFreeReleaseKeepsAdmissionClosed() async {
        let foregroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(
            to: .active
        )
        let releaseStarted = expectation(description: "context-free release started")
        var releaseContinuation: CheckedContinuation<Void, Never>?
        var releaseCount = 0
        var clientGateClosed = true
        var coreGateClosed = true
        let capturedOwner = UUID()
        var currentOwner = capturedOwner

        let resumeTask = Task { @MainActor in
            await MLSForegroundResumeCoordinator.runContextFree(
                resumeStillCurrent: {
                    MLSForegroundResumeCoordinator.isCurrentActiveTransition(
                        foregroundToken
                    )
                },
                releaseOwnedSuspension: {
                    releaseCount += 1
                    releaseStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        releaseContinuation = continuation
                    }

                    // Models Core's opaque owner check at capability capture.
                    // The superseding transition rotates the owner before this
                    // stale release resumes.
                    guard capturedOwner == currentOwner else {
                        return false
                    }
                    clientGateClosed = false
                    coreGateClosed = false
                    return true
                }
            )
        }

        await fulfillment(of: [releaseStarted])
        let backgroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(
            to: .background
        )
        currentOwner = UUID()
        clientGateClosed = true
        coreGateClosed = true
        releaseContinuation?.resume()

        let outcome = await resumeTask.value
        XCTAssertEqual(outcome, .staleTransition)
        XCTAssertEqual(releaseCount, 1)
        XCTAssertTrue(clientGateClosed)
        XCTAssertTrue(coreGateClosed)
        XCTAssertTrue(
            MLSForegroundResumeCoordinator.isCurrentTransition(
                backgroundToken,
                expectedPhase: .background
            )
        )
    }

    func testRotatedOwnerRejectsStaleReleaseBeforeCoreCapabilityCapture() async {
        let staleForegroundOwner = MLSContextFreeLifecycleSuspensionOwner()
        staleForegroundOwner.markSuspensionInProgress(reason: "older foreground owner")

        // The app-level active precheck has already passed. A newer background
        // transition now rotates the stable store to a distinct opaque owner.
        let newerBackgroundOwner = MLSContextFreeLifecycleSuspensionOwner()
        newerBackgroundOwner.markSuspensionInProgress(reason: "newer background owner")

        let staleReleased =
            await staleForegroundOwner.resumeSuspensionIfOwnedAndContextFree()
        XCTAssertFalse(staleReleased)
        XCTAssertTrue(MLSClient.isSuspensionInProgress)
        XCTAssertTrue(MLSCoreContext.isSuspensionInProgress)

        let newerReleased =
            await newerBackgroundOwner.resumeSuspensionIfOwnedAndContextFree()
        XCTAssertTrue(newerReleased)
        XCTAssertFalse(MLSClient.isSuspensionInProgress)
        XCTAssertFalse(MLSCoreContext.isSuspensionInProgress)
    }

    func testManagerResumePathDoesNotInvokeContextFreeRelease() throws {
        let appSource = try source(relativePath: "Catbird/App/CatbirdApp.swift")
        let foregroundResume = try XCTUnwrap(
            functionBody(
                signature: "private func resumeMLSAfterReturningToForeground("
                    + "transitionToken: UInt64) async",
                in: appSource
            )
        )
        let contextFreeBranch = try XCTUnwrap(
            functionBody(signature: "guard let manager else", in: foregroundResume)
        )
        let capturedOwner = try XCTUnwrap(
            contextFreeBranch.range(
                of: "let contextFreeSuspensionOwner = "
                    + "appStateManager.contextFreeMLSSuspensionOwner"
            )
        )
        let coordinatorCall = try XCTUnwrap(
            contextFreeBranch.range(
                of: "MLSForegroundResumeCoordinator.runContextFree("
            )
        )
        XCTAssertLessThan(capturedOwner.lowerBound, coordinatorCall.lowerBound)
        XCTAssertTrue(
            contextFreeBranch.contains("contextFreeSuspensionOwner")
        )
        XCTAssertTrue(
            contextFreeBranch.contains(".resumeSuspensionIfOwnedAndContextFree()")
        )
        XCTAssertFalse(contextFreeBranch.contains("manager.resumeMLSOperations()"))
        XCTAssertTrue(
            foregroundResume.contains("return await manager.resumeMLSOperations()")
        )
    }

    func testCatbirdConsumersUseOnlyCoupledCoreLifecycleMutators() throws {
        let consumerPaths = [
            "Catbird/App/CatbirdApp.swift",
            "Catbird/Services/MLS/MLSBackgroundRefreshManager.swift",
            "NotificationServiceExtension/NotificationService.swift",
        ]
        let rawCoreMutators = [
            "MLSCoreContext.markSuspensionInProgress()",
            "MLSCoreContext.clearSuspensionFlag()",
            "MLSCoreContext.emergencyCloseAllContexts()",
        ]

        for path in consumerPaths {
            let consumerSource = try source(relativePath: path)
            for rawMutator in rawCoreMutators {
                XCTAssertFalse(
                    consumerSource.contains(rawMutator),
                    "\(path) must not bypass MLSClient with \(rawMutator)"
                )
            }
        }
    }

    private func source(relativePath: String) throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func functionBody(signature: String, in source: String) -> String? {
        guard let signatureRange = source.range(of: signature),
              let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
        else {
            return nil
        }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{":
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace ... cursor])
                }
            default:
                break
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }
}

@MainActor
final class MLSForegroundResumeRaceTests: XCTestCase {
    func testBackgroundSupersedesInactivePreparationAndOwnsSingleClose() async {
        let inactiveToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
        let preparationStarted = expectation(description: "inactive preparation started")
        var preparationContinuation: CheckedContinuation<Void, Never>?
        var closes: [String] = []

        let inactiveClose = Task { @MainActor in
            await MLSSuspensionCloseCoordinator.run(
                rustPathAvailable: true,
                transitionStillCurrent: {
                    MLSForegroundResumeCoordinator.isCurrentTransition(
                        inactiveToken,
                        expectedPhase: .inactive
                    )
                },
                prepareRustRuntime: {
                    preparationStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        preparationContinuation = continuation
                    }
                    return true
                },
                closePreparedRuntime: {
                    closes.append("inactive")
                }
            )
        }

        await fulfillment(of: [preparationStarted])
        let backgroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        let backgroundOutcome = await MLSSuspensionCloseCoordinator.run(
            rustPathAvailable: true,
            transitionStillCurrent: {
                MLSForegroundResumeCoordinator.isCurrentTransition(
                    backgroundToken,
                    expectedPhase: .background
                )
            },
            prepareRustRuntime: { true },
            closePreparedRuntime: {
                closes.append("background")
            }
        )
        preparationContinuation?.resume()
        let inactiveOutcome = await inactiveClose.value

        XCTAssertEqual(backgroundOutcome, .closed)
        XCTAssertEqual(inactiveOutcome, .staleTransition)
        XCTAssertEqual(closes, ["background"])
    }

    func testClosedInactiveRuntimeCanBeReusedByBackgroundButNotForeground() {
        let inactiveToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .inactive)
        XCTAssertTrue(
            MLSForegroundResumeCoordinator.markRustRuntimeClosedForSuspension(
                inactiveToken,
                expectedPhase: .inactive
            )
        )

        let backgroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        XCTAssertTrue(
            MLSForegroundResumeCoordinator.hasClosedRustRuntimeForSuspension(
                backgroundToken,
                expectedPhase: .background
            )
        )

        let foregroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        XCTAssertFalse(
            MLSForegroundResumeCoordinator.hasClosedRustRuntimeForSuspension(
                foregroundToken,
                expectedPhase: .active
            )
        )
    }

    func testStaleSceneTaskStopsAfterFeedStateAwaitBeforeLifecycleEffects() async {
        let transitionToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        var feedContinuation: CheckedContinuation<Void, Never>?
        let feedUpdateStarted = expectation(description: "feed-state update started")
        var events: [String] = []

        let sceneTask = Task { @MainActor in
            feedUpdateStarted.fulfill()
            await withCheckedContinuation { continuation in
                feedContinuation = continuation
            }
            guard MLSForegroundResumeCoordinator.isCurrentTransition(
                transitionToken,
                expectedPhase: .active
            ) else {
                return
            }
            events.append("publish-active")
        }

        await fulfillment(of: [feedUpdateStarted])
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        feedContinuation?.resume()
        await sceneTask.value

        XCTAssertEqual(events, [])
    }

    func testStaleSuspensionTaskStopsAfterDelayBeforePublishingInactive() async {
        let transitionToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        var delayContinuation: CheckedContinuation<Void, Never>?
        let delayStarted = expectation(description: "post-close delay started")
        var events: [String] = []

        let sceneTask = Task { @MainActor in
            guard MLSForegroundResumeCoordinator.isCurrentTransition(
                transitionToken,
                expectedPhase: .background
            ) else {
                return
            }
            events.append("close-runtime")
            delayStarted.fulfill()
            await withCheckedContinuation { continuation in
                delayContinuation = continuation
            }
            guard MLSForegroundResumeCoordinator.isCurrentTransition(
                transitionToken,
                expectedPhase: .background
            ) else {
                return
            }
            events.append("publish-inactive")
        }

        await fulfillment(of: [delayStarted])
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        delayContinuation?.resume()
        await sceneTask.value

        XCTAssertEqual(events, ["close-runtime"])
    }

    func testNewerSuspensionRevokesPausedForegroundResumeBeforeManagerGateRelease() async {
        let foregroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        var preparationContinuation: CheckedContinuation<Void, Never>?
        let preparationStarted = expectation(description: "foreground preparation started")
        var events: [String] = []
        var gatesClosed = true

        let resumeTask = Task { @MainActor in
            await MLSForegroundResumeCoordinator.run(
                managerAvailable: true,
                resumeStillCurrent: {
                    MLSForegroundResumeCoordinator.isCurrentActiveTransition(foregroundToken)
                },
                prepareStorage: {
                    events.append("prepare")
                    preparationStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        preparationContinuation = continuation
                    }
                },
                resumeManager: {
                    events.append("resume")
                    gatesClosed = false
                    return .resumed
                },
                reassertSuspensionAfterStaleResume: {
                    events.append("reassert")
                    gatesClosed = true
                },
                reloadProjection: {
                    events.append("projection")
                },
                performBackup: {
                    events.append("backup")
                }
            )
        }

        await fulfillment(of: [preparationStarted])
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        preparationContinuation?.resume()

        let result = await resumeTask.value
        XCTAssertEqual(result, .staleTransition)
        XCTAssertEqual(events, ["prepare"])
        XCTAssertTrue(gatesClosed)
    }

    func testNewerSuspensionDuringManagerResumeIsReassertedBeforeProjectionAndBackup() async {
        let foregroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        var managerContinuation: CheckedContinuation<Void, Never>?
        let managerResumeStarted = expectation(description: "manager resume started")
        var events: [String] = []
        var gatesClosed = true

        let resumeTask = Task { @MainActor in
            await MLSForegroundResumeCoordinator.run(
                managerAvailable: true,
                resumeStillCurrent: {
                    MLSForegroundResumeCoordinator.isCurrentActiveTransition(foregroundToken)
                },
                prepareStorage: {
                    events.append("prepare")
                },
                resumeManager: {
                    events.append("resume")
                    managerResumeStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        managerContinuation = continuation
                    }
                    gatesClosed = false
                    return .resumed
                },
                reassertSuspensionAfterStaleResume: {
                    events.append("reassert")
                    gatesClosed = true
                },
                reloadProjection: {
                    events.append("projection")
                },
                performBackup: {
                    events.append("backup")
                }
            )
        }

        await fulfillment(of: [managerResumeStarted])
        _ = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        managerContinuation?.resume()

        let result = await resumeTask.value
        XCTAssertEqual(result, .staleTransition)
        XCTAssertEqual(events, ["prepare", "resume", "reassert"])
        XCTAssertTrue(gatesClosed)
    }

    func testProductionOrderedSupersessionCannotReopenNewerSuspensionGates() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Catbird/App/CatbirdApp.swift"),
            encoding: .utf8
        )
        func extractFunctionBody(signature: String, from source: String) -> String? {
            guard let signatureRange = source.range(of: signature),
                  let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
            else {
                return nil
            }

            var depth = 0
            var cursor = openingBrace
            while cursor < source.endIndex {
                switch source[cursor] {
                case "{":
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(source[openingBrace ... cursor])
                    }
                default:
                    break
                }
                cursor = source.index(after: cursor)
            }
            return nil
        }
        let sceneHandler = try XCTUnwrap(
            extractFunctionBody(
                signature: "func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase)",
                from: appSource
            )
        )
        let recordTransition = try XCTUnwrap(
            sceneHandler.range(of: "MLSForegroundResumeCoordinator.recordSceneTransition(to: newPhase)")
        )
        let ownerBoundSuspend = try XCTUnwrap(
            sceneHandler.range(of: "rustPathAvailable = manager.suspendMLSOperations()")
        )
        let contextFreeGateClose = try XCTUnwrap(
            sceneHandler.range(of: "appStateManager.beginContextFreeMLSSuspension(")
        )
        let firstAwaitingTask = try XCTUnwrap(sceneHandler.range(of: "Task { @MainActor in"))
        XCTAssertLessThan(recordTransition.lowerBound, ownerBoundSuspend.lowerBound)
        XCTAssertLessThan(ownerBoundSuspend.lowerBound, firstAwaitingTask.lowerBound)
        XCTAssertLessThan(contextFreeGateClose.lowerBound, firstAwaitingTask.lowerBound)
        XCTAssertFalse(sceneHandler.contains("MLSCoreContext.markSuspensionInProgress()"))

        let foregroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
        var managerContinuation: CheckedContinuation<Void, Never>?
        let managerResumeStarted = expectation(description: "generation-bound manager resume started")
        let capturedResumeGeneration = 1
        var suspensionGeneration = capturedResumeGeneration
        var suspensionOwner = "foreground-manager"
        var clientGateClosed = true
        var coreGateClosed = true
        var staleReassertCount = 0
        var staleCloseCount = 0
        var staleReleaseCount = 0

        let resumeTask = Task { @MainActor in
            await MLSForegroundResumeCoordinator.run(
                managerAvailable: true,
                resumeStillCurrent: {
                    MLSForegroundResumeCoordinator.isCurrentActiveTransition(foregroundToken)
                },
                prepareStorage: {},
                resumeManager: {
                    managerResumeStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        managerContinuation = continuation
                    }

                    // This models Core's exact-generation final release: a newer
                    // suspension revokes the captured resume authority before either
                    // admission gate can be cleared.
                    guard suspensionGeneration == capturedResumeGeneration else {
                        return .failedStillSuspended
                    }
                    clientGateClosed = false
                    coreGateClosed = false
                    staleReleaseCount += 1
                    return .resumed
                },
                reassertSuspensionAfterStaleResume: {
                    staleReassertCount += 1
                },
                reloadProjection: {
                    staleCloseCount += 1
                },
                performBackup: {
                    staleReleaseCount += 1
                }
            )
        }

        await fulfillment(of: [managerResumeStarted])

        // Production performs all four operations synchronously on MainActor
        // before yielding to the lifecycle Task.
        let newerBackgroundToken = MLSForegroundResumeCoordinator.recordSceneTransition(to: .background)
        suspensionGeneration += 1
        suspensionOwner = "newer-background-transition"
        clientGateClosed = true
        coreGateClosed = true
        managerContinuation?.resume()

        let outcome = await resumeTask.value
        let freshFFIAdmissionAllowed = !clientGateClosed && !coreGateClosed

        XCTAssertEqual(outcome, .failedStillSuspended)
        XCTAssertTrue(clientGateClosed)
        XCTAssertTrue(coreGateClosed)
        XCTAssertFalse(freshFFIAdmissionAllowed)
        XCTAssertEqual(suspensionGeneration, 2)
        XCTAssertEqual(suspensionOwner, "newer-background-transition")
        XCTAssertTrue(
            MLSForegroundResumeCoordinator.isCurrentTransition(
                newerBackgroundToken,
                expectedPhase: .background
            )
        )
        XCTAssertEqual(staleReassertCount, 0)
        XCTAssertEqual(staleCloseCount, 0)
        XCTAssertEqual(staleReleaseCount, 0)
    }
}
