import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Composer media preparation")
@MainActor
struct ComposerMediaPreparationTests {
  private func savedItem(imageURL: URL? = nil, videoURL: URL? = nil) -> CodableMediaItem {
    CodableMediaItem(
      altText: "A description worth retaining", aspectRatio: nil, isLoading: true,
      isAudioVisualizerVideo: false, rawVideoURLString: videoURL?.absoluteString,
      rawImageURLString: imageURL?.absoluteString
    )
  }

  private func makeViewModel() async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    let state = AppState(userDID: "did:plc:mediapreparationtest", client: client)
    return PostComposerViewModel(appState: state)
  }

  @Test("A restored loading flag cannot advertise work with no source")
  func missingSourceIsTerminal() {
    let item = savedItem().toMediaItem()
    #expect(!item.isLoading)
    #expect(item.image == nil)
    #expect(item.altText == "A description worth retaining")
  }

  @Test("Missing draft media stays unavailable and retains its reference on autosave")
  func missingImageReferenceSurvivesAutosave() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-composer-image-\(UUID()).jpg")
    let item = savedItem(imageURL: url).toMediaItem()
    #expect(!item.isLoading)
    #expect(item.image == nil)
    #expect(item.rawImageURL == url)
    let resaved = CodableMediaItem(from: item)
    #expect(resaved.rawImageURLString == url.absoluteString)
    #expect(resaved.altText == "A description worth retaining")
  }

  @Test("Unreadable image bytes do not leave a perpetual preparation state")
  func corruptImageIsTerminalAndPreserved() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("corrupt-composer-image-\(UUID()).jpg")
    let data = Data("Not an image".utf8)
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let item = savedItem(imageURL: url).toMediaItem()
    #expect(!item.isLoading)
    #expect(item.image == nil)
    #expect(item.rawImageURL == url)
    #expect(try Data(contentsOf: url) == data)
  }

  @Test("Restoring a video reference does not claim an unstarted task")
  func videoReferenceRestoresTerminal() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("unprepared-composer-video-\(UUID()).mp4")
    let item = savedItem(videoURL: url).toMediaItem()
    #expect(!item.isLoading)
    #expect(item.rawVideoURL == url)
  }

  @Test("Loading a thread entry preserves media identity and preparation metadata")
  func threadEntryRetainsMediaIdentity() async throws {
    let model = await makeViewModel()
    defer { model.clearAll() }
    var item = savedItem().toMediaItem()
    item.isGifConversion = true
    item.isAudioVisualizerVideo = true
    var entry = ThreadEntry()
    entry.mediaItems = [item]
    model.threadEntries = [entry]
    model.currentThreadIndex = 0

    model.loadEntryState()

    let restored = try #require(model.mediaItems.first)
    #expect(restored.id == item.id)
    #expect(restored.altText == item.altText)
    #expect(restored.isGifConversion)
    #expect(restored.isAudioVisualizerVideo)
    #expect(!restored.isLoading)
  }

  @Test("An unavailable image blocks posting while preserving meaningful draft content")
  func unavailableImageBlocksSubmit() async {
    let model = await makeViewModel()
    defer { model.clearAll() }
    model.postText = "Keep this draft and its attachment"
    model.mediaItems = [savedItem().toMediaItem()]

    #expect(!model.submitValidationState.canSubmit)
    #expect(model.submitValidationState.reason == .mediaUnavailable)
    #expect(model.hasMeaningfulDraftContent)
    #expect(model.saveDraftState().mediaItems.count == 1)
  }

  @Test("An image actively preparing blocks posting")
  func preparingImageBlocksSubmit() async {
    let model = await makeViewModel()
    defer { model.clearAll() }
    var item = savedItem().toMediaItem()
    item.isLoading = true
    model.mediaItems = [item]

    #expect(!model.submitValidationState.canSubmit)
    #expect(model.submitValidationState.reason == .mediaPreparing)
  }

  @Test("Unavailable media in another thread entry also blocks posting")
  func unavailableImageInOtherEntryBlocksSubmit() async {
    let model = await makeViewModel()
    defer { model.clearAll() }
    var first = ThreadEntry()
    first.text = "Current entry"
    var second = ThreadEntry()
    second.mediaItems = [savedItem().toMediaItem()]
    model.threadEntries = [first, second]
    model.currentThreadIndex = 0
    model.isThreadMode = true
    model.postText = first.text

    #expect(!model.submitValidationState.canSubmit)
    #expect(model.submitValidationState.reason == .mediaUnavailable)
    #expect(model.threadEntries[1].mediaItems.count == 1)
  }

  @Test("Completing media offscreen settles only its original entry and retains the source")
  func offscreenCompletionPreservesCurrentMedia() async throws {
    let model = await makeViewModel()
    defer { model.clearAll() }
    var original = savedItem().toMediaItem()
    original.rawImageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("offscreen-composer-image-\(UUID()).jpg")
    original.isLoading = true
    var first = ThreadEntry()
    first.mediaItems = [original]
    var other = savedItem().toMediaItem()
    other.isLoading = true
    var second = ThreadEntry()
    second.mediaItems = [other]
    model.isThreadMode = true
    model.threadEntries = [first, second]
    model.currentThreadIndex = 0
    model.mediaItems = [original]
    let context = model.mediaLoadContext()

    model.currentThreadIndex = 1
    model.mediaItems = [other]
    model.finishMediaLoad(withId: original.id, context: context)

    let settled = try #require(model.threadEntries[0].mediaItems.first)
    #expect(!settled.isLoading)
    #expect(settled.id == original.id)
    #expect(settled.rawImageURL == original.rawImageURL)
    #expect(settled.altText == original.altText)
    #expect(model.mediaItems.first?.id == other.id)
    #expect(model.mediaItems.first?.isLoading == true)
    #expect(model.threadEntries[1].mediaItems.first?.isLoading == true)
  }

  @Test("A completion from a cleared draft cannot settle a reused attachment in a new draft")
  func staleDraftCompletionCannotMutateNewDraft() async throws {
    let model = await makeViewModel()
    defer { model.clearAll() }
    var item = savedItem().toMediaItem()
    item.isLoading = true
    model.mediaItems = [item]
    let staleContext = model.mediaLoadContext()
    model.clearAll()
    model.mediaItems = [item]

    model.finishMediaLoad(withId: item.id, context: staleContext)

    #expect(model.mediaItems.first?.id == item.id)
    #expect(model.mediaItems.first?.isLoading == true)
  }
}
