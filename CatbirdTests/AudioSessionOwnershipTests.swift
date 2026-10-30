import Foundation
import Testing
@testable import Catbird

@Suite("Video audio session ownership")
struct AudioSessionOwnershipTests {
  @Test("Muted inline setup and an unrelated release cannot silence a video feed owner")
  func silentPreviewRespectsOwner() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    manager.releaseVideoPlayback(owner: UUID())
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateVideo])
    #expect(driver.mode == .video)
    manager.releaseVideoPlayback(owner: owner)
    manager.releaseVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateVideo, .deactivate, .ambient])
  }

  @Test("A second owner, including muted PiP, survives another owner's release")
  func separateOwners() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let feedOwner = UUID()
    let pictureInPictureOwner = UUID()
    manager.acquireVideoPlayback(owner: feedOwner)
    manager.acquireVideoPlayback(owner: pictureInPictureOwner)
    manager.releaseVideoPlayback(owner: feedOwner)
    manager.configureForSilentPlayback()
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(!driver.actions.contains(.deactivate))
    manager.releaseVideoPlayback(owner: pictureInPictureOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions.suffix(2) == [.deactivate, .ambient])
  }

  @Test("Pool cleanup preserves another active inline or fullscreen owner")
  func otherActivePlaybackOwner() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    let inlineOwner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    manager.acquireVideoPlayback(owner: inlineOwner)
    manager.releaseVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(!driver.actions.contains(.deactivate))
    manager.releaseVideoPlayback(owner: inlineOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions.suffix(2) == [.deactivate, .ambient])
  }

  @Test("An external recorder is neither reconfigured nor deactivated by a pool")
  func externalRecording() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    let inlineOwner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    driver.mode = .recording
    manager.releaseVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    manager.acquireVideoPlayback(owner: owner)
    manager.acquireVideoPlayback(owner: inlineOwner)
    manager.releaseVideoPlayback(owner: inlineOwner)
    manager.releaseVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .recording)
    #expect(driver.actions == [.activateVideo])
  }

  @Test("Releasing video ownership cannot deactivate a newer audio preview")
  func externalPlayback() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    driver.mode = .otherPlayback
    manager.releaseVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .otherPlayback)
    #expect(driver.actions == [.activateVideo])
  }

  @Test("Managed recording has priority and ending it restores retained playback intent")
  func managedRecording() async throws {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    let recordingOwner = UUID()
    try await manager.configureForRecording(owner: recordingOwner)
    manager.acquireVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    manager.releaseVideoPlayback(owner: UUID())
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateRecording])
    manager.resetAfterRecording(owner: recordingOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient, .activateVideo])
    manager.releaseVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
  }

  @Test("Stopping recording clears its category before the next video starts")
  func videoAfterRecordingStops() async throws {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let recordingOwner = UUID()
    let videoOwner = UUID()
    try await manager.configureForRecording(owner: recordingOwner)
    manager.resetAfterRecording(owner: recordingOwner)
    manager.acquireVideoPlayback(owner: videoOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient, .activateVideo])
    #expect(driver.mode == .video)
    manager.releaseVideoPlayback(owner: videoOwner)
    await manager.waitForPendingConfiguration()
  }

  @Test("Stale recording completion cannot release a newer recorder")
  func recordingOwnerIdentity() async throws {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let oldOwner = UUID()
    let newOwner = UUID()
    try await manager.configureForRecording(owner: oldOwner)
    manager.resetAfterRecording(owner: oldOwner)
    try await manager.configureForRecording(owner: newOwner)
    manager.resetAfterRecording(owner: oldOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .recording)
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient, .activateRecording])
    manager.resetAfterRecording(owner: newOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
  }

  @Test("Recording activation errors propagate and partial configuration is rolled back")
  func recordingActivationFailure() async {
    let driver = FixtureAudioSessionDriver()
    driver.failRecordingActivation = true
    let manager = AudioSessionManager(driver: driver)
    let recordingOwner = UUID()
    do {
      try await manager.configureForRecording(owner: recordingOwner)
      Issue.record("Recording activation must propagate its driver error")
    } catch {
      #expect(error is FixtureAudioSessionDriver.ActivationError)
    }
    #expect(driver.mode == .ambient)
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient])
    manager.resetAfterRecording(owner: recordingOwner)
    let videoOwner = UUID()
    manager.acquireVideoPlayback(owner: videoOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateRecording, .deactivate, .ambient, .activateVideo])
    manager.releaseVideoPlayback(owner: videoOwner)
    await manager.waitForPendingConfiguration()
  }
  @Test("Retiring inline ownership leaves no phantom owner for a later feed")
  func retiredInlineThenFeed() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let inlineOwner = UUID()
    let feedOwner = UUID()
    manager.acquireVideoPlayback(owner: inlineOwner)
    manager.releaseVideoPlayback(owner: inlineOwner)
    manager.acquireVideoPlayback(owner: feedOwner)
    manager.releaseVideoPlayback(owner: feedOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
    #expect(driver.actions == [.activateVideo, .deactivate, .ambient, .activateVideo, .deactivate, .ambient])
    manager.acquireVideoPlayback(owner: inlineOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    manager.releaseVideoPlayback(owner: inlineOwner)
    await manager.waitForPendingConfiguration()
  }

  @Test("Synchronous PiP and preview starts cannot take a recording session")
  func immediatePlaybackRespectsRecording() async throws {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let recordingOwner = UUID()
    let previewOwner = UUID()
    try await manager.configureForRecording(owner: recordingOwner)
    #expect(throws: AudioSessionManager.PlaybackActivationError.self) {
      try manager.acquireImmediatePlayback(owner: previewOwner)
    }
    manager.releaseVideoPlayback(owner: previewOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.actions == [.activateRecording])
    manager.resetAfterRecording(owner: recordingOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
    try manager.acquireImmediatePlayback(owner: previewOwner)
    #expect(driver.mode == .video)
    manager.releaseVideoPlayback(owner: previewOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
  }

  @Test("Stopping a preview leaves a retained feed lease active")
  func previewReleasePreservesFeed() async throws {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let feedOwner = UUID()
    let previewOwner = UUID()
    manager.acquireVideoPlayback(owner: feedOwner)
    try manager.acquireImmediatePlayback(owner: previewOwner)
    manager.releaseVideoPlayback(owner: previewOwner)
    manager.releaseVideoPlayback(owner: UUID())
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(!driver.actions.contains(.deactivate))
    manager.releaseVideoPlayback(owner: feedOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
  }

  @Test("Failed immediate activation restores its partial category without a phantom lease")
  func immediateActivationRollback() async {
    let driver = FixtureAudioSessionDriver()
    driver.failPlaybackActivation = true
    let manager = AudioSessionManager(driver: driver)
    let failedOwner = UUID()
    #expect(throws: FixtureAudioSessionDriver.ActivationError.self) {
      try manager.acquireImmediatePlayback(owner: failedOwner)
    }
    #expect(driver.mode == .ambient)
    #expect(driver.actions == [.activateVideo, .deactivate, .restore])
    manager.releaseVideoPlayback(owner: failedOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
    #expect(driver.actions == [.activateVideo, .deactivate, .restore])
  }

  @Test("Failed preview activation cannot deactivate a retained feed owner")
  func immediateFailureRetainsFeed() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let feedOwner = UUID()
    let failedOwner = UUID()
    manager.acquireVideoPlayback(owner: feedOwner)
    await manager.waitForPendingConfiguration()
    driver.failPlaybackActivation = true
    #expect(throws: FixtureAudioSessionDriver.ActivationError.self) {
      try manager.acquireImmediatePlayback(owner: failedOwner)
    }
    manager.releaseVideoPlayback(owner: failedOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(driver.actions == [.activateVideo, .activateVideo])
    manager.releaseVideoPlayback(owner: feedOwner)
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .ambient)
  }

  @Test("Failed immediate activation restores an external playback configuration without deactivation")
  func immediateFailureRestoresExternalConfiguration() {
    let driver = FixtureAudioSessionDriver()
    driver.mode = .otherPlayback
    driver.failPlaybackActivation = true
    let manager = AudioSessionManager(driver: driver)
    #expect(throws: FixtureAudioSessionDriver.ActivationError.self) {
      try manager.acquireImmediatePlayback(owner: UUID())
    }
    #expect(driver.mode == .otherPlayback)
    #expect(driver.actions == [.activateVideo, .restore])
  }

  @Test("A newer external recording category is not rolled back after a failed activation")
  func immediateFailurePreservesNewExternalOwner() {
    let driver = FixtureAudioSessionDriver()
    driver.failPlaybackActivation = true
    driver.playbackFailureMode = .recording
    let manager = AudioSessionManager(driver: driver)
    #expect(throws: FixtureAudioSessionDriver.ActivationError.self) {
      try manager.acquireImmediatePlayback(owner: UUID())
    }
    #expect(driver.mode == .recording)
    #expect(driver.actions == [.activateVideo])
  }

}

/// The lock protects both session-queue mutations and test-thread snapshots.
private final class FixtureAudioSessionDriver: AudioSessionDriving, @unchecked Sendable {
  enum Mode: String { case ambient, video, recording, otherPlayback }
  enum Action { case activateVideo, deactivate, ambient, activateRecording, restore }
  enum ActivationError: Error { case recording, playback }

  private let lock = NSLock()
  private var storedMode: Mode = .ambient
  private var storedActions: [Action] = []
  private var storedFailRecordingActivation = false
  private var storedFailPlaybackActivation = false
  private var storedPlaybackFailureMode: Mode?

  var mode: Mode {
    get { lock.withLock { storedMode } }
    set { lock.withLock { storedMode = newValue } }
  }

  var actions: [Action] { lock.withLock { storedActions } }
  var failRecordingActivation: Bool {
    get { lock.withLock { storedFailRecordingActivation } }
    set { lock.withLock { storedFailRecordingActivation = newValue } }
  }
  var failPlaybackActivation: Bool {
    get { lock.withLock { storedFailPlaybackActivation } }
    set { lock.withLock { storedFailPlaybackActivation = newValue } }
  }
  var playbackFailureMode: Mode? {
    get { lock.withLock { storedPlaybackFailureMode } }
    set { lock.withLock { storedPlaybackFailureMode = newValue } }
  }
  var isAmbient: Bool { mode == .ambient }
  var configuration: AudioSessionConfiguration {
    AudioSessionConfiguration(category: mode.rawValue, mode: "default", options: 0)
  }
  func restoreConfiguration(_ configuration: AudioSessionConfiguration) throws {
    lock.withLock {
      storedMode = Mode(rawValue: configuration.category)!
      storedActions.append(.restore)
    }
  }
  var isVideoPlayback: Bool { mode == .video }
  var isRecording: Bool { mode == .recording }

  func activateVideoPlayback() throws {
    try lock.withLock {
      storedMode = .video
      storedActions.append(.activateVideo)
      if storedFailPlaybackActivation {
        if let mode = storedPlaybackFailureMode { storedMode = mode }
        throw ActivationError.playback
      }
    }
  }

  func deactivatePlayback() throws {
    lock.withLock { storedActions.append(.deactivate) }
  }

  func configureAmbient() throws {
    lock.withLock {
      storedMode = .ambient
      storedActions.append(.ambient)
    }
  }

  func activateRecording() throws {
    try lock.withLock {
      storedMode = .recording
      storedActions.append(.activateRecording)
      if storedFailRecordingActivation { throw ActivationError.recording }
    }
  }
}
