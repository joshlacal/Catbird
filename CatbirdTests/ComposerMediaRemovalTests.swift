import Foundation
import Petrel
import Testing
@testable import Catbird

/// Removing an attachment from the composer never unlinks its file. A saved draft row, a
/// recovery envelope, another scene or the source account of a cross-account handoff may still
/// reference the same URL (SceneComposerEditingSession: "Editor teardown intentionally never
/// unlinks files"); draft media is deleted only with its saved-draft row.
@Suite("Composer media removal")
@MainActor
struct ComposerMediaRemovalTests {
  enum VideoLocation: String, CaseIterable, CustomTestStringConvertible {
    case capturedVideoStore
    case temporaryDirectory
    case sharedDrafts

    var testDescription: String { rawValue }
  }

  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:composermediaremovaltest", client: client)
    return PostComposerViewModel(appState: state)
  }

  private func makeVideo(at location: VideoLocation) async throws -> URL {
    let source = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")
    try Data([0, 1, 2, 3]).write(to: source)
    switch location {
    case .temporaryDirectory:
      return source
    case .capturedVideoStore:
      defer { try? FileManager.default.removeItem(at: source) }
      return try await CapturedVideoStore.applicationStore().importVideo(from: source)
    case .sharedDrafts:
      defer { try? FileManager.default.removeItem(at: source) }
      let container = try #require(FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.blue.catbird.shared"
      ))
      let directory = container.appendingPathComponent("SharedDrafts", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
      try FileManager.default.copyItem(at: source, to: url)
      return url
    }
  }

  @Test("Removing a video attachment leaves its file on disk", arguments: VideoLocation.allCases)
  func removingVideoKeepsFile(location: VideoLocation) async throws {
    let model = await makeViewModel()
    let videoURL = try await makeVideo(at: location)
    defer { try? FileManager.default.removeItem(at: videoURL) }
    var video = PostComposerViewModel.MediaItem(url: videoURL)
    video.isLoading = false
    model.videoItem = video

    model.removeMediaItem(withId: video.id)

    #expect(model.videoItem == nil)
    // A background unlink would finish within milliseconds; give it far longer than that.
    for _ in 0..<20 where FileManager.default.fileExists(atPath: videoURL.path) {
      try await Task.sleep(for: .milliseconds(50))
    }
    #expect(FileManager.default.fileExists(atPath: videoURL.path))
  }
}
