import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Composer recording activation lifetime")
struct ComposerRecordingStartTests {
  @Test("Immediate invalidation never invokes the recording operation")
  func invalidateBeforeTaskRuns() async throws {
    let start = ComposerRecordingStart()
    var operations = 0
    var phases = 0
    start.activate()
    #expect(start.start(operation: { operations += 1; return true }, cancel: {},
                        onStarted: { phases += 1 }, onFailure: { phases += 1 }))
    // No yield between enqueueing and invalidating the request.
    start.invalidate()
    try await waitFor { !start.isPending }
    #expect(operations == 0)
    #expect(phases == 0)
  }

  @Test("Cancel stops a late successful activation and never announces recording")
  func cancelDuringPendingActivation() async throws {
    let start = ComposerRecordingStart()
    let recorder = DelayedRecorder()
    var starts = 0
    var failures = 0
    start.activate()
    #expect(start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                        onStarted: { starts += 1 }, onFailure: { failures += 1 }))
    try await waitFor { recorder.continuation != nil }
    #expect(start.isPending)
    start.cancelPendingStart()
    recorder.complete()
    try await waitFor { !start.isPending }
    #expect(!recorder.isRecording)
    #expect(starts == 0)
    #expect(failures == 0)
    #expect(recorder.cancellations >= 2)
  }

  @Test("Repeated Record during activation starts once and waits for real success")
  func repeatedRecordWaitsForActivation() async throws {
    let start = ComposerRecordingStart()
    let recorder = DelayedRecorder()
    var starts = 0
    start.activate()
    #expect(start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                        onStarted: { starts += 1 }, onFailure: { }))
    try await waitFor { recorder.continuation != nil }
    #expect(!start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                         onStarted: { starts += 1 }, onFailure: { }))
    #expect(starts == 0)
    #expect(recorder.attempts == 1)
    #expect(!recorder.isRecording)
    recorder.complete()
    try await waitFor { !start.isPending }
    #expect(starts == 1)
    #expect(recorder.isRecording)
  }

  @Test("Disappearance invalidates activation before a new presentation can start")
  func disappearanceAndReappearanceInvalidateOldStart() async throws {
    let start = ComposerRecordingStart()
    let recorder = DelayedRecorder()
    var starts = 0
    start.activate()
    #expect(start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                        onStarted: { starts += 1 }, onFailure: { }))
    try await waitFor { recorder.continuation != nil }
    start.invalidate()
    #expect(!start.isPresented)
    start.activate()
    #expect(!start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                         onStarted: { starts += 1 }, onFailure: { }))
    recorder.complete()
    try await waitFor { !start.isPending }
    #expect(starts == 0)
    #expect(!recorder.isRecording)
    #expect(start.start(operation: { try await recorder.start() }, cancel: { recorder.cancel() },
                        onStarted: { starts += 1 }, onFailure: { }))
    try await waitFor { recorder.continuation != nil }
    recorder.complete()
    try await waitFor { !start.isPending }
    #expect(starts == 1)
    #expect(recorder.attempts == 2)
  }

  private func waitFor(_ ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(ready(), "Bounded activation did not settle")
  }

  @MainActor
  private final class DelayedRecorder {
    var continuation: CheckedContinuation<Void, Error>?
    var attempts = 0
    var cancellations = 0
    var isRecording = false

    func start() async throws -> Bool {
      attempts += 1
      try await withCheckedThrowingContinuation { continuation = $0 }
      // Deliberately ignores task cancellation, exercising caller cleanup after the await.
      isRecording = true
      return true
    }

    func complete() {
      continuation?.resume()
      continuation = nil
    }

    func cancel() {
      cancellations += 1
      isRecording = false
    }
  }
}
