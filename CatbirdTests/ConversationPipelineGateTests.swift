import Foundation
import Testing
@testable import Catbird
@testable import CatbirdMLSCore

@Suite("ConversationPipelineGateTests")
struct ConversationPipelineGateTests {

    private final class MockClock: @unchecked Sendable {
        private var now: Date
        private let lock = NSLock()

        init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
            self.now = start
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            now = now.addingTimeInterval(seconds)
        }

        func time() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
    }

    private actor Barrier {
        private var isStarted = false
        private var isReleased = false

        func markStarted() {
            isStarted = true
        }

        func waitUntilStarted() async {
            while !isStarted {
                await Task.yield()
            }
        }

        func release() {
            isReleased = true
        }

        func waitUntilReleased() async {
            while !isReleased {
                await Task.yield()
            }
        }
    }

    private final class Counter: @unchecked Sendable {
        private var count = 0
        private let lock = NSLock()

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test func concurrentPipelineLaunchesCollapseToSingleRun() async {
        let gate = ConversationPipelineGate()
        let counter = Counter()
        let barrier = Barrier()

        async let r1 = gate.run(conversationID: "convo-collapse") {
            counter.increment()
            await barrier.markStarted()
            await barrier.waitUntilReleased()
            return true
        }

        await barrier.waitUntilStarted()

        // Concurrent launches while r1 is in flight
        async let r2 = gate.run(conversationID: "convo-collapse") {
            counter.increment()
            return true
        }
        async let r3 = gate.run(conversationID: "convo-collapse") {
            counter.increment()
            return true
        }
        // Wait until both r2 and r3 have entered gate.run and joined the in-flight task
        while gate.joinedCallersCount(for: "convo-collapse") < 2 {
            await Task.yield()
        }

        await barrier.release()
        let (res1, res2, res3) = await (r1, r2, r3)
        #expect(res1 == true)
        #expect(res2 == true)
        #expect(res3 == true)
        #expect(counter.value == 1)
        #expect(gate.joinedCallersCount(for: "convo-collapse") == 2)
    }

    @Test func failingPipelineHonoursBackoffAcrossRepeatedTriggers() async {
        let clock = MockClock()
        let gate = ConversationPipelineGate(
            timeProvider: { clock.time() },
            initialBackoff: 1.0,
            maxBackoff: 16.0,
            backoffMultiplier: 2.0
        )

        var executedAttempts = 0

        // Simulate 20 seconds of failing attempts with 5 triggers per second (105 triggers total).
        // Backoff schedule:
        // Attempt 1: at t=0, backoff = 1s, next = 1.0
        // Attempt 2: at t=1, backoff = 2s, next = 3.0
        // Attempt 3: at t=3, backoff = 4s, next = 7.0
        // Attempt 4: at t=7, backoff = 8s, next = 15.0
        // Attempt 5: at t=15, backoff = 16s, next = 31.0
        // All other triggers between t=0 and t=20 are throttled.
        for _ in 0...20 {
            for _ in 0..<5 {
                _ = await gate.run(conversationID: "convo-backoff", isUserInitiated: false) {
                    executedAttempts += 1
                    return false
                }
            }
            clock.advance(by: 1.0)
        }

        #expect(executedAttempts == 5)
        #expect(gate.failureCount(for: "convo-backoff") == 5)
    }

    @Test func userInitiatedRetryBypassesBackoff() async {
        let clock = MockClock()
        let gate = ConversationPipelineGate(
            timeProvider: { clock.time() },
            initialBackoff: 5.0,
            maxBackoff: 30.0,
            backoffMultiplier: 2.0
        )

        var attemptCount = 0

        // Initial failure at t=0
        let res1 = await gate.run(conversationID: "convo-retry", isUserInitiated: false) {
            attemptCount += 1
            return false
        }
        #expect(res1 == false)
        #expect(attemptCount == 1)

        // Advance only 1s into a 5s backoff
        clock.advance(by: 1.0)

        // Ambient trigger at t=1 should be throttled
        let res2 = await gate.run(conversationID: "convo-retry", isUserInitiated: false) {
            attemptCount += 1
            return false
        }
        #expect(res2 == false)
        #expect(attemptCount == 1) // Did not run

        // User-initiated retry at t=1 must run immediately
        let res3 = await gate.run(conversationID: "convo-retry", isUserInitiated: true) {
            attemptCount += 1
            return true
        }
        #expect(res3 == true)
        #expect(attemptCount == 2) // Ran immediately
    }

    @Test func successResetsBackoff() async {
        let clock = MockClock()
        let gate = ConversationPipelineGate(
            timeProvider: { clock.time() },
            initialBackoff: 2.0,
            maxBackoff: 30.0,
            backoffMultiplier: 2.0
        )

        // Two failures
        _ = await gate.run(conversationID: "convo-reset", isUserInitiated: false) { false }
        clock.advance(by: 2.0)
        _ = await gate.run(conversationID: "convo-reset", isUserInitiated: false) { false }

        #expect(gate.failureCount(for: "convo-reset") == 2)
        #expect(gate.nextAllowedAttempt(for: "convo-reset") != nil)

        // Next allowed attempt at t=6.0 (2.0 + 4.0)
        clock.advance(by: 4.0)

        // Now succeeds
        let successResult = await gate.run(conversationID: "convo-reset", isUserInitiated: false) { true }
        #expect(successResult == true)

        // Backoff must be reset
        #expect(gate.failureCount(for: "convo-reset") == 0)
        #expect(gate.nextAllowedAttempt(for: "convo-reset") == nil)

        // A new failure starts backoff over at initial (2.0s), not at previous 8.0s
        clock.advance(by: 0.1)
        _ = await gate.run(conversationID: "convo-reset", isUserInitiated: false) { false }
        #expect(gate.failureCount(for: "convo-reset") == 1)
    }

    private struct CustomLocalFailure: Error {}

    @Test func pipelineErrorClassificationMapsKnownAndUnmappedErrors() {
        // 1. Concrete error that caused the active DM failure
        let c1 = MLSConversationLifecycleError.classifyPipelineError(MLSConversationError.conversationNotFound)
        #expect(c1.diagnosticCode == "ConversationNotFound")
        #expect(c1.presentationHeadline == "Conversation Not Found")
        #expect(c1.presentationDetail.contains("Tap Retry"))

        // 2. Storage/pipeline access failures
        let c2 = MLSConversationLifecycleError.classifyPipelineError(MLSConversationPipelineAccess.Failure.unavailable)
        #expect(c2.diagnosticCode == "ConversationUnavailable")
        #expect(c2.presentationHeadline == "Conversation Unavailable")
        #expect(c2.presentationDetail.contains("Tap Retry"))

        // 3. Unmapped concrete error carries the concrete error type name, never generic UnknownError
        let c3 = MLSConversationLifecycleError.classifyPipelineError(CustomLocalFailure())
        #expect(c3.diagnosticCode == "Unmapped_CustomLocalFailure")
        #expect(c3.diagnosticCode != "UnknownError")
        #expect(c3.presentationHeadline == "Couldn't Load Messages")
        #expect(c3.presentationDetail.contains("Tap Retry"))
    }
}
