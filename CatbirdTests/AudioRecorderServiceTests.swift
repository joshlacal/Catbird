import AVFoundation
import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Audio recorder pending start lifecycle")
struct AudioRecorderServiceTests {
  private struct Fixture {
    let service: AudioRecorderService
    let session: DelayedRecordingSession
    let recorder: FixtureRecordingDevice
    let creation: RecorderCreationProbe
  }

  private func fixture() -> Fixture {
    let session = DelayedRecordingSession()
    let recorder = FixtureRecordingDevice()
    let creation = RecorderCreationProbe()
    let service = AudioRecorderService(
      audioSession: session,
      recordingDirectory: URL(fileURLWithPath: "/audio-recorder-fixture"),
      makeRecorder: { _, _ in
        creation.count += 1
        if let error = creation.error { throw error }
        return recorder
      }
    )
    service.hasPermission = true
    return Fixture(service: service, session: session, recorder: recorder, creation: creation)
  }

  @Test("Cancel invalidates a pending start before delayed activation completes")
  func cancelPendingStart() async {
    let fixture = fixture()
    let start = Task { try await fixture.service.startRecording() }
    let owner = await fixture.session.nextRequest()
    #expect(fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)

    fixture.service.cancelRecording()
    #expect(!fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    fixture.session.succeed(owner)
    await expectCancellation(start)
    #expect(fixture.creation.count == 0)
    #expect(fixture.session.activeOwners.isEmpty)
    #expect(fixture.service.currentRecordingURL == nil)
  }

  @Test("A duplicate pending start throws instead of reporting recording success")
  func duplicatePendingStart() async throws {
    let fixture = fixture()
    let start = Task { try await fixture.service.startRecording() }
    let owner = await fixture.session.nextRequest()
    do {
      try await fixture.service.startRecording()
      Issue.record("A pending start must not return as though recording began")
    } catch {
      #expect((error as? AudioRecordingError) == .recordingInProgress)
    }
    #expect(fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    #expect(fixture.session.requestedOwners == [owner])
    #expect(fixture.creation.count == 0)

    fixture.session.succeed(owner)
    try await start.value
    #expect(!fixture.service.isStartingRecording)
    #expect(fixture.service.isRecording)
    #expect(fixture.recorder.recordCount == 1)
    fixture.service.stopRecording()
    #expect(fixture.session.activeOwners.isEmpty)
  }

  @Test("Late cancellation of an older start cannot stop the newer recording")
  func olderCancelledStartAfterNewerRecording() async throws {
    let fixture = fixture()
    let olderStart = Task { try await fixture.service.startRecording() }
    let olderOwner = await fixture.session.nextRequest()
    olderStart.cancel()
    fixture.service.stopRecording()

    let newerStart = Task { try await fixture.service.startRecording() }
    let newerOwner = await fixture.session.nextRequest()
    #expect(newerOwner != olderOwner)
    fixture.session.succeed(newerOwner)
    try await newerStart.value
    #expect(fixture.service.isRecording)

    fixture.session.succeed(olderOwner)
    await expectCancellation(olderStart)
    #expect(fixture.service.isRecording)
    #expect(!fixture.service.isStartingRecording)
    #expect(fixture.recorder.stopCount == 0)
    #expect(fixture.creation.count == 1)
    #expect(fixture.session.activeOwners == [newerOwner])
    fixture.service.stopRecording()
    #expect(fixture.session.activeOwners.isEmpty)
  }

  @Test("Task cancellation alone cannot start the recorder after delayed activation")
  func cancelledTaskCannotStartRecorder() async {
    let fixture = fixture()
    let start = Task { try await fixture.service.startRecording() }
    let owner = await fixture.session.nextRequest()
    start.cancel()
    fixture.session.succeed(owner)
    await expectCancellation(start)
    #expect(!fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    #expect(fixture.creation.count == 0)
    #expect(fixture.session.activeOwners.isEmpty)
  }

  @Test("Activation and recorder setup failures propagate and release the pending owner")
  func setupFailures() async {
    let fixture = fixture()
    let activation = Task { try await fixture.service.startRecording() }
    let firstOwner = await fixture.session.nextRequest()
    fixture.session.fail(firstOwner, error: FixtureRecordingError.activation)
    let activationResult = await activation.result
    if case .failure(let error) = activationResult {
      #expect((error as? FixtureRecordingError) == .activation)
    } else {
      Issue.record("Session activation failure must propagate")
    }
    #expect(!fixture.service.isStartingRecording)
    #expect(fixture.creation.count == 0)

    fixture.creation.error = FixtureRecordingError.setup
    let setup = Task { try await fixture.service.startRecording() }
    let secondOwner = await fixture.session.nextRequest()
    fixture.session.succeed(secondOwner)
    let setupResult = await setup.result
    if case .failure(let error) = setupResult {
      #expect((error as? FixtureRecordingError) == .setup)
    } else {
      Issue.record("Recorder construction failure must propagate")
    }
    #expect(!fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    #expect(fixture.session.activeOwners.isEmpty)
  }

  @Test("A device that refuses to record releases its session without reporting success")
  func recordFailure() async {
    let fixture = fixture()
    fixture.recorder.canRecord = false
    let start = Task { try await fixture.service.startRecording() }
    let owner = await fixture.session.nextRequest()
    fixture.session.succeed(owner)
    let result = await start.result
    if case .failure(let error) = result {
      #expect((error as? AudioRecordingError) == .recordingFailed)
    } else {
      Issue.record("A device start failure must propagate")
    }
    #expect(!fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    #expect(fixture.recorder.stopCount == 1)
    #expect(fixture.session.activeOwners.isEmpty)
  }

  private func expectCancellation(_ task: Task<Void, Error>) async {
    let result = await task.result
    if case .failure(let error) = result {
      #expect(error is CancellationError)
    } else {
      Issue.record("An invalidated pending start must throw cancellation")
    }
  }
}

private enum FixtureRecordingError: Error { case activation, setup }

@MainActor
private final class RecorderCreationProbe {
  var count = 0
  var error: Error?
}

/// Activation deliberately completes even after reset to exercise stale responses.
@MainActor
private final class DelayedRecordingSession: AudioRecordingSession {
  private var completions: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var queuedRequests: [UUID] = []
  private var requestWaiters: [CheckedContinuation<UUID, Never>] = []
  private(set) var requestedOwners: [UUID] = []
  private(set) var activeOwners: Set<UUID> = []

  func configureForRecording(owner: UUID) async throws {
    try await withCheckedThrowingContinuation { continuation in
      completions[owner] = continuation
      requestedOwners.append(owner)
      if requestWaiters.isEmpty {
        queuedRequests.append(owner)
      } else {
        requestWaiters.removeFirst().resume(returning: owner)
      }
    }
  }

  func resetAfterRecording(owner: UUID) { activeOwners.remove(owner) }

  func nextRequest() async -> UUID {
    if !queuedRequests.isEmpty { return queuedRequests.removeFirst() }
    return await withCheckedContinuation { requestWaiters.append($0) }
  }

  func succeed(_ owner: UUID) {
    activeOwners.insert(owner)
    completions.removeValue(forKey: owner)?.resume()
  }

  func fail(_ owner: UUID, error: Error) {
    completions.removeValue(forKey: owner)?.resume(throwing: error)
  }
}

@MainActor
private final class FixtureRecordingDevice: AudioRecordingDevice {
  var delegate: (any AVAudioRecorderDelegate)?
  var isMeteringEnabled = false
  private(set) var isRecording = false
  var canRecord = true
  private(set) var recordCount = 0
  private(set) var stopCount = 0

  func prepareToRecord() -> Bool { true }
  func record() -> Bool {
    recordCount += 1
    isRecording = canRecord
    return canRecord
  }
  func stop() { stopCount += 1; isRecording = false }
  func updateMeters() {}
  func averagePower(forChannel channelNumber: Int) -> Float { -60 }
}
