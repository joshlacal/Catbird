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
    while response == nil { await Task.yield() }
    current = false
    response?.resume(returning: 7)
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
    while response == nil { await Task.yield() }
    session.invalidate()
    await session.load()
    response?.resume(returning: 2)
    await save?.value
    #expect(session.state == .ready)
    #expect(session.confirmedValue == 1)
    #expect(session.displayedValue == 1)
    #expect(session.retrySave() == nil)
  }
}
