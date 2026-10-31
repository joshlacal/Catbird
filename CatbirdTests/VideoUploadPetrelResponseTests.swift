import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Video responses with Petrel models")
struct VideoUploadPetrelResponseTests {
  @Test(arguments: [false, true], ["JOB_STATE_COMPLETED", "JOB_STATE_FAILED"])
  func decodesImmediateBlobThroughPinnedSDK(wrapped: Bool, state: String) throws {
    let payload: [String: Any] = [
      "jobId": "synthetic-job",
      "did": "did:plc:z72i7hdynmk6r22z27h6tvur",
      "state": state,
      "error": "already_exists",
      "blob": [
        "$type": "blob",
        "ref": ["$link": "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"],
        "mimeType": "video/mp4",
        "size": 42,
      ],
    ]
    let response: [String: Any] = wrapped ? ["jobStatus": payload] : payload
    let data = try JSONSerialization.data(withJSONObject: response)
    let status: AppBskyVideoDefs.JobStatus = try JSONDecoder().decode(
      VideoUploadResponse<AppBskyVideoDefs.JobStatus>.self, from: data
    ).jobStatus

    #expect(status.jobId == "synthetic-job")
    let outcome: VideoProcessingOutcome<Blob> = VideoProcessingOutcome.resolve(
      state: status.state, progress: status.progress, blob: status.blob,
      error: status.error, message: status.message
    )
    guard case .complete(let blob) = outcome else {
      Issue.record("The pinned SDK should decode and preserve the reusable blob")
      return
    }
    #expect(blob.mimeType == "video/mp4")
    #expect(blob.size == 42)
  }
}
