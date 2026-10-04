import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Account-bound Settings editors")
struct AccountSettingsEditSessionTests {
  private enum Failure: Error { case read, write }

  @Test("Failed initial read never admits a write")
  func failedRead() async {
    var writes = 0
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", isCurrentAccount: { true },
      load: { throw Failure.read },
      save: { value in writes += 1; return value }
    )
    await session.load()
    #expect(session.state == .loadFailed)
    #expect(!session.canEdit)
    #expect(session.submit(2) == nil)
    #expect(session.confirmedValue == nil)
    #expect(writes == 0)
  }

  @Test("Save admission is synchronous and preserves the accepted baseline on failure")
  func saveAndRetry() async {
    var values: [Int] = []
    var fail = true
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", isCurrentAccount: { true }, load: { 1 },
      save: { value in
        values.append(value)
        if fail { throw Failure.write }
        return value
      }
    )
    await session.load()
    let first = session.submit(2)
    #expect(session.state == .saving)
    #expect(session.displayedValue == 2)
    #expect(session.submit(3) == nil)
    await first?.value
    #expect(session.state == .saveFailed)
    #expect(session.displayedValue == 1)
    fail = false
    await session.retrySave()?.value
    #expect(values == [2, 2])
    #expect(session.confirmedValue == 2)
    fail = true
    await session.submit(3)?.value
    #expect(session.confirmedValue == 2)
    #expect(session.displayedValue == 2)
    #expect(session.canEdit)
    let newEdit = session.submit(4)
    #expect(newEdit != nil)
    await newEdit?.value
    #expect(values == [2, 2, 3, 4])
  }

  @Test("An uncertain save blocks new edits but permits only one exact retry")
  func uncertainSaveRequiresRetryOrReload() async {
    var remoteValue = 1
    var writes: [Int] = []
    var failLocalPersistence = true
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", allowEditingAfterSaveFailure: false,
      isCurrentAccount: { true }, load: { remoteValue },
      save: { value in
        writes.append(value)
        remoteValue = value
        if failLocalPersistence { throw Failure.write }
        return value
      }
    )
    await session.load()
    await session.submit(2)?.value
    #expect(remoteValue == 2)
    #expect(session.state == .saveFailed)
    #expect(session.displayedValue == 1)
    #expect(!session.canEdit)
    #expect(session.submit(1) == nil)
    #expect(session.submit(3) == nil)
    #expect(writes == [2])

    failLocalPersistence = false
    let retry = session.retrySave()
    #expect(retry != nil)
    #expect(session.state == .saving)
    #expect(session.retrySave() == nil)
    #expect(session.submit(3) == nil)
    await retry?.value
    #expect(writes == [2, 2])
    #expect(session.confirmedValue == 2)
    #expect(session.canEdit)
  }

  @Test("Reload after an uncertain save accepts the remote value and reenables editing")
  func uncertainSaveReloadsAcceptedRemoteValue() async {
    var remoteValue = 1
    var writes: [Int] = []
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", allowEditingAfterSaveFailure: false,
      isCurrentAccount: { true }, load: { remoteValue },
      save: { value in
        writes.append(value)
        remoteValue = value
        throw Failure.write
      }
    )
    await session.load()
    await session.submit(2)?.value
    #expect(!session.canEdit)
    #expect(session.confirmedValue == 1)
    await session.load()
    #expect(session.state == .ready)
    #expect(session.confirmedValue == 2)
    #expect(session.canEdit)
    #expect(session.retrySave() == nil)
    let newEdit = session.submit(1)
    #expect(newEdit != nil)
    await newEdit?.value
    #expect(writes == [2, 1])
  }

  @Test("Exact retry remains bound to the originating account and cannot survive invalidation")
  func uncertainSaveRetryChecksAccount() async {
    var current = true
    var writes = 0
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", allowEditingAfterSaveFailure: false,
      isCurrentAccount: { current }, load: { 1 },
      save: { _ in writes += 1; throw Failure.write }
    )
    await session.load()
    await session.submit(2)?.value
    current = false
    #expect(session.retrySave() == nil)
    #expect(session.submit(3) == nil)
    #expect(writes == 1)
    session.invalidate()
    current = true
    #expect(session.retrySave() == nil)
    #expect(session.state == .unavailable)
    #expect(writes == 1)
  }

  @Test("Stale read cannot publish to a replacement account")
  func staleRead() async {
    var current = true
    var response: CheckedContinuation<Int, Never>?
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", isCurrentAccount: { current },
      load: { await withCheckedContinuation { response = $0 } },
      save: { $0 }
    )
    let load = Task { await session.load() }
    for _ in 0..<1_000 { if response != nil { break }; await Task.yield() }
    guard let response else { #expect(Bool(false), "Read did not start"); load.cancel(); return }
    current = false
    response.resume(returning: 7)
    await load.value
    #expect(session.confirmedValue == nil)
    #expect(session.state == .unavailable)
    #expect(session.submit(8) == nil)
  }

  @Test("Invalidation rejects late saves even when the original account returns")
  func staleSaveAcrossReturn() async {
    var response: CheckedContinuation<Int, Never>?
    let session = AccountSettingsEditSession<Int>(
      accountDID: "did:test:a", isCurrentAccount: { true }, load: { 1 },
      save: { _ in await withCheckedContinuation { response = $0 } }
    )
    await session.load()
    let save = session.submit(2)
    for _ in 0..<1_000 { if response != nil { break }; await Task.yield() }
    guard let response else { #expect(Bool(false), "Save did not start"); save?.cancel(); return }
    session.invalidate()
    await session.load()
    response.resume(returning: 2)
    await save?.value
    #expect(session.state == .ready)
    #expect(session.confirmedValue == 1)
    #expect(session.displayedValue == 1)
    #expect(session.retrySave() == nil)
  }
}
