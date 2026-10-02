import Foundation
import Testing
@testable import Catbird

@MainActor
struct AccountServiceWorkTests {
    @Test
    func suspensionWaitsForCancelledTaskToActuallyExit() async throws {
        let work = AccountServiceWork()
        var continuation: CheckedContinuation<Void, Never>?
        var finished = false
        work.start {
            await withCheckedContinuation { continuation = $0 }
            finished = true
        }
        while continuation == nil { await Task.yield() }
        work.suspend()
        do {
            try await work.drain(timeout: .milliseconds(1))
            Issue.record("A cancellation-resistant task was reported drained")
        } catch AccountServiceWork.BarrierError.drainTimedOut {
            #expect(!finished)
            #expect(work.isSuspended)
        }
        continuation?.resume()
        try await work.drain()
        #expect(finished)
        #expect(work.isSuspended)
    }

    @Test
    func suspendedWorkRejectsNewTasksUntilExplicitResume() async throws {
        let work = AccountServiceWork()
        var executions = 0
        work.suspend()
        #expect(work.start { executions += 1 } == nil)
        #expect(work.beginOperation() == nil)
        try await work.drain()
        work.resume()
        let resumed = try #require(work.start { executions += 1 })
        await resumed.value
        #expect(executions == 1)
    }

    @Test
    func directRequestsKeepBarrierClosedUntilTheyFinish() async throws {
        let work = AccountServiceWork()
        let operation = try #require(work.beginOperation())
        #expect(work.isCurrent(operation))
        work.suspend()
        #expect(!work.isCurrent(operation))
        do {
            try await work.drain(timeout: .milliseconds(1))
            Issue.record("An in-flight direct request was reported drained")
        } catch AccountServiceWork.BarrierError.drainTimedOut {
            #expect(work.isSuspended)
        }
        work.endOperation(operation)
        try await work.drain()
        work.resume()
        #expect(!work.isCurrent(operation))
        #expect(work.beginOperation() != nil)
    }

    @Test
    func timedOutServiceReceiptRetainsItsEventualCompletion() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let receipt = AccountServiceDrainReceipt {
            await withCheckedContinuation { continuation = $0 }
        }
        while continuation == nil { await Task.yield() }
        do {
            try await receipt.wait(timeout: .milliseconds(1))
            Issue.record("An outstanding service request was reported complete")
        } catch AccountServiceWork.BarrierError.drainTimedOut {
            #expect(!receipt.isComplete)
        }
        continuation?.resume()
        try await receipt.wait()
        #expect(receipt.isComplete)
    }

    @Test
    func cancellationBeforeTaskStartsCannotRunAfterResume() async throws {
        let work = AccountServiceWork()
        var executions = 0
        work.start { executions += 1 }
        work.suspend()
        work.resume()
        try await work.drain()
        #expect(executions == 0)
    }
}
