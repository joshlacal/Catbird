import AVFoundation
import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("MLSVoiceSender audio session lifecycle")
struct MLSVoiceSenderTests {
  @Test("Idle cancelOrDiscard never touches the audio session")
  func idleCancelDoesNotTouchAudioSession() {
    let session = StubMLSVoiceRecordingSession()
    let sender = MLSVoiceSender(
      audioSession: session,
      requestPermission: { true },
      makeRecorder: { _, _ in StubMLSVoiceRecorder() }
    )

    sender.cancelOrDiscard()
    sender.cancelOrDiscard()

    #expect(session.requestedOwners.isEmpty)
    #expect(session.resetOwners.isEmpty)
  }

  @Test("Start and cancel execute AVAudioSession activation and deactivation off the main thread")
  func activationAndDeactivationRunOffMainThread() async throws {
    let driver = ThreadCheckingAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let recorder = StubMLSVoiceRecorder()
    let sender = MLSVoiceSender(
      audioSession: manager,
      requestPermission: { true },
      makeRecorder: { _, _ in recorder }
    )

    sender.startRecording()
    for _ in 0..<100 where recorder.recordCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recorder.recordCount == 1)

    sender.cancelOrDiscard()
    await manager.waitForPendingConfiguration()

    #expect(recorder.stopCount == 1)
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient])
    #expect(driver.mainThreadCalls.isEmpty)

    // Subsequent idle cancel (e.g. onDisappear after discard) must not touch the session again.
    sender.cancelOrDiscard()
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient])
  }

  @Test("Cancel while recording session activation is pending releases owner and never starts recorder")
  func cancelDuringPendingActivation() async {
    let session = StubMLSVoiceRecordingSession()
    let recorder = StubMLSVoiceRecorder()
    var recorderCreations = 0
    let sender = MLSVoiceSender(
      audioSession: session,
      requestPermission: { true },
      makeRecorder: { _, _ in
        recorderCreations += 1
        return recorder
      }
    )

    sender.startRecording()
    let owner = await session.nextRequest()

    sender.cancelOrDiscard()
    session.succeed(owner)
    await Task.yield()
    await Task.yield()

    #expect(recorderCreations == 0)
    #expect(recorder.recordCount == 0)
    #expect(session.activeOwners.isEmpty)
    #expect(session.resetOwners.contains(owner))
  }

  @Test("Recorder start failure releases recording session and surfaces error")
  func recorderFailureReleasesSession() async throws {
    let session = StubMLSVoiceRecordingSession()
    let recorder = StubMLSVoiceRecorder()
    recorder.canRecord = false
    let sender = MLSVoiceSender(
      audioSession: session,
      requestPermission: { true },
      makeRecorder: { _, _ in recorder }
    )

    sender.startRecording()
    let owner = await session.nextRequest()
    session.succeed(owner)

    for _ in 0..<100 where sender.voiceError == nil {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(sender.voiceError == "Couldn't start voice recording.")
    #expect(recorder.stopCount == 1)
    #expect(session.activeOwners.isEmpty)
    #expect(session.resetOwners == [owner])
  }

  @Test("Restarting while an earlier activation is pending isolates the new recording owner")
  func restartWhilePendingIsolatesOwners() async throws {
    let session = StubMLSVoiceRecordingSession()
    let recorder = StubMLSVoiceRecorder()
    let sender = MLSVoiceSender(
      audioSession: session,
      requestPermission: { true },
      makeRecorder: { _, _ in recorder }
    )

    sender.startRecording()
    let firstOwner = await session.nextRequest()

    sender.startRecording()
    let secondOwner = await session.nextRequest()
    #expect(firstOwner != secondOwner)

    session.succeed(secondOwner)
    for _ in 0..<100 where recorder.recordCount == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recorder.recordCount == 1)

    // Late completion of the cancelled first request must not stop or release the second.
    session.succeed(firstOwner)
    await Task.yield()
    await Task.yield()

    #expect(recorder.stopCount == 0)
    #expect(session.activeOwners == [secondOwner])

    sender.cancelOrDiscard()
    #expect(session.activeOwners.isEmpty)
  }

  @Test("Deinit releases an active recording session")
  func deinitReleasesActiveRecordingSession() async throws {
    let session = StubMLSVoiceRecordingSession()
    let recorder = StubMLSVoiceRecorder()
    do {
      let sender = MLSVoiceSender(
        audioSession: session,
        requestPermission: { true },
        makeRecorder: { _, _ in recorder }
      )
      sender.startRecording()
      let owner = await session.nextRequest()
      session.succeed(owner)
      for _ in 0..<100 where recorder.recordCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(session.activeOwners == [owner])
    }

    #expect(recorder.stopCount == 1)
    #expect(session.activeOwners.isEmpty)
  }
}

@MainActor
private final class StubMLSVoiceRecordingSession: AudioRecordingSession {
  private var completions: [UUID: CheckedContinuation<Void, Error>] = [:]
  private var queuedRequests: [UUID] = []
  private var waiters: [CheckedContinuation<UUID, Never>] = []
  private(set) var requestedOwners: [UUID] = []
  private(set) var activeOwners: Set<UUID> = []
  private(set) var resetOwners: [UUID] = []

  func configureForRecording(owner: UUID) async throws {
    try await withCheckedThrowingContinuation { continuation in
      completions[owner] = continuation
      requestedOwners.append(owner)
      if waiters.isEmpty {
        queuedRequests.append(owner)
      } else {
        waiters.removeFirst().resume(returning: owner)
      }
    }
  }

  func resetAfterRecording(owner: UUID) {
    activeOwners.remove(owner)
    resetOwners.append(owner)
  }

  func nextRequest() async -> UUID {
    if !queuedRequests.isEmpty { return queuedRequests.removeFirst() }
    return await withCheckedContinuation { waiters.append($0) }
  }

  func succeed(_ owner: UUID) {
    activeOwners.insert(owner)
    completions.removeValue(forKey: owner)?.resume()
  }
}

@MainActor
private final class StubMLSVoiceRecorder: AudioRecordingDevice {
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
  func stop() {
    stopCount += 1
    isRecording = false
  }
  func updateMeters() {}
  func averagePower(forChannel channelNumber: Int) -> Float { -60 }
}

private final class ThreadCheckingAudioSessionDriver: AudioSessionDriving, @unchecked Sendable {
  enum Action: Equatable {
    case activateRecording
    case deactivate
    case ambient
  }

  private let lock = NSLock()
  private var currentRecording = false
  private var recordedActions: [Action] = []
  private var recordedMainThreadCalls: [Action] = []

  var actions: [Action] { lock.withLock { recordedActions } }
  var mainThreadCalls: [Action] { lock.withLock { recordedMainThreadCalls } }

  var isVideoPlayback: Bool { false }
  var isRecording: Bool { lock.withLock { currentRecording } }
  var isAmbient: Bool { lock.withLock { !currentRecording } }
  var configuration: AudioSessionConfiguration {
    AudioSessionConfiguration(category: "ambient", mode: "default", options: 0)
  }

  func restoreConfiguration(_ configuration: AudioSessionConfiguration) throws {}
  func activateVideoPlayback() throws {}

  func activateRecording() throws {
    let onMain = Thread.isMainThread
    lock.withLock {
      currentRecording = true
      recordedActions.append(.activateRecording)
      if onMain { recordedMainThreadCalls.append(.activateRecording) }
    }
  }

  func deactivatePlayback() throws {
    let onMain = Thread.isMainThread
    lock.withLock {
      recordedActions.append(.deactivate)
      if onMain { recordedMainThreadCalls.append(.deactivate) }
    }
  }

  func configureAmbient() throws {
    let onMain = Thread.isMainThread
    lock.withLock {
      currentRecording = false
      recordedActions.append(.ambient)
      if onMain { recordedMainThreadCalls.append(.ambient) }
    }
  }
}
