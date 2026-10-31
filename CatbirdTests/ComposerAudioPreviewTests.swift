import AVFoundation
import Foundation
import Testing
@testable import Catbird

@MainActor
@Suite("Composer audio preview ownership")
struct ComposerAudioPreviewTests {
  @Test("Stopping an unused preview never releases another playback or recording owner")
  func stopWithoutPreviewLeavesOtherOwners() {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let preview = AudioPlaybackService(audioSession: session)
    preview.stop()
    #expect(session.owners == [other])
    #expect(session.releases.isEmpty)
  }

  @Test("Preview stops release only the preview lease")
  func previewStopReleasesOnlyOwnedLease() async throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let player = Player()
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
    #expect(player.starts == 1)
    #expect(session.owners.count == 2)
    #expect(preview.isPlaying)
    preview.stop()
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(!preview.isPlaying)
  }

  @Test("Recording priority errors propagate before a preview starts or acquires ownership")
  func recordingPriorityFailurePreventsPreview() async throws {
    let session = Session()
    session.failure = AudioSessionManager.PlaybackActivationError.recordingInProgress
    let player = Player()
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    do {
      try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
      Issue.record("Recording priority must reject playback")
    } catch {
      guard case AudioSessionManager.PlaybackActivationError.recordingInProgress = error else {
        Issue.record("Original activation error was replaced")
        return
      }
    }
    #expect(player.starts == 0)
    #expect(session.owners.isEmpty)
    #expect(session.releases.isEmpty)
    #expect(!preview.isPlaying)
  }

  @Test("A failed player start releases the acquired preview lease without releasing others")
  func failedPlaybackReleasesOnlyPreview() async throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let player = Player()
    player.canPlay = false
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    do {
      try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
      Issue.record("A failed player start must throw")
    } catch { #expect(error is AudioPlaybackError) }
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(!preview.isPlaying)
  }

  @Test("Retiring a preview releases its lease and stops its player")
  func deinitReleasesPreview() async throws {
    let session = Session()
    let player = Player()
    var preview: AudioPlaybackService? = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    try preview?.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
    #expect(session.owners.count == 1)
    preview = nil
    #expect(session.owners.isEmpty)
    #expect(player.stops == 1)
  }

  @Test("Callback retirement releases only the current preview lease")
  func callbackRetirementReleasesPreview() throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let player = Player()
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
    preview.retirePlayback(player)
    #expect(!preview.isPlaying)
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(player.stops == 1)
    preview.stop()
    #expect(session.releases.count == 1)
  }

  @Test("Repeated callback retirement after stop never releases another owner")
  func repeatedRetirementAfterStop() throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let player = Player()
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
    preview.stop()
    preview.retirePlayback(player)
    preview.retirePlayback(player)
    #expect(!preview.isPlaying)
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(player.stops == 1)
  }

  @Test("A stale callback retirement cannot release the replacement preview")
  func staleCallbackRetirementPreservesReplacement() throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let retired = Player()
    let current = Player()
    var players = [retired, current]
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in players.removeFirst() })
    defer { preview.stop() }
    try preview.play(url: URL(fileURLWithPath: "/tmp/retired-preview.m4a"))
    let delayedRetirement = { preview.retirePlayback(retired) }
    try preview.play(url: URL(fileURLWithPath: "/tmp/current-preview.m4a"))
    let replacementOwners = session.owners
    delayedRetirement()
    delayedRetirement()
    #expect(preview.isPlaying)
    #expect(session.owners == replacementOwners)
    #expect(session.owners.count == 2)
    #expect(session.releases.count == 1)
    #expect(retired.stops == 1)
    #expect(current.stops == 0)
    preview.retirePlayback(current)
    #expect(!preview.isPlaying)
    #expect(session.owners == [other])
    #expect(session.releases.count == 2)
  }

  @Test("Player construction failure releases the acquired lease without releasing others")
  func constructionFailureReleasesPreview() throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in throw PreviewFixtureError.construction })
    do {
      try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
      Issue.record("Player construction failure must throw")
    } catch { #expect(error is PreviewFixtureError) }
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(!preview.isPlaying)
  }

  @Test("Player preparation failure stops the player and releases only its lease")
  func preparationFailureReleasesPreview() throws {
    let session = Session()
    let other = UUID()
    session.owners.insert(other)
    let player = Player()
    player.canPrepare = false
    let preview = AudioPlaybackService(audioSession: session, makePlayer: { _ in player })
    do {
      try preview.play(url: URL(fileURLWithPath: "/tmp/synthetic-preview.m4a"))
      Issue.record("Player preparation failure must throw")
    } catch { #expect(error is AudioPlaybackError) }
    #expect(player.starts == 0)
    #expect(player.stops == 1)
    #expect(session.owners == [other])
    #expect(session.releases.count == 1)
    #expect(!preview.isPlaying)
  }

  private enum PreviewFixtureError: Error { case construction }

  @MainActor
  private final class Player: ComposerAudioPreviewPlayer {
    weak var delegate: (any AVAudioPlayerDelegate)?
    var currentTime: TimeInterval = 0
    var canPrepare = true
    var canPlay = true
    var starts = 0
    var stops = 0
    func prepareToPlay() -> Bool { canPrepare }
    func play() -> Bool { starts += 1; return canPlay }
    func stop() { stops += 1 }
  }

  private final class Session: ImmediatePlaybackAudioSession {
    var owners: Set<UUID> = []
    var releases: [UUID] = []
    var failure: Error?
    func acquireVideoPlayback(owner: UUID) { owners.insert(owner) }
    func acquireImmediatePlayback(owner: UUID) throws {
      if let failure { throw failure }
      owners.insert(owner)
    }
    func releaseVideoPlayback(owner: UUID) { releases.append(owner); owners.remove(owner) }
  }
}
