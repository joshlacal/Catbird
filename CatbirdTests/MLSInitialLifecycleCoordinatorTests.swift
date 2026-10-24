import Testing
@testable import Catbird
#if os(iOS)
import CatbirdMLSCore
#endif

@MainActor
@Suite("MLS cold launch admission", .serialized)
struct MLSInitialLifecycleCoordinatorTests {
  @Test("A cold background launch blocks MLS before any scene observation")
  func coldBackgroundBlocksAdmissionWithoutSceneChange() {
    let lifecycle = MLSInitialLifecycleCoordinator()
    var mlsAdmissionOpen = true

    lifecycle.prepareForLaunch(applicationIsActive: false) {
      mlsAdmissionOpen = false
    }

    #expect(!mlsAdmissionOpen)
  }

  @Test("App initialization and launch delegate share one initial suspension owner")
  func repeatedLaunchSetupDoesNotRotateOwner() {
    let lifecycle = MLSInitialLifecycleCoordinator()
    var suspensionCount = 0
    lifecycle.prepareForLaunch(applicationIsActive: false) { suspensionCount += 1 }
    lifecycle.prepareForLaunch(applicationIsActive: false) { suspensionCount += 1 }
    #expect(suspensionCount == 1)
  }

  @Test("Becoming inactive before the first scene observation establishes admission gating")
  func nonactiveLaunchUpdateBeforeFirstSceneStillBlocks() {
    let lifecycle = MLSInitialLifecycleCoordinator()
    var suspensionCount = 0
    lifecycle.prepareForLaunch(applicationIsActive: true) { suspensionCount += 1 }
    #expect(suspensionCount == 0)
    lifecycle.prepareForLaunch(applicationIsActive: false) { suspensionCount += 1 }
    #expect(suspensionCount == 1)
  }

  @Test("App struct recreation cannot replace an observed scene's suspension owner")
  func observedScenePreventsBootstrapFromReplacingOwner() {
    let lifecycle = MLSInitialLifecycleCoordinator()
    lifecycle.recordSceneObservation()
    lifecycle.prepareForLaunch(applicationIsActive: false) {
      Issue.record("Launch bootstrap replaced an established scene lifecycle owner")
    }
  }
}

// These use the same process-wide scene state and Core gates as the other app
// lifecycle integration tests, so keep them in that suite's serialization group.
#if os(iOS)
extension MLSSuspensionCloseCoordinatorTests {
  @Test("Cold launch gates both MLS layers and the first active scene releases its exact owner")
  func firstActiveSceneReleasesInitialCoupledSuspension() async {
    let lifecycle = MLSInitialLifecycleCoordinator()
    let owner = MLSContextFreeLifecycleSuspensionOwner()
    lifecycle.prepareForLaunch(applicationIsActive: false) {
      owner.markSuspensionInProgress(reason: "cold-launch admission test")
    }
    #expect(MLSClient.isSuspensionInProgress)
    #expect(MLSCoreContext.isSuspensionInProgress)

    lifecycle.recordSceneObservation()
    let generation = MLSForegroundResumeCoordinator.recordSceneTransition(to: .active)
    let outcome = await MLSForegroundResumeCoordinator.runContextFree(
      resumeStillCurrent: { MLSForegroundResumeCoordinator.isCurrentActiveTransition(generation) },
      releaseOwnedSuspension: { await owner.resumeSuspensionIfOwnedAndContextFree() }
    )

    #expect(outcome == .resumed)
    #expect(!MLSClient.isSuspensionInProgress)
    #expect(!MLSCoreContext.isSuspensionInProgress)
  }

  @Test("A stale cold-launch owner cannot release a later background suspension")
  func staleInitialOwnerCannotReleaseNewSuspension() async {
    let lifecycle = MLSInitialLifecycleCoordinator()
    let initialOwner = MLSContextFreeLifecycleSuspensionOwner()
    lifecycle.prepareForLaunch(applicationIsActive: false) {
      initialOwner.markSuspensionInProgress(reason: "initial-owner test")
    }
    let laterOwner = MLSContextFreeLifecycleSuspensionOwner()
    laterOwner.markSuspensionInProgress(reason: "new background owner test")

    let released = await initialOwner.resumeSuspensionIfOwnedAndContextFree()
    #expect(!released)
    #expect(MLSClient.isSuspensionInProgress)
    #expect(MLSCoreContext.isSuspensionInProgress)

    #expect(await laterOwner.resumeSuspensionIfOwnedAndContextFree())
  }
}
#endif
