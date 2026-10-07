import Foundation
import Testing
@testable import Catbird

@MainActor
private final class SuspendedMediaPreview {
  var continuation: CheckedContinuation<Int, Never>?

  func read() async -> Int {
    await withCheckedContinuation { continuation = $0 }
  }

  func complete(_ value: Int) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

@MainActor
struct MediaPreviewLoadTests {
  @Test
  func deadlineDoesNotWaitForUncooperativeTransfer() async throws {
    let attempt = MediaPreviewLoadAttempt(timeout: .milliseconds(30))
    let transfer = SuspendedMediaPreview()
    do {
      _ = try await attempt.value { await transfer.read() }
      Issue.record("A suspended transfer must time out")
    } catch MediaPreviewLoadError.timedOut {
      #expect(transfer.continuation != nil)
    }
    // Late callbacks remain safe after the wait has already completed.
    transfer.complete(1)
  }

  @Test
  func replacementCannotBeClearedByOldFinalizerOrCallback() async throws {
    let registry = MediaPreviewLoadRegistry()
    let id = UUID()
    let old = registry.begin(for: id)
    let transfer = SuspendedMediaPreview()
    let task = Task { @MainActor in
      do {
        _ = try await old.value { await transfer.read() }
        return false
      } catch is CancellationError { return true }
      catch { return false }
    }
    while transfer.continuation == nil { await Task.yield() }
    let replacement = registry.begin(for: id)
    #expect(await task.value)
    #expect(!registry.finish(old, for: id))
    transfer.complete(1)
    await Task.yield()
    #expect(registry.owns(replacement, for: id))
    #expect(try await replacement.value { 42 } == 42)
    #expect(registry.finish(replacement, for: id))
  }

  @Test
  func callerCancellationDoesNotRequireTransferCompletion() async {
    let attempt = MediaPreviewLoadAttempt(timeout: .seconds(10))
    let transfer = SuspendedMediaPreview()
    let task = Task { @MainActor in
      do {
        _ = try await attempt.value { await transfer.read() }
        return false
      } catch is CancellationError { return true }
      catch { return false }
    }
    while transfer.continuation == nil { await Task.yield() }
    task.cancel()
    #expect(await task.value)
    #expect(transfer.continuation != nil)
    transfer.complete(2)
  }

  @Test
  func completedStageDoesNotResetPreparationDeadline() async throws {
    let attempt = MediaPreviewLoadAttempt(timeout: .milliseconds(30))
    _ = try await attempt.value { 1 }
    try await Task.sleep(for: .milliseconds(50))
    var started = false
    do {
      _ = try await attempt.value { started = true; return 2 }
      Issue.record("Every stage must share the same deadline")
    } catch MediaPreviewLoadError.timedOut {
      #expect(!started)
    }
  }

  @Test
  func removingOneAttachmentDoesNotCancelAnother() async {
    let registry = MediaPreviewLoadRegistry()
    let firstID = UUID()
    let secondID = UUID()
    let first = registry.begin(for: firstID)
    let second = registry.begin(for: secondID)
    registry.cancel(for: firstID)
    #expect(!registry.owns(first, for: firstID))
    #expect(registry.owns(second, for: secondID))
    #expect(!registry.finish(first, for: firstID))
    #expect(registry.finish(second, for: secondID))
  }
}
