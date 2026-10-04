import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Settings account-switch preflight")
struct SettingsAccountSwitchPreflightTests {
  @Test("No draft needs no persistence; provider transactions reject admission")
  func noDraftOrProvider() async {
    let gate = SettingsAccountSwitchPreflight()
    var writes = 0
    let outcome = await gate.resolve(hasPendingChanges: false, isCurrent: { true },
      accountOperationInProgress: { false }, savePending: { writes += 1; return true })
    #expect(outcome == .allowed)
    #expect(writes == 0)
    let busy = await gate.resolve(hasPendingChanges: true, isCurrent: { true },
      accountOperationInProgress: { true }, savePending: { writes += 1; return true })
    #expect(busy == .busy)
    #expect(writes == 0)
  }

  @Test("Failed save blocks switch and a later retry succeeds")
  func saveFailure() async {
    let gate = SettingsAccountSwitchPreflight()
    let failed = await gate.resolve(hasPendingChanges: true, isCurrent: { true },
      accountOperationInProgress: { false }, savePending: { false })
    #expect(failed == .saveFailed)
    #expect(!gate.isRunning)
    let retry = await gate.resolve(hasPendingChanges: true, isCurrent: { true },
      accountOperationInProgress: { false }, savePending: { true })
    #expect(retry == .allowed)
  }

  @Test("Overlapping and stale account returns cannot admit a switch")
  func overlapAndStale() async {
    let gate = SettingsAccountSwitchPreflight()
    var revision = 1
    var reply: CheckedContinuation<Bool, Never>?
    let first = Task { await gate.resolve(hasPendingChanges: true, isCurrent: { revision == 1 },
      accountOperationInProgress: { false }, savePending: {
        await withCheckedContinuation { reply = $0 }
      }) }
    for _ in 0..<1_000 { if reply != nil { break }; await Task.yield() }
    guard let reply else { #expect(Bool(false), "Preflight save did not start"); first.cancel(); return }
    let second = await gate.resolve(hasPendingChanges: true, isCurrent: { true },
      accountOperationInProgress: { false }, savePending: { true })
    #expect(second == .busy)
    revision = 3 // A left for B and returned; same DID does not restore its old context.
    reply.resume(returning: true)
    #expect(await first.value == .accountChanged)
    #expect(!gate.isRunning)
  }

  @Test("Cancellation during save preserves source admission")
  func cancelledSave() async {
    let gate = SettingsAccountSwitchPreflight()
    var reply: CheckedContinuation<Bool, Never>?
    let task = Task { await gate.resolve(hasPendingChanges: true, isCurrent: { true },
      accountOperationInProgress: { false }, savePending: {
        await withCheckedContinuation { reply = $0 }
      }) }
    for _ in 0..<1_000 { if reply != nil { break }; await Task.yield() }
    guard let reply else { #expect(Bool(false), "Preflight save did not start"); task.cancel(); return }
    task.cancel()
    reply.resume(returning: true)
    #expect(await task.value == .cancelled)
    #expect(!gate.isRunning)
  }
}
