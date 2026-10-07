import Foundation
import Testing
@testable import Catbird

@Suite("Legacy video upload responses")
struct VideoUploadResponseTests {
  private struct Status: Decodable {
    let jobId: String
    let state: String
    let progress: Int?
    let blob: String?
    let error: String?
    let message: String?

    var outcome: VideoProcessingOutcome<String> {
      VideoProcessingOutcome.resolve(
        state: state, progress: progress, blob: blob, error: error, message: message
      )
    }
  }

  private func decode(_ json: String) throws -> Status {
    try JSONDecoder().decode(VideoUploadResponse<Status>.self, from: Data(json.utf8)).jobStatus
  }

  @Test func acceptsBareUploadStatus() throws {
    let status = try decode(#"{"jobId":"job-1","state":"JOB_STATE_PROCESSING","progress":20}"#)
    #expect(status.jobId == "job-1")
    guard case .pending(let progress) = status.outcome else {
      Issue.record("Expected processing status")
      return
    }
    #expect(progress == 0.2)
  }

  @Test func acceptsLexiconEnvelope() throws {
    let status = try decode(#"{"jobStatus":{"jobId":"job-1","state":"JOB_STATE_COMPLETED","blob":"uploaded"}}"#)
    guard case .complete(let blob) = status.outcome else {
      Issue.record("Expected the immediate uploaded blob")
      return
    }
    #expect(blob == "uploaded")
  }

  @Test(arguments: ["JOB_STATE_COMPLETED", "JOB_STATE_FAILED", "JOB_STATE_PROCESSING", "future-state"])
  func blobTakesPrecedenceOverState(state: String) {
    let outcome = VideoProcessingOutcome.resolve(
      state: state, progress: nil, blob: "existing-blob", error: "already_exists", message: nil
    )
    guard case .complete(let blob) = outcome else {
      Issue.record("A returned blob must be reusable regardless of state")
      return
    }
    #expect(blob == "existing-blob")
  }

  @Test func failedAlreadyExistingUploadWithBlobSucceeds() throws {
    let status = try decode(#"{"jobId":"existing-job","state":"JOB_STATE_FAILED","error":"already_exists","blob":"existing-blob"}"#)
    guard case .complete(let blob) = status.outcome else {
      Issue.record("Expected the already-existing blob")
      return
    }
    #expect(blob == "existing-blob")
  }

  @Test func completedWithoutBlobIsTerminalFailure() throws {
    let status = try decode(#"{"jobStatus":{"jobId":"job-1","state":"JOB_STATE_COMPLETED"}}"#)
    guard case .failed = status.outcome else {
      Issue.record("Completed status without a blob must stop polling")
      return
    }
  }

  @Test func serverFailurePreservesReason() throws {
    let status = try decode(#"{"jobStatus":{"jobId":"job-1","state":"JOB_STATE_FAILED","error":"invalid_video","message":"The video could not be decoded"}}"#)
    guard case .failed(let reason) = status.outcome else {
      Issue.record("Processing failure must stop polling")
      return
    }
    #expect(reason == "The video could not be decoded")
  }

  @Test func emptyMessageUsesError() throws {
    let status = try decode(#"{"jobId":"job-1","state":"JOB_STATE_FAILED","error":"invalid_video","message":""}"#)
    guard case .failed(let reason) = status.outcome else {
      Issue.record("Expected failure")
      return
    }
    #expect(reason == "invalid_video")
  }

  @Test func unknownStateRemainsPendingForBoundedPolling() throws {
    let status = try decode(#"{"jobId":"job-1","state":"future-state"}"#)
    guard case .pending(let progress) = status.outcome else {
      Issue.record("Unknown states should remain pending")
      return
    }
    #expect(progress == 0)
  }

  @Test(arguments: [-50, 150])
  func clampsProgress(progress: Int) {
    let outcome: VideoProcessingOutcome<String> = .resolve(
      state: "JOB_STATE_PROCESSING", progress: progress, blob: nil, error: nil, message: nil
    )
    guard case .pending(let fraction) = outcome else {
      Issue.record("Expected pending outcome")
      return
    }
    #expect(fraction == (progress < 0 ? 0 : 1))
  }

  @Test(arguments: [
    #"{"jobStatus":null,"jobId":"job-1","state":"JOB_STATE_COMPLETED","blob":"ignored"}"#,
    #"{"jobStatus":{"state":"JOB_STATE_PROCESSING"}}"#,
    #"{"message":"unrelated response"}"#,
  ])
  func rejectsMalformedStatuses(json: String) {
    #expect(throws: (any Error).self) { try decode(json) }
  }
}
