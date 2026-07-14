import Foundation
import Petrel
import SwiftData
import Testing
@testable import Catbird

@Suite("Draft Persistence Captured Video Lifecycle")
struct DraftPersistenceCapturedVideoLifecycleTests {
  @Test("Persisted draft media waits for successful row deletion")
  func persistedDraftMediaDoesNotUseImmediateCleanup() {
    #expect(SavedDraftMediaCleanupPolicy.allowsImmediateCleanup(hasPersistedRow: false))
    #expect(!SavedDraftMediaCleanupPolicy.allowsImmediateCleanup(hasPersistedRow: true))
  }

  @MainActor
  @Test("Deleting a persisted captured-video draft removes its owned file")
  func deletingPersistedDraftRemovesOwnedVideo() async throws {
    let persistence = try makePersistence()
    let store = try CapturedVideoStore.applicationStore()
    let source = try makeTemporaryVideo()
    defer { try? FileManager.default.removeItem(at: source) }
    let ownedVideo = try await store.importVideo(from: source)
    defer { try? FileManager.default.removeItem(at: ownedVideo) }
    let draftID = try await persistence.saveDraftAsync(
      makeDraft(videoURL: ownedVideo),
      accountDID: "did:plc:captured-video-test"
    )

    try await persistence.deleteDraft(id: draftID)

    #expect(try await persistence.countDrafts(for: "did:plc:captured-video-test") == 0)
    #expect(!FileManager.default.fileExists(atPath: ownedVideo.path))
  }

  @MainActor
  @Test("Failed row deletion does not remove an owned file")
  func failedDeletePreservesOwnedVideo() async throws {
    let persistence = try makePersistence()
    let store = try CapturedVideoStore.applicationStore()
    let source = try makeTemporaryVideo()
    defer { try? FileManager.default.removeItem(at: source) }
    let ownedVideo = try await store.importVideo(from: source)
    defer { try? FileManager.default.removeItem(at: ownedVideo) }

    await #expect(throws: DraftError.self) {
      try await persistence.deleteDraft(id: UUID())
    }

    #expect(FileManager.default.fileExists(atPath: ownedVideo.path))
  }

  @MainActor
  @Test("Deleting a persisted draft never removes an unowned video URL")
  func deletePreservesUnownedVideo() async throws {
    let persistence = try makePersistence()
    let unownedVideo = try makeTemporaryVideo()
    defer { try? FileManager.default.removeItem(at: unownedVideo) }
    let draftID = try await persistence.saveDraftAsync(
      makeDraft(videoURL: unownedVideo),
      accountDID: "did:plc:unowned-video-test"
    )

    try await persistence.deleteDraft(id: draftID)

    #expect(try await persistence.countDrafts(for: "did:plc:unowned-video-test") == 0)
    #expect(FileManager.default.fileExists(atPath: unownedVideo.path))
  }

  @MainActor
  private func makePersistence() throws -> DraftPersistence {
    let schema = Schema([DraftPost.self])
    let configuration = ModelConfiguration(
      "DraftPersistenceCapturedVideoLifecycleTests",
      schema: schema,
      isStoredInMemoryOnly: true,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return DraftPersistence(modelContainer: container)
  }

  private func makeTemporaryVideo() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension("mov")
    try Data([0, 1, 2, 3]).write(to: url)
    return url
  }

  private func makeDraft(videoURL: URL) -> PostComposerDraft {
    let video = CodableMediaItem(
      altText: "",
      aspectRatio: nil,
      isLoading: false,
      isAudioVisualizerVideo: false,
      rawVideoURLString: videoURL.absoluteString,
      rawImageURLString: nil
    )
    return PostComposerDraft(
      postText: "Captured video",
      mediaItems: [],
      videoItem: video,
      selectedGif: nil,
      selectedLanguages: [],
      selectedLabels: [],
      outlineTags: [],
      threadEntries: [],
      isThreadMode: false,
      currentThreadIndex: 0,
      parentPostURI: nil,
      quotedPostURI: nil
    )
  }
}
