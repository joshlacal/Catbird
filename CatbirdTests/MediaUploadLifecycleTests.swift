import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Video upload terminal cleanup")
@MainActor
struct MediaUploadLifecycleTests {
  private func manager() async -> MediaUploadManager {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    return MediaUploadManager(client: client)
  }

  private var owner: VideoUploadOwner {
    VideoUploadOwner(accountDID: "did:plc:synthetic-upload-owner", draftID: UUID().uuidString,
      entryID: UUID().uuidString, mediaID: UUID().uuidString)
  }

  private var missingVideo: URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("missing-upload-\(UUID()).mp4")
  }

  @Test("Missing source reports a terminal failure and clears busy state before networking")
  func missingSourceSettlesUpload() async {
    let upload = await manager()
    do {
      _ = try await upload.uploadVideo(url: missingVideo, owner: owner, isOwnerCurrent: { true }, isAccountCurrent: { true })
      Issue.record("A missing source must fail before any upload")
    } catch {
      #expect(!upload.isVideoUploading)
      #expect(upload.uploadedBlob == nil)
      #expect(upload.videoJobId == nil)
      #expect(upload.videoError?.isEmpty == false)
      guard case .failed(let message) = upload.uploadStatus else {
        Issue.record("The failed operation must have a terminal status")
        return
      }
      #expect(!message.isEmpty)
    }
  }

  @Test("An already-cancelled caller cancels its owned operation and clears busy state")
  func callerCancellationSettlesUpload() async {
    let upload = await manager()
    let url = missingVideo
    let caller = Task { @MainActor in
      try await upload.uploadVideo(url: url, owner: owner, isOwnerCurrent: { true }, isAccountCurrent: { true })
    }
    caller.cancel()
    do {
      _ = try await caller.value
      Issue.record("A cancelled caller must not finish an upload")
    } catch is CancellationError {
      #expect(!upload.isVideoUploading)
      #expect(upload.uploadedBlob == nil)
      #expect(upload.videoError == nil)
      guard case .cancelled = upload.uploadStatus else {
        Issue.record("Cancellation must settle the upload status")
        return
      }
    } catch {
      Issue.record("Caller cancellation was replaced by a different error: \(error)")
    }
  }
}
