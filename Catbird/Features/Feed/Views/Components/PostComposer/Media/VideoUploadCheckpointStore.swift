import CryptoKit
import Foundation

/// Machine-local transfer identity. This metadata never goes into a remote draft or contains tokens.
struct VideoUploadOwner: Codable, Hashable, Sendable {
  let accountDID: String
  let draftID: String
  let entryID: String
  let mediaID: String
}

struct VideoUploadCheckpoint: Codable, Sendable {
  enum Phase: String, Codable, Sendable {
    case prepared, starting, startUncertain, uploading, finishing, processing, complete, abandoned, terminal
  }

  let operationID: UUID
  var runID: UUID
  let owner: VideoUploadOwner
  let snapshotName: String
  let sha256: String
  let sizeBytes: Int
  let mimeType: String
  var phase: Phase
  var uploadJobID: String?
  var partSizeBytes: Int?
  var partCount: Int?
  var expiresAt: Date?
  var completedJobID: String?
  var failureReason: String?
}

enum VideoUploadFileError: LocalizedError {
  case invalidSource, sourceChanged, snapshotChanged, ownerChanged, invalidCheckpoint, uploadAlreadyActive

  var errorDescription: String? {
    switch self {
    case .invalidSource: return "The prepared video is not available locally. Keep this attachment and try loading it again."
    case .sourceChanged: return "The video changed since this upload began. Start a new upload for the changed attachment."
    case .snapshotChanged: return "The saved upload file changed. The original attachment has been preserved."
    case .ownerChanged: return "This upload belongs to a different account or attachment."
    case .invalidCheckpoint: return "The saved video upload could not be recovered. The attachment has been preserved."
    case .uploadAlreadyActive: return "The previous video upload is still stopping. Your attachment is preserved; try again."
    }
  }
}

/// Disk work is actor-isolated off MainActor. Only disposable part files are removed; snapshots
/// and checkpoint history are retained so cancellation cannot destroy an attachment.
actor VideoUploadCheckpointStore {
  static let shared: Result<VideoUploadCheckpointStore, Error> = Result { try VideoUploadCheckpointStore() }
  private let rootURL: URL
  private let fileManager = FileManager.default
  private var activeLeases: [VideoUploadOwner: UUID] = [:]
  private var cleanupLeases: [VideoUploadOwner: UUID] = [:]

  init(rootURL: URL? = nil) throws {
    if let rootURL {
      self.rootURL = rootURL
    } else {
      self.rootURL = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Catbird/VideoUploads", isDirectory: true)
    }
    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
  }

  func prepare(
    sourceURL: URL, owner: VideoUploadOwner, mimeType: String, allowReplacementSource: Bool = false
  ) throws -> VideoUploadCheckpoint {
    try Task.checkCancellation()
    guard activeLeases[owner] == nil, cleanupLeases[owner] == nil else {
      throw VideoUploadFileError.uploadAlreadyActive
    }
    guard !owner.accountDID.isEmpty, !owner.draftID.isEmpty, !owner.entryID.isEmpty,
      !owner.mediaID.isEmpty, mimeType.count >= 3, mimeType.count <= 255
    else { throw VideoUploadFileError.invalidSource }
    let directory = try directory(for: owner)
    let existing = try load(owner: owner)
    let original = try fingerprint(sourceURL)
    if var existing {
      guard existing.owner == owner else { throw VideoUploadFileError.ownerChanged }
      if existing.sizeBytes == original.count, existing.sha256 == original.digest, existing.mimeType == mimeType {
        let snapshot = try fingerprint(try snapshotURL(for: existing))
        guard snapshot.count == existing.sizeBytes, snapshot.digest == existing.sha256
        else { throw VideoUploadFileError.snapshotChanged }
        try Task.checkCancellation()
        existing.runID = UUID()
        try write(existing)
        activeLeases[owner] = existing.runID
        return existing
      }
      guard allowReplacementSource else { throw VideoUploadFileError.sourceChanged }
      // Only a new user submit/retry can replace prepared bytes. Preserve the previous file and
      // reservation record; the changed bytes always get a separate snapshot and server session.
      try archive(existing)
    }

    let snapshotName = UUID().uuidString + ".video"
    let destination = directory.appendingPathComponent(snapshotName)
    // Copy in fixed-size buffers, also proving the exact bytes did not change during import.
    let copied = try copy(source: sourceURL, destination: destination, offset: 0, count: original.count)
    guard copied.digest == original.digest,
      try fingerprint(sourceURL).digest == original.digest
    else { throw VideoUploadFileError.sourceChanged }
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    let checkpoint = VideoUploadCheckpoint(
      operationID: UUID(), runID: UUID(), owner: owner, snapshotName: snapshotName,
      sha256: original.digest, sizeBytes: original.count, mimeType: mimeType, phase: .prepared
    )
    try write(checkpoint)
    activeLeases[owner] = checkpoint.runID
    return checkpoint
  }

  func load(owner: VideoUploadOwner) throws -> VideoUploadCheckpoint? {
    let url = try directory(for: owner).appendingPathComponent("checkpoint.json")
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let checkpoint = try JSONDecoder().decode(VideoUploadCheckpoint.self, from: Data(contentsOf: url))
    guard checkpoint.owner == owner else { throw VideoUploadFileError.ownerChanged }
    _ = try snapshotURL(for: checkpoint)
    return checkpoint
  }

  /// Compare operation IDs to keep a late abort/completion from overwriting a replacement run.
  func save(_ checkpoint: VideoUploadCheckpoint) throws {
    if let current = try load(owner: checkpoint.owner) {
      guard current.operationID == checkpoint.operationID, current.runID == checkpoint.runID else {
        throw VideoUploadFileError.ownerChanged
      }
    }
    try write(checkpoint)
  }

  /// Called only for a new, explicit submit/retry. Keep previous reservations and files recorded.
  func beginNewAttempt(from old: VideoUploadCheckpoint) throws -> VideoUploadCheckpoint {
    guard let current = try load(owner: old.owner), current.operationID == old.operationID,
      current.runID == old.runID else {
      throw VideoUploadFileError.ownerChanged
    }
    try archive(old)
    let replacement = VideoUploadCheckpoint(
      operationID: UUID(), runID: old.runID, owner: old.owner, snapshotName: old.snapshotName,
      sha256: old.sha256, sizeBytes: old.sizeBytes, mimeType: old.mimeType, phase: .prepared
    )
    try write(replacement)
    return replacement
  }

  func release(owner: VideoUploadOwner, runID: UUID) {
    if activeLeases[owner] == runID { activeLeases.removeValue(forKey: owner) }
  }

  func isCurrentLease(_ checkpoint: VideoUploadCheckpoint) -> Bool {
    guard let current = try? load(owner: checkpoint.owner) else { return false }
    return current.operationID == checkpoint.operationID && current.runID == checkpoint.runID
  }

  func beginCleanup(_ checkpoint: VideoUploadCheckpoint) -> Bool {
    guard isCurrentLease(checkpoint), cleanupLeases[checkpoint.owner] == nil else { return false }
    cleanupLeases[checkpoint.owner] = checkpoint.runID
    return true
  }

  func finishCleanup(owner: VideoUploadOwner, runID: UUID) {
    if cleanupLeases[owner] == runID { cleanupLeases.removeValue(forKey: owner) }
  }

  func makePart(checkpoint: VideoUploadCheckpoint, partNumber: Int, offset: Int64, count: Int) throws -> URL {
    try Task.checkCancellation()
    guard isCurrentLease(checkpoint), activeLeases[checkpoint.owner] == checkpoint.runID else {
      throw VideoUploadFileError.ownerChanged
    }
    guard offset >= 0, count > 0, offset <= Int64(checkpoint.sizeBytes),
      Int64(count) <= Int64(checkpoint.sizeBytes) - offset
    else { throw VideoUploadFileError.invalidCheckpoint }
    let snapshot = try snapshotURL(for: checkpoint)
    let parts = try directory(for: checkpoint.owner).appendingPathComponent("parts", isDirectory: true)
    try fileManager.createDirectory(at: parts, withIntermediateDirectories: true)
    let part = parts.appendingPathComponent("\(checkpoint.operationID)-\(partNumber)-\(UUID()).part")
    _ = try copy(source: snapshot, destination: part, offset: offset, count: count)
    return part
  }

  func removePart(_ url: URL, owner: VideoUploadOwner) throws {
    let parent = try directory(for: owner).appendingPathComponent("parts", isDirectory: true)
    guard url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
      url.pathExtension == "part"
    else { throw VideoUploadFileError.invalidCheckpoint }
    if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
  }

  private func write(_ checkpoint: VideoUploadCheckpoint) throws {
    _ = try snapshotURL(for: checkpoint)
    let target = try directory(for: checkpoint.owner).appendingPathComponent("checkpoint.json")
    try JSONEncoder().encode(checkpoint).write(to: target, options: .atomic)
  }

  private func archive(_ checkpoint: VideoUploadCheckpoint) throws {
    let history = try directory(for: checkpoint.owner).appendingPathComponent("history", isDirectory: true)
    try fileManager.createDirectory(at: history, withIntermediateDirectories: true)
    try JSONEncoder().encode(checkpoint).write(
      to: history.appendingPathComponent(checkpoint.operationID.uuidString + ".json"), options: .atomic
    )
  }

  private func directory(for owner: VideoUploadOwner) throws -> URL {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let key = SHA256.hash(data: try encoder.encode(owner)).map { String(format: "%02x", $0) }.joined()
    let directory = rootURL.appendingPathComponent(key, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func snapshotURL(for checkpoint: VideoUploadCheckpoint) throws -> URL {
    guard checkpoint.snapshotName == URL(fileURLWithPath: checkpoint.snapshotName).lastPathComponent,
      checkpoint.snapshotName.hasSuffix(".video"), checkpoint.sizeBytes > 0,
      checkpoint.sha256.count == 64
    else { throw VideoUploadFileError.invalidCheckpoint }
    return try directory(for: checkpoint.owner).appendingPathComponent(checkpoint.snapshotName)
  }

  private func fingerprint(_ url: URL) throws -> (count: Int, digest: String) {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .ubiquitousItemDownloadingStatusKey])
    guard values.isRegularFile == true, let size = values.fileSize, size > 0,
      values.ubiquitousItemDownloadingStatus != .notDownloaded
    else { throw VideoUploadFileError.invalidSource }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    var total = 0
    while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty {
      try Task.checkCancellation()
      let (next, overflow) = total.addingReportingOverflow(bytes.count)
      guard !overflow, next <= size else { throw VideoUploadFileError.sourceChanged }
      total = next
      hash.update(data: bytes)
    }
    guard total == size else { throw VideoUploadFileError.sourceChanged }
    return (total, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }

  private func copy(source: URL, destination: URL, offset: Int64, count: Int) throws -> (count: Int, digest: String) {
    let input = try FileHandle(forReadingFrom: source)
    defer { try? input.close() }
    guard fileManager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
    else { throw VideoUploadFileError.invalidSource }
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    try input.seek(toOffset: UInt64(offset))
    var remaining = count
    var hash = SHA256()
    while remaining > 0 {
      try Task.checkCancellation()
      guard let bytes = try input.read(upToCount: min(64 * 1024, remaining)), !bytes.isEmpty else {
        throw VideoUploadFileError.sourceChanged
      }
      try output.write(contentsOf: bytes)
      hash.update(data: bytes)
      remaining -= bytes.count
    }
    try output.synchronize()
    return (count, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
}
