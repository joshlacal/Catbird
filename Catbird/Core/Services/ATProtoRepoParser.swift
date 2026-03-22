import Foundation
import OSLog
import Petrel

// MARK: - ATProtoRepoParser

/// Catbird-side wrapper around Petrel's `CARRepository` that produces SwiftData models.
///
/// Delegates all CAR parsing, MST traversal, and type decoding to Petrel.
/// Records arrive as `CARRepository.Record` with `ATProtocolValueContainer` values
/// that are already decoded into the correct generated types.
final class ATProtoRepoParser {

  // MARK: - Types

  struct ParseProgress {
    enum Phase: String {
      case parsing = "Parsing repository"
      case complete = "Complete"
    }

    var phase: Phase
    var recordsProcessed: Int = 0
  }

  // MARK: - Properties

  private let logger = Logger(subsystem: "blue.catbird", category: "ATProtoRepoParser")

  // MARK: - Public API

  func parseRepository(
    fileURL: URL,
    userDID: String,
    userHandle: String,
    backupRecordID: UUID,
    repositoryRecordID: UUID = UUID(),
    onProgress: ((ParseProgress) -> Void)? = nil,
    onRecord: @escaping (CARRepository.Record) throws -> Void
  ) throws -> RepositoryRecord {

    var progress = ParseProgress(phase: .parsing)
    onProgress?(progress)

    let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0

    let repositoryRecord = RepositoryRecord(
      id: repositoryRecordID,
      backupRecordID: backupRecordID,
      userDID: userDID,
      userHandle: userHandle,
      parsingStatus: .inProgress,
      originalCarSize: fileSize
    )

    var typeCounts: [String: Int] = [:]
    var decodedCount = 0
    var failedCount = 0

    let stats = try CARRepository.parse(fileURL: fileURL) { record in
      typeCounts[record.collection, default: 0] += 1

      if case .decodeError = record.value {
        failedCount += 1
      } else {
        decodedCount += 1
      }

      try onRecord(record)

      progress.recordsProcessed += 1
      if progress.recordsProcessed % 500 == 0 {
        onProgress?(progress)
      }
    }

    // Finalize
    progress.phase = .complete
    onProgress?(progress)

    repositoryRecord.totalRecordCount = stats.recordCount
    repositoryRecord.successfullyParsedCount = decodedCount
    repositoryRecord.failedParseCount = failedCount
    repositoryRecord.parsingConfidenceScore = stats.recordCount == 0 ? 0 : Double(decodedCount) / Double(stats.recordCount)
    repositoryRecord.postCount = typeCounts["app.bsky.feed.post"] ?? 0
    repositoryRecord.profileCount = typeCounts["app.bsky.actor.profile"] ?? 0
    repositoryRecord.connectionCount = (typeCounts["app.bsky.graph.follow"] ?? 0) + (typeCounts["app.bsky.graph.block"] ?? 0)

    let statsJSON: [String: Any] = [
      "decodedCount": decodedCount,
      "failedCount": failedCount,
      "typeCounts": typeCounts,
      "blockCount": stats.blockCount,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: statsJSON),
       let str = String(data: data, encoding: .utf8) {
      repositoryRecord.parsingStatistics = str
    }

    let summary = typeCounts.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
    logger.info("Parsing complete: \(decodedCount)/\(stats.recordCount) decoded. Types: \(summary)")

    return repositoryRecord
  }
}
