import Foundation
import Testing
@testable import Catbird

@MainActor
struct MLSConversationCreationRetryTests {
  enum Failure: Error { case throttled(Double?), other }
  private func hint(_ error: Error) -> Double? {
    if case Failure.throttled(let value) = error { return value }
    return nil
  }

  @Test func waitsThenRetriesWithoutChangingOperation() async throws {
    var attempts = 0
    var waits: [Double] = []
    var progress: [String] = []
    let result = try await MLSConversationCreationRetry.run(
      isCurrent: { true }, retryAfter: hint, onProgress: { progress.append($0) },
      sleep: { waits.append($0) }, operation: {
        attempts += 1
        if attempts == 1 { throw Failure.throttled(2.5) }
        return "same conversation"
      })
    #expect(result == "same conversation")
    #expect(attempts == 2)
    #expect(waits == [1, 1, 0.5])
    #expect(progress.contains(where: { $0.contains("3 seconds") }))
  }

  @Test func nonRateLimitAndInvalidHintsNeverRetry() async {
    for failure in [Failure.other, .throttled(nil), .throttled(0), .throttled(-1),
                    .throttled(.infinity), .throttled(.nan), .throttled(902)] {
      var attempts = 0
      var waits = 0
      do {
        let _: Int = try await MLSConversationCreationRetry.run(
          isCurrent: { true }, retryAfter: hint, onProgress: { _ in },
          sleep: { _ in waits += 1 }, operation: { attempts += 1; throw failure })
        Issue.record("Expected unretryable failure")
      } catch {}
      #expect(attempts == 1)
      #expect(waits == 0)
    }
  }

  @Test func repeatedRateLimitsStopAtThreeAttempts() async {
    var attempts = 0
    var waits = 0
    do {
      let _: Int = try await MLSConversationCreationRetry.run(
        isCurrent: { true }, retryAfter: hint, onProgress: { _ in },
        sleep: { _ in waits += 1 }, operation: { attempts += 1; throw Failure.throttled(1) })
      Issue.record("Expected final throttling failure")
    } catch {}
    #expect(attempts == 3)
    #expect(waits == 2)
  }

  @Test func accountChangeDuringWaitPreventsRetry() async {
    var current = true
    var attempts = 0
    do {
      let _: Int = try await MLSConversationCreationRetry.run(
        isCurrent: { current }, retryAfter: hint, onProgress: { _ in },
        sleep: { _ in current = false }, operation: { attempts += 1; throw Failure.throttled(2) })
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(attempts == 1)
  }

  @Test func cancellationDuringWaitPreventsRetry() async {
    var attempts = 0
    do {
      let _: Int = try await MLSConversationCreationRetry.run(
        isCurrent: { true }, retryAfter: hint, onProgress: { _ in },
        sleep: { _ in throw CancellationError() }, operation: { attempts += 1; throw Failure.throttled(2) })
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(attempts == 1)
  }

  @Test func obsoleteAccountCannotStartOrPublishOperation() async {
    var attempts = 0
    do {
      let _: Int = try await MLSConversationCreationRetry.run(
        isCurrent: { false }, retryAfter: hint, onProgress: { _ in },
        sleep: { _ in }, operation: { attempts += 1; return 1 })
      Issue.record("Expected cancellation")
    } catch { #expect(error is CancellationError) }
    #expect(attempts == 0)
  }
  @Test func accountChangeDuringNativeOperationDiscardsResult() async {
    var current = true
    do {
      let _: Int = try await MLSConversationCreationRetry.run(
        isCurrent: { current }, retryAfter: hint, onProgress: { _ in },
        sleep: { _ in }, operation: { current = false; return 42 })
      Issue.record("Obsolete native result must not be published")
    } catch { #expect(error is CancellationError) }
  }

  @Test func cancellationBeforeNativeResultPreventsPublication() async {
    let cancelled = await Task {
      do {
        let _: Int = try await MLSConversationCreationRetry.run(
          isCurrent: { true }, retryAfter: hint, onProgress: { _ in },
          sleep: { _ in }, operation: {
            withUnsafeCurrentTask { $0?.cancel() }
            return 42
          })
        return false
      } catch { return error is CancellationError }
    }.value
    #expect(cancelled)
  }

}
