import AVFoundation
import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Composer and recorder combined lifetime")
struct ComposerAudioLifecycleTests {
  @Test("Immediate disappearance never requests session activation or creates a recorder")
  func invalidateBeforeActivationBegins() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    fixture.start.invalidate()
    fixture.service.stopRecording()
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.session.requestedOwners.isEmpty)
    #expect(fixture.events.createdURLs.isEmpty)
    #expect(fixture.device.recordCount == 0)
    #expect(fixture.events.started == 0)
    #expect(fixture.events.failed == 0)
  }

  @Test("Cancel while activation is suspended prevents recorder creation and phase publication")
  func cancelPendingActivation() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    let owner = try await fixture.nextOwner()
    #expect(fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    fixture.start.cancelPendingStart()
    #expect(!fixture.service.isStartingRecording)
    fixture.session.succeed(owner)
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.device.recordCount == 0)
    #expect(fixture.events.createdURLs.isEmpty)
    #expect(fixture.events.started == 0)
    #expect(fixture.events.failed == 0)
    #expect(fixture.session.activeOwners.isEmpty)
    #expect(fixture.service.currentRecordingURL == nil)
  }

  @Test("Disappear and reappear retire the old activation before accepting another recording")
  func disappearAndReappear() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    let oldOwner = try await fixture.nextOwner()
    fixture.start.invalidate()
    fixture.service.stopRecording()
    #expect(!fixture.service.isStartingRecording)
    fixture.start.activate()
    #expect(!fixture.begin())
    fixture.session.succeed(oldOwner)
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.events.started == 0)
    #expect(fixture.events.failed == 0)
    #expect(fixture.device.recordCount == 0)
    #expect(fixture.session.activeOwners.isEmpty)

    #expect(fixture.begin())
    let newOwner = try await fixture.nextOwner(after: 1)
    #expect(newOwner != oldOwner)
    fixture.session.succeed(newOwner)
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.service.isRecording)
    #expect(fixture.events.started == 1)
    #expect(fixture.device.recordCount == 1)
    #expect(fixture.session.activeOwners == [newOwner])
  }

  @Test("Repeated Record taps reserve one service activation and announce only its success")
  func repeatedRecordTaps() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    #expect(!fixture.begin())
    let owner = try await fixture.nextOwner()
    #expect(!fixture.begin())
    #expect(fixture.session.requestedOwners == [owner])
    #expect(fixture.events.started == 0)
    #expect(fixture.device.recordCount == 0)
    fixture.session.succeed(owner)
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.events.started == 1)
    #expect(fixture.events.failed == 0)
    #expect(fixture.device.recordCount == 1)
  }

  @Test("A delayed activation failure after disappearance cannot publish a stale failure phase")
  func delayedFailureAfterInvalidation() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    let owner = try await fixture.nextOwner()
    fixture.start.invalidate()
    fixture.service.stopRecording()
    fixture.session.fail(owner)
    try await waitFor { !fixture.start.isPending }
    #expect(fixture.events.started == 0)
    #expect(fixture.events.failed == 0)
    #expect(!fixture.service.isStartingRecording)
    #expect(!fixture.service.isRecording)
    #expect(fixture.events.createdURLs.isEmpty)
    #expect(fixture.session.activeOwners.isEmpty)
  }

  @Test("A completed recording handed to a draft survives caller invalidation and recorder stop cleanup")
  func completedFileSurvivesHandoffCleanup() async throws {
    let fixture = try fixture()
    defer { fixture.cleanup() }
    #expect(fixture.begin())
    let owner = try await fixture.nextOwner()
    fixture.session.succeed(owner)
    try await waitFor { !fixture.start.isPending }
    fixture.service.stopRecording()
    let completedURL = try #require(fixture.service.currentRecordingURL)
    var draftAudioURL: URL?
    let onAudioRecorded: (URL) -> Void = { draftAudioURL = $0 }
    onAudioRecorded(completedURL)

    // Same cleanup ordering as the recording sheet after Next hands off its URL.
    fixture.start.invalidate()
    fixture.service.stopRecording()
    let handedOffURL = try #require(draftAudioURL)
    #expect(handedOffURL == completedURL)
    #expect(fixture.service.currentRecordingURL == handedOffURL)
    #expect(try Data(contentsOf: handedOffURL) == fixture.recordedBytes)
    #expect(fixture.device.stopCount == 1)
    #expect(fixture.session.activeOwners.isEmpty)
    #expect(!fixture.service.isRecording)
    #expect(!fixture.service.isStartingRecording)
  }

  private func fixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-audio-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let session = DelayedSession()
    let device = RecordingDevice()
    let events = Events()
    let recordedBytes = Data("completed recording fixture".utf8)
    let service = AudioRecorderService(audioSession: session, recordingDirectory: directory, makeRecorder: { url, _ in
      events.createdURLs.append(url)
      try recordedBytes.write(to: url)
      return device
    })
    service.hasPermission = true
    let start = ComposerRecordingStart()
    start.activate()
    return Fixture(start: start, service: service, session: session, device: device,
                   events: events, directory: directory, recordedBytes: recordedBytes)
  }

  private func waitFor(_ ready: () -> Bool) async throws {
    for _ in 0..<100 {
      if ready() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(ready(), "Bounded combined recording activation did not settle")
  }

  @MainActor
  private struct Fixture {
    let start: ComposerRecordingStart
    let service: AudioRecorderService
    let session: DelayedSession
    let device: RecordingDevice
    let events: Events
    let directory: URL
    let recordedBytes: Data

    func begin() -> Bool {
      start.start(operation: {
        try await service.startRecording()
        return service.isRecording
      }, cancel: { service.cancelRecording() },
      onStarted: { events.started += 1 }, onFailure: { events.failed += 1 })
    }

    func nextOwner(after previousCount: Int = 0) async throws -> UUID {
      for _ in 0..<100 {
        if session.requestedOwners.count > previousCount { return session.requestedOwners[previousCount] }
        try await Task.sleep(for: .milliseconds(5))
      }
      try #require(session.requestedOwners.count > previousCount, "Recorder never requested activation")
      return session.requestedOwners[previousCount]
    }

    func cleanup() {
      start.invalidate()
      service.stopRecording()
      session.failPending()
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private final class Events {
    var started = 0
    var failed = 0
    var createdURLs: [URL] = []
  }

  @MainActor
  private final class DelayedSession: AudioRecordingSession {
    private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var requestedOwners: [UUID] = []
    private(set) var activeOwners: Set<UUID> = []

    func configureForRecording(owner: UUID) async throws {
      try await withCheckedThrowingContinuation { continuation in
        pending[owner] = continuation
        requestedOwners.append(owner)
      }
    }

    func resetAfterRecording(owner: UUID) { activeOwners.remove(owner) }

    func succeed(_ owner: UUID) {
      activeOwners.insert(owner)
      pending.removeValue(forKey: owner)?.resume()
    }

    func fail(_ owner: UUID) {
      pending.removeValue(forKey: owner)?.resume(throwing: ActivationFailure.failed)
    }

    func failPending() {
      let continuations = Array(pending.values)
      pending.removeAll()
      for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
  }

  private enum ActivationFailure: Error { case failed }

  @MainActor
  private final class RecordingDevice: AudioRecordingDevice {
    weak var delegate: (any AVAudioRecorderDelegate)?
    var isMeteringEnabled = false
    private(set) var isRecording = false
    private(set) var recordCount = 0
    private(set) var stopCount = 0
    func prepareToRecord() -> Bool { true }
    func record() -> Bool { recordCount += 1; isRecording = true; return true }
    func stop() { stopCount += 1; isRecording = false }
    func updateMeters() { }
    func averagePower(forChannel channelNumber: Int) -> Float { -60 }
  }
}
