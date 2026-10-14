import Foundation
import Petrel
import SwiftData
import SwiftUI
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

  /// The thread-mode gallery (MediaGalleryView in PostComposerViewUIKit+Thread) edits
  /// `vm.mediaItems` through a Binding. Its remove button must still go through the composer's
  /// removeMediaItem, which cancels the attachment's load, updates the thread entry and saves.
  @Test("The thread gallery's remove button removes through the composer")
  func threadGalleryRemovesThroughComposer() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:composermediaremovaltest", client: client)
    let suiteName = "ComposerMediaRemovalTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let container = try ModelContainer(
      for: DraftPost.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    )
    let manager = ComposerDraftManager(accountDID: state.userDID, modelContext: container.mainContext, defaults: defaults)
    let session = SceneComposerEditingSession(
      manager: manager, accountDID: state.userDID, sceneID: UUID(), defaults: defaults, persistDelay: .seconds(60)
    )
    let model = PostComposerViewModel(appState: state, editingSession: session)
    try model.startEditing()
    model.postText = "First post"
    model.enterThreadMode()
    model.addNewThreadEntry()
    var photos = [PostComposerViewModel.MediaItem(), PostComposerViewModel.MediaItem()]
    for index in photos.indices {
      photos[index].altText = "Photo \(index)"
      photos[index].isLoading = false
    }
    model.mediaItems = photos
    model.updateCurrentThreadEntry()
    model.saveDraftIfNeeded()
    let entry = model.currentThreadIndex
    #expect(session.currentDraft?.threadEntries[entry].mediaItems.count == 2, "fixture: the session holds both photos")

    func gallery(onRemove: ((UUID) -> Void)?) -> MediaGalleryView {
      MediaGalleryView(
        mediaItems: Binding(get: { model.mediaItems }, set: { model.mediaItems = $0 }),
        currentEditingMediaId: .constant(nil),
        isAltTextEditorPresented: .constant(false),
        maxImagesAllowed: model.maxImagesAllowed,
        onAddMore: {},
        onRemove: onRemove
      )
    }

    // Without onRemove the gallery only edits its binding, as the thread view's did before.
    gallery(onRemove: nil).removeMediaItem(withId: photos[0].id)
    #expect(model.mediaItems.map(\.id) == [photos[1].id])
    #expect(model.threadEntries[entry].mediaItems.count == 2, "control: the binding alone leaves the entry stale")
    #expect(session.currentDraft?.threadEntries[entry].mediaItems.count == 2)

    // What the thread view now passes.
    gallery(onRemove: { model.removeMediaItem(withId: $0) }).removeMediaItem(withId: photos[1].id)
    #expect(model.mediaItems.isEmpty)
    #expect(model.threadEntries[entry].mediaItems.isEmpty)
    #expect(session.currentDraft?.threadEntries[entry].mediaItems.isEmpty == true)
  }
}
