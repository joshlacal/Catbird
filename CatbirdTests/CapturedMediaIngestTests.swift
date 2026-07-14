import Testing
import SwiftUI
import UIKit
import Petrel
@testable import Catbird

@MainActor
private func makeCapturedMediaTestAppState() async -> AppState {
  let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
  return AppState(userDID: "did:plc:test0000000000000000000001", client: client)
}

@Suite("Captured Media Ingest Tests")
struct CapturedMediaIngestTests {
  @MainActor
  @Test("Ingesting a captured photo adds one image media item")
  func ingestCapturedPhotoAddsImage() async throws {
    let appState = await makeCapturedMediaTestAppState()
    let viewModel = PostComposerViewModel(appState: appState)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let data = try #require(image.jpegData(compressionQuality: 0.9))

    viewModel.ingestCapturedPhoto(data)

    #expect(viewModel.mediaItems.count == 1)
    #expect(viewModel.mediaItems.first?.rawData == data)
    #expect(viewModel.mediaItems.first?.isLoading == false)
    #expect(viewModel.videoItem == nil)
  }

  @MainActor
  @Test("Ingesting a captured photo respects the image limit")
  func ingestCapturedPhotoRespectsLimit() async throws {
    let appState = await makeCapturedMediaTestAppState()
    let viewModel = PostComposerViewModel(appState: appState)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    let data = try #require(image.jpegData(compressionQuality: 0.9))

    for _ in 0..<(viewModel.maxImagesAllowed + 2) {
      viewModel.ingestCapturedPhoto(data)
    }

    #expect(viewModel.mediaItems.count == viewModel.maxImagesAllowed)
  }
}
