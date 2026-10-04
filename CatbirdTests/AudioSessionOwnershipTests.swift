import Foundation
import Testing
@testable import Catbird

@Suite("Video audio session ownership")
struct AudioSessionOwnershipTests {
  @Test("Muted inline setup and legacy mute cannot silence a video feed owner")
  func silentPreviewRespectsOwner() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    manager.handleVideoMute()
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

  @Test("Pool cleanup preserves newer inline or fullscreen unmute intent")
  func newerLegacyIntent() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    manager.handleVideoUnmute()
    manager.releaseVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    await manager.waitForPendingConfiguration()
    #expect(driver.mode == .video)
    #expect(!driver.actions.contains(.deactivate))
    manager.handleVideoMute()
    await manager.waitForPendingConfiguration()
    #expect(driver.actions.suffix(2) == [.deactivate, .ambient])
  }

  @Test("An external recorder is neither reconfigured nor deactivated by a pool")
  func externalRecording() async {
    let driver = FixtureAudioSessionDriver()
    let manager = AudioSessionManager(driver: driver)
    let owner = UUID()
    manager.acquireVideoPlayback(owner: owner)
    await manager.waitForPendingConfiguration()
    driver.mode = .recording
    manager.releaseVideoPlayback(owner: owner)
    manager.configureForSilentPlayback()
    manager.acquireVideoPlayback(owner: owner)
    manager.handleVideoUnmute()
    manager.handleVideoMute()
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
    manager.handleVideoMute()
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
}

/// The lock protects both session-queue mutations and test-thread snapshots.
private final class FixtureAudioSessionDriver: AudioSessionDriving, @unchecked Sendable {
  enum Mode { case ambient, video, recording, otherPlayback }
  enum Action { case activateVideo, deactivate, ambient, activateRecording }
  enum ActivationError: Error { case recording }

  private let lock = NSLock()
  private var storedMode: Mode = .ambient
  private var storedActions: [Action] = []
  private var storedFailRecordingActivation = false

  var mode: Mode {
    get { lock.withLock { storedMode } }
    set { lock.withLock { storedMode = newValue } }
  }

  var actions: [Action] { lock.withLock { storedActions } }
  var failRecordingActivation: Bool {
    get { lock.withLock { storedFailRecordingActivation } }
    set { lock.withLock { storedFailRecordingActivation = newValue } }
  }
  var isVideoPlayback: Bool { mode == .video }
  var isRecording: Bool { mode == .recording }

  func activateVideoPlayback() throws {
    lock.withLock {
      storedMode = .video
      storedActions.append(.activateVideo)
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
