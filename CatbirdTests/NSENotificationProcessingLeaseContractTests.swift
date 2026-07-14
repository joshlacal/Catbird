@testable import Catbird
import XCTest

@MainActor
final class NSEProcessingLeaseContractTests: XCTestCase {
  func testOverlappingReleasesGiveCleanupOnlyToFinalLease() async {
    let leases = NSENotificationProcessingLeases()
    let first = await leases.acquire(recipientDID: "did:plc:first")
    let second = await leases.acquire(recipientDID: "did:plc:second")

    XCTAssertEqual(leases.release(first), .stillProcessing)
    guard case .performCleanup(let claim) = leases.release(second) else {
      return XCTFail("Final lease did not receive cleanup ownership")
    }
    XCTAssertTrue(leases.ordinaryCleanupIsCurrent(claim))

    leases.finishOrdinaryCleanup(claim)
    XCTAssertEqual(leases.release(second), .cleanupAlreadyPerformed)
  }

  func testExpirationSupersedesHeldOrdinaryCleanupExactlyOnce() async {
    let leases = NSENotificationProcessingLeases()
    let lease = await leases.acquire(recipientDID: "did:plc:expiry")
    guard case .performCleanup(let ordinaryClaim) = leases.release(lease) else {
      return XCTFail("Final lease did not receive cleanup ownership")
    }

    XCTAssertTrue(leases.claimExpirationCleanup())
    XCTAssertFalse(leases.claimExpirationCleanup())
    XCTAssertFalse(leases.ordinaryCleanupIsCurrent(ordinaryClaim))
    leases.finishExpirationCleanupIfIdle()
    leases.finishOrdinaryCleanup(ordinaryClaim)

    XCTAssertFalse(leases.claimExpirationCleanup())
  }

  func testExpirationAfterCompletedOrdinaryCleanupDoesNotCloseAgain() async {
    let leases = NSENotificationProcessingLeases()
    let lease = await leases.acquire(recipientDID: "did:plc:complete")
    guard case .performCleanup(let ordinaryClaim) = leases.release(lease) else {
      return XCTFail("Final lease did not receive cleanup ownership")
    }

    leases.finishOrdinaryCleanup(ordinaryClaim)

    XCTAssertFalse(leases.claimExpirationCleanup())
  }

  func testExpirationDefersToOrdinaryCleanupAfterAtomicCloseClaim() async {
    let leases = NSENotificationProcessingLeases()
    let lease = await leases.acquire(recipientDID: "did:plc:closing")
    guard case .performCleanup(let ordinaryClaim) = leases.release(lease) else {
      return XCTFail("Final lease did not receive cleanup ownership")
    }

    XCTAssertTrue(leases.beginOrdinaryClose(ordinaryClaim))
    XCTAssertFalse(leases.claimExpirationCleanup())
    XCTAssertTrue(leases.ordinaryCleanupIsCurrent(ordinaryClaim))
    leases.finishOrdinaryCleanup(ordinaryClaim)
    XCTAssertFalse(leases.claimExpirationCleanup())
  }

  func testAcquisitionWaitsForCleanupThenStartsNextGeneration() async {
    let leases = NSENotificationProcessingLeases()
    let first = await leases.acquire(recipientDID: "did:plc:first")
    guard case .performCleanup(let ordinaryClaim) = leases.release(first) else {
      return XCTFail("Final lease did not receive cleanup ownership")
    }

    var acquisitionFinished = false
    let waitingAcquisition = Task { @MainActor in
      let lease = await leases.acquire(recipientDID: "did:plc:next")
      acquisitionFinished = true
      return lease
    }
    await Task.yield()
    XCTAssertFalse(acquisitionFinished)

    leases.finishOrdinaryCleanup(ordinaryClaim)
    let next = await waitingAcquisition.value

    XCTAssertTrue(acquisitionFinished)
    XCTAssertTrue(next.startsNewGeneration)
  }

  func testAppStopWaitsForActiveLeaseAndBlocksNewAcquisition() async {
    let leases = NSENotificationProcessingLeases()
    let active = await leases.acquire(recipientDID: "did:plc:active")

    var stopFinishedWaiting = false
    let stopRequest = Task { @MainActor in
      let decision = await leases.requestAppStopCleanup()
      stopFinishedWaiting = true
      return decision
    }
    await Task.yield()
    XCTAssertFalse(stopFinishedWaiting)

    var acquisitionFinished = false
    let waitingAcquisition = Task { @MainActor in
      let lease = await leases.acquire(recipientDID: "did:plc:later")
      acquisitionFinished = true
      return lease
    }
    await Task.yield()
    XCTAssertFalse(acquisitionFinished)

    XCTAssertEqual(leases.release(active), .cleanupOwnedElsewhere)
    guard case .performCleanup(let stopClaim) = await stopRequest.value else {
      return XCTFail("App stop did not receive cleanup ownership")
    }
    XCTAssertTrue(stopFinishedWaiting)
    XCTAssertEqual(stopClaim.recipientDIDs, ["did:plc:active"])
    XCTAssertFalse(acquisitionFinished)

    leases.finishAppStopCleanup(stopClaim)
    let later = await waitingAcquisition.value
    XCTAssertTrue(acquisitionFinished)
    XCTAssertTrue(later.startsNewGeneration)
  }

  func testAppStopPreservesDistinctOverlappingRecipients() async {
    let leases = NSENotificationProcessingLeases()
    let first = await leases.acquire(recipientDID: "did:plc:first")
    let second = await leases.acquire(recipientDID: "did:plc:second")
    let stopRequest = Task { @MainActor in
      await leases.requestAppStopCleanup()
    }
    await Task.yield()

    XCTAssertEqual(leases.release(first), .stillProcessing)
    XCTAssertEqual(leases.release(second), .cleanupOwnedElsewhere)
    guard case .performCleanup(let stopClaim) = await stopRequest.value else {
      return XCTFail("App stop did not receive cleanup ownership")
    }

    XCTAssertEqual(stopClaim.recipientDIDs, ["did:plc:first", "did:plc:second"])
    leases.finishAppStopCleanup(stopClaim)
  }

  func testExpirationSupersedesAppStopBeforeCloseBegins() async {
    let leases = NSENotificationProcessingLeases()
    let active = await leases.acquire(recipientDID: "did:plc:active")
    let stopRequest = Task { @MainActor in
      await leases.requestAppStopCleanup()
    }
    await Task.yield()
    XCTAssertEqual(leases.release(active), .cleanupOwnedElsewhere)
    guard case .performCleanup(let stopClaim) = await stopRequest.value else {
      return XCTFail("App stop did not receive cleanup ownership")
    }

    XCTAssertTrue(leases.claimExpirationCleanup())
    XCTAssertFalse(leases.appStopCleanupIsCurrent(stopClaim))
    leases.finishExpirationCleanupIfIdle()
    leases.finishAppStopCleanup(stopClaim)
    XCTAssertFalse(leases.claimExpirationCleanup())
  }

  func testExpirationDefersToAppStopAfterAtomicCloseClaim() async {
    let leases = NSENotificationProcessingLeases()
    let active = await leases.acquire(recipientDID: "did:plc:active")
    let stopRequest = Task { @MainActor in
      await leases.requestAppStopCleanup()
    }
    await Task.yield()
    XCTAssertEqual(leases.release(active), .cleanupOwnedElsewhere)
    guard case .performCleanup(let stopClaim) = await stopRequest.value else {
      return XCTFail("App stop did not receive cleanup ownership")
    }

    XCTAssertTrue(leases.beginAppStopClose(stopClaim))
    XCTAssertFalse(leases.claimExpirationCleanup())
    XCTAssertTrue(leases.appStopCleanupIsCurrent(stopClaim))
    leases.finishAppStopCleanup(stopClaim)
    XCTAssertFalse(leases.claimExpirationCleanup())
  }

  func testOverlappingNotificationTasksReleaseThroughFinalLeaseCleanup() throws {
    let source = try notificationServiceSource()
    let receiveBody = try XCTUnwrap(
      functionBody(signature: "override func didReceive(", in: source)
    )
    let leaseWrapper = try XCTUnwrap(
      functionBody(signature: "private func withNotificationProcessingLease(", in: source)
    )

    XCTAssertEqual(
      receiveBody.components(separatedBy: "withNotificationProcessingLease(").count - 1,
      2,
      "Both the rustFull cache path and Swift MLS decrypt path must hold a process lease"
    )
    XCTAssertTrue(
      leaseWrapper.contains(
        "await Self.notificationProcessingLeases.acquire(recipientDID: recipientDid)"
      )
    )
    XCTAssertTrue(leaseWrapper.contains("await operation()"))
    XCTAssertTrue(leaseWrapper.contains("Self.notificationProcessingLeases.release(lease)"))
    XCTAssertTrue(leaseWrapper.contains("case .stillProcessing"))
    XCTAssertTrue(leaseWrapper.contains("case .performCleanup"))
    XCTAssertTrue(leaseWrapper.contains("await performCoordinatedNSECleanup"))
    XCTAssertFalse(
      receiveBody.contains("quickShutdownForNSE"),
      "A finishing delivery must not close MLS while another delivery still holds a lease"
    )
  }

  func testFinalLeaseOwnsSuspensionClearAndEmergencyClose() throws {
    let source = try notificationServiceSource()
    let receiveBody = try XCTUnwrap(
      functionBody(signature: "override func didReceive(", in: source)
    )
    let cleanupBody = try XCTUnwrap(
      functionBody(signature: "private func bestEffortNSECleanup(", in: source)
    )
    let leaseWrapper = try XCTUnwrap(
      functionBody(signature: "private func withNotificationProcessingLease(", in: source)
    )

    XCTAssertFalse(receiveBody.contains("MLSCoreContext.clearSuspensionFlag()"))
    XCTAssertTrue(leaseWrapper.contains("if lease.startsNewGeneration"))
    XCTAssertTrue(leaseWrapper.contains("MLSClient.clearSuspensionFlag("))
    XCTAssertFalse(leaseWrapper.contains("MLSCoreContext.clearSuspensionFlag()"))
    XCTAssertTrue(cleanupBody.contains("MLSClient.emergencyCloseAllContexts("))
    XCTAssertFalse(cleanupBody.contains("MLSCoreContext.emergencyCloseAllContexts()"))
    XCTAssertTrue(cleanupBody.contains("MLSGRDBManager.emergencyCloseAllDatabases(mode: .passive)"))
    XCTAssertTrue(cleanupBody.contains("MLSClient.clearSuspensionFlag("))
    XCTAssertFalse(cleanupBody.contains("MLSCoreContext.clearSuspensionFlag()"))
  }

  func testNSEUsesOnlyCoupledLifecycleMutators() throws {
    let source = try notificationServiceSource()

    for rawMutator in [
      "MLSCoreContext.markSuspensionInProgress()",
      "MLSCoreContext.clearSuspensionFlag()",
      "MLSCoreContext.emergencyCloseAllContexts()",
    ] {
      XCTAssertFalse(source.contains(rawMutator), "NSE must not call \(rawMutator)")
    }
    XCTAssertTrue(source.contains("MLSClient.clearSuspensionFlag("))
    XCTAssertTrue(source.contains("MLSClient.emergencyCloseAllContexts("))
  }

  func testExpirationClaimsExceptionalCleanupExactlyOnce() throws {
    let source = try notificationServiceSource()
    let expirationBody = try XCTUnwrap(
      functionBody(signature: "override func serviceExtensionTimeWillExpire()", in: source)
    )
    XCTAssertTrue(expirationBody.contains("claimExpirationCleanup()"))
    XCTAssertTrue(expirationBody.contains("if shouldForceCleanup"))
    XCTAssertTrue(expirationBody.contains("activeRecipientDIDs"))
    XCTAssertTrue(expirationBody.contains("MLSClient.emergencyCloseAllContexts("))
    XCTAssertFalse(expirationBody.contains("MLSCoreContext.emergencyCloseAllContexts()"))
    XCTAssertTrue(expirationBody.contains("MLSGRDBManager.emergencyCloseAllDatabases(mode: .passive)"))
  }

  func testAppStopCleanupUsesExclusiveLeaseOwnedRecipientSet() throws {
    let source = try notificationServiceSource()
    let appStopBody = try XCTUnwrap(
      functionBody(signature: "private func handleAppStopNotification()", in: source)
    )

    XCTAssertTrue(appStopBody.contains("requestAppStopCleanup()"))
    XCTAssertTrue(appStopBody.contains("claim.recipientDIDs.sorted()"))
    XCTAssertTrue(appStopBody.contains("finishAppStopCleanup(claim)"))
    XCTAssertFalse(source.contains("private var activeRecipientDID"))
  }

  func testDeinitRemovesDarwinObserverWithoutAssumingMainActorIsolation() throws {
    let source = try notificationServiceSource()
    let deinitBody = try XCTUnwrap(functionBody(signature: "deinit", in: source))

    XCTAssertTrue(deinitBody.contains("CFNotificationCenterGetDarwinNotifyCenter()"))
    XCTAssertTrue(deinitBody.contains("CFNotificationCenterRemoveObserver("))
    XCTAssertTrue(deinitBody.contains("Unmanaged.passUnretained(self).toOpaque()"))
    XCTAssertTrue(deinitBody.contains("CFNotificationName(kMLSNSEStopNotification)"))
    XCTAssertFalse(deinitBody.contains("MainActor.assumeIsolated"))
    XCTAssertFalse(deinitBody.contains("stopObservingAppStop()"))
    XCTAssertFalse(deinitBody.contains("isObservingAppStop"))
  }

  private func notificationServiceSource() throws -> String {
    try String(
      contentsOf: repositoryRoot()
        .appendingPathComponent("NotificationServiceExtension/NotificationService.swift"),
      encoding: .utf8
    )
  }

  private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func functionBody(signature: String, in source: String) -> String? {
    body(after: signature, in: source)
  }

  private func body(after signature: String, in source: String) -> String? {
    guard let signatureRange = source.range(of: signature),
      let openingBrace = source[signatureRange.upperBound...].firstIndex(of: "{")
    else {
      return nil
    }

    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
      switch source[index] {
      case "{":
        depth += 1
      case "}":
        depth -= 1
        if depth == 0 {
          return String(source[source.index(after: openingBrace)..<index])
        }
      default:
        break
      }
      index = source.index(after: index)
    }
    return nil
  }
}
