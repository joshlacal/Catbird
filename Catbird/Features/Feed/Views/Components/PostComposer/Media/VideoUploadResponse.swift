import Foundation

/// The legacy upload guide returns a bare status; the lexicon specifies an envelope.
struct VideoUploadResponse<JobStatus: Decodable>: Decodable {
  let jobStatus: JobStatus

  private enum CodingKeys: String, CodingKey {
    case jobStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.jobStatus) {
      jobStatus = try container.decode(JobStatus.self, forKey: .jobStatus)
    } else {
      jobStatus = try JobStatus(from: decoder)
    }
  }
}

/// A returned blob is usable even when a reused job reports `already_exists`.
enum VideoProcessingOutcome<VideoBlob> {
  case complete(VideoBlob)
  case failed(String)
  case pending(progress: Double)

  static func resolve(
    state: String,
    progress: Int?,
    blob: VideoBlob?,
    error: String?,
    message: String?
  ) -> Self {
    if let blob {
      return .complete(blob)
    }

    switch state {
    case "JOB_STATE_COMPLETED":
      return .failed("Server reported success but provided no video data")
    case "JOB_STATE_FAILED":
      let reason = [message, error].compactMap { $0 }.first { !$0.isEmpty }
      return .failed(reason ?? "Video processing failed")
    default:
      return .pending(progress: min(1, max(0, Double(progress ?? 0) / 100)))
    }
  }
}
