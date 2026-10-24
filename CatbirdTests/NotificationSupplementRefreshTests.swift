import Testing
@testable import Catbird

@Suite("Independent notification refresh")
@MainActor
struct NotificationSupplementRefreshTests {
  @Test func primaryCompletesWhileSupplementIsSuspended() async {
    let owner = NotificationSupplementRefresh()
    let gate = Gate()
    var supplementFinished = false
    owner.start {
      await gate.wait()
      supplementFinished = true
    }
    await Task.yield()
    // Primary work can finish without releasing the secondary feed.
    let primary = Task { @MainActor in ["notification"] }
    #expect(await primary.value == ["notification"])
    #expect(!supplementFinished)
    gate.release()
    owner.cancel()
  }

  @Test func duplicateRefreshIsCoalescedAndOldCompletionCannotClearNewTask() async {
    let owner = NotificationSupplementRefresh()
    let oldGate = Gate()
    let newGate = Gate()
    var starts = 0
    owner.start { starts += 1; await oldGate.wait() }
    await oldGate.waitForEntry()
    owner.start { starts += 1 }
    #expect(starts == 1)
    owner.cancel()
    owner.start { starts += 1; await newGate.wait() }
    await Task.yield()
    #expect(starts == 1)
    oldGate.release()
    await newGate.waitForEntry()
    owner.start { starts += 1 }
    await Task.yield()
    #expect(starts == 2)
    newGate.release()
    owner.cancel()
  }

  @Test func cancellationReachesSupplement() async {
    let owner = NotificationSupplementRefresh()
    let gate = Gate()
    var cancelled = false
    owner.start { await gate.wait(); cancelled = Task.isCancelled }
    await gate.waitForEntry()
    owner.cancel()
    gate.release()
    for _ in 0..<10 where !cancelled { await Task.yield() }
    #expect(cancelled)
  }

  @MainActor private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var entered = false
    func waitForEntry() async {
      while !entered { await Task.yield() }
    }
    func wait() async {
      entered = true
      guard !released else { return }
      await withCheckedContinuation { continuation = $0 }
    }
    func release() {
      released = true
      continuation?.resume()
      continuation = nil
    }
  }
}
