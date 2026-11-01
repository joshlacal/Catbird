import CryptoKit
import Foundation
import OSLog

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

/// Disk work is actor-isolated off MainActor. A snapshot is the exact bytes a server session takes
/// parts from, so it exists only while a run or cleanup holds its owner's lease, or while its
/// checkpoint's session can still take parts (`keepsSnapshot`). A finished, failed, replaced or
/// expired checkpoint's snapshot is deleted; a later run on the same bytes clones it again from
/// its matching source. The attachment is never touched. Checkpoint and history JSON hold no
/// media and are retained. The root is excluded from device backups.
actor VideoUploadCheckpointStore {
  static let shared: Result<VideoUploadCheckpointStore, Error> = Result { try VideoUploadCheckpointStore() }
  /// Present once every snapshot under the root was cloned from a sanitized upload copy. Older
  /// snapshots can be raw clones of an attachment, with its location and device metadata, and no
  /// sanitized upload can resume from them, so the first store to open a root deletes them all.
  static let sanitizedSnapshotsMarker = ".sanitized-snapshots"
  private static let logger = Logger(subsystem: "blue.catbird", category: "VideoUploadCheckpointStore")
  private let rootURL: URL
  private let fileManager = FileManager.default
  private var activeLeases: [VideoUploadOwner: UUID] = [:]
  private var cleanupLeases: [VideoUploadOwner: UUID] = [:]

  /// Opens `shared` once, off the main thread. App launch calls this so an older build's raw
  /// snapshots are purged and the root is excluded from backups even if no composer ever holds a
  /// video again, and so that sweep never runs on the main thread. No run can hold a lease before
  /// `shared` exists, so the sweep is safe this early.
  @discardableResult
  static func openSharedInBackground() -> Task<Void, Never> {
    Task.detached(priority: .utility) {
      if case .failure(let error) = Self.shared {
        Self.logger.error("Couldn’t open the video upload store: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  /// The root `shared` opens.
  static func defaultRootURL() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Catbird/VideoUploads", isDirectory: true)
  }

  init(rootURL: URL? = nil) throws {
    self.rootURL = try rootURL ?? Self.defaultRootURL()
    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var root = self.rootURL
    try root.setResourceValues(values)
    // Only `shared` opens the production root, so no run holds a lease in it yet.
    Self.removeUnusedFiles(in: self.rootURL, now: Date())
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
    let original = try Self.fingerprint(sourceURL)
    if var existing {
      guard existing.owner == owner else { throw VideoUploadFileError.ownerChanged }
      if existing.sizeBytes == original.count, existing.sha256 == original.digest, existing.mimeType == mimeType {
        let snapshotFile = try snapshotURL(for: existing)
        if fileManager.fileExists(atPath: snapshotFile.path) {
          let snapshot = try Self.fingerprint(snapshotFile)
          guard snapshot.count == existing.sizeBytes, snapshot.digest == existing.sha256
          else { throw VideoUploadFileError.snapshotChanged }
        } else {
          // An earlier run's end deleted the snapshot; the matching source holds the same bytes.
          try cloneSnapshot(of: sourceURL, to: snapshotFile, matching: original)
        }
        try Task.checkCancellation()
        existing.runID = UUID()
        try write(existing)
        activeLeases[owner] = existing.runID
        // No earlier run still holds this owner: drop its leftover part files.
        Self.removeFiles(in: directory, keepingSnapshot: existing.snapshotName)
        return existing
      }
      guard allowReplacementSource else { throw VideoUploadFileError.sourceChanged }
      // Only a new user submit/retry can replace prepared bytes. The previous reservation record
      // stays in history; the changed bytes always get a separate snapshot and server session.
      try archive(existing)
    }

    let snapshotName = UUID().uuidString + ".video"
    let destination = directory.appendingPathComponent(snapshotName)
    try cloneSnapshot(of: sourceURL, to: destination, matching: original)
    let checkpoint = VideoUploadCheckpoint(
      operationID: UUID(), runID: UUID(), owner: owner, snapshotName: snapshotName,
      sha256: original.digest, sizeBytes: original.count, mimeType: mimeType, phase: .prepared
    )
    do {
      try write(checkpoint)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
    activeLeases[owner] = checkpoint.runID
    // No session can resume from a replaced checkpoint's bytes, and no run holds its parts.
    Self.removeFiles(in: directory, keepingSnapshot: snapshotName)
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

  /// Called only for a new, explicit submit/retry. The previous reservation stays recorded in
  /// history; the new attempt sends the same snapshot.
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
    guard activeLeases[owner] == runID else { return }
    activeLeases.removeValue(forKey: owner)
    removeUnusedFiles(owner: owner)
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
    guard cleanupLeases[owner] == runID else { return }
    cleanupLeases.removeValue(forKey: owner)
    removeUnusedFiles(owner: owner)
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

  /// Clones `source` (an APFS copy-on-write clone where the volume allows, P177) and makes the
  /// clone read-only. The clone is kept only when its bytes are exactly `expected`.
  private func cloneSnapshot(
    of source: URL, to destination: URL, matching expected: (count: Int, digest: String)
  ) throws {
    try fileManager.copyItem(at: source, to: destination)
    do {
      let copied = try Self.fingerprint(destination)
      guard copied.digest == expected.digest, copied.count == expected.count
      else { throw VideoUploadFileError.sourceChanged }
      try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }
  }

  /// Deletes the owner's part files, and its snapshot unless the checkpoint still needs it. Only
  /// once neither a run nor a cleanup holds the owner.
  private func removeUnusedFiles(owner: VideoUploadOwner) {
    guard activeLeases[owner] == nil, cleanupLeases[owner] == nil,
      let directory = try? directory(for: owner)
    else { return }
    let kept = (try? load(owner: owner)).flatMap { checkpoint in
      Self.keepsSnapshot(checkpoint, at: Date()) ? checkpoint.snapshotName : nil
    }
    Self.removeFiles(in: directory, keepingSnapshot: kept)
  }

  private func archive(_ checkpoint: VideoUploadCheckpoint) throws {
    let history = try directory(for: checkpoint.owner).appendingPathComponent("history", isDirectory: true)
    try fileManager.createDirectory(at: history, withIntermediateDirectories: true)
    try JSONEncoder().encode(checkpoint).write(
      to: history.appendingPathComponent(checkpoint.operationID.uuidString + ".json"), options: .atomic
    )
  }

  private func directory(for owner: VideoUploadOwner) throws -> URL {
    let directory = rootURL.appendingPathComponent(try Self.directoryName(for: owner), isDirectory: true)
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

  /// Size and SHA-256 of a local, fully downloaded file. Uses no actor state.
  static func fingerprint(_ url: URL) throws -> (count: Int, digest: String) {
    // A URL keeps the resource values it read; a file rewritten since must not report its old size.
    var url = url
    url.removeAllCachedResourceValues()
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

// MARK: - Snapshot Retention

extension VideoUploadCheckpointStore {
  /// Whether `checkpoint`'s server session can still take parts from its snapshot: an upload
  /// session that has not finished, failed or expired. Any other checkpoint's bytes are already
  /// on the service or go to a new session, which a later run clones again from its source.
  static func keepsSnapshot(_ checkpoint: VideoUploadCheckpoint, at now: Date) -> Bool {
    guard checkpoint.uploadJobID?.isEmpty == false, checkpoint.completedJobID == nil,
      let expiresAt = checkpoint.expiresAt, expiresAt > now
    else { return false }
    switch checkpoint.phase {
    case .uploading, .finishing, .abandoned: return true
    case .prepared, .starting, .startUncertain, .processing, .complete, .terminal: return false
    }
  }

  /// Startup sweep of a root no run is using: every part file, every snapshot no checkpoint
  /// references (including archived and legacy ones), and every referenced snapshot its
  /// checkpoint no longer needs. On the first open of a root without the marker, every snapshot.
  /// Best-effort: a file that cannot be removed now is tried again on the next open.
  private static func removeUnusedFiles(in root: URL, now: Date) {
    let fileManager = FileManager.default
    let marker = root.appendingPathComponent(sanitizedSnapshotsMarker)
    let purgeEverySnapshot = !fileManager.fileExists(atPath: marker.path)
    var removedAll = true
    let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for directory in entries where (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
      var kept: String?
      if !purgeEverySnapshot,
        let data = try? Data(contentsOf: directory.appendingPathComponent("checkpoint.json")),
        let checkpoint = try? JSONDecoder().decode(VideoUploadCheckpoint.self, from: data),
        (try? directoryName(for: checkpoint.owner)) == directory.lastPathComponent,
        keepsSnapshot(checkpoint, at: now) {
        kept = checkpoint.snapshotName
      }
      if !removeFiles(in: directory, keepingSnapshot: kept) { removedAll = false }
    }
    if purgeEverySnapshot, removedAll, !fileManager.createFile(atPath: marker.path, contents: nil) {
      logger.error("Couldn’t record the video upload snapshot sweep")
    }
  }

  /// Removes the directory's part files and every snapshot except `kept`; true when all are gone.
  @discardableResult
  private static func removeFiles(in directory: URL, keepingSnapshot kept: String?) -> Bool {
    let fileManager = FileManager.default
    let parts = directory.appendingPathComponent("parts", isDirectory: true)
    let snapshots = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".video") && $0 != kept }
      .map { directory.appendingPathComponent($0) }
    let partFiles = ((try? fileManager.contentsOfDirectory(atPath: parts.path)) ?? [])
      .filter { $0.hasSuffix(".part") }
      .map { parts.appendingPathComponent($0) }
    var removedAll = true
    for url in snapshots + partFiles {
      do {
        try fileManager.removeItem(at: url)
      } catch {
        removedAll = false
        logger.error("Couldn’t remove a video upload file: \(error.localizedDescription, privacy: .public)")
      }
    }
    return removedAll
  }

  private static func directoryName(for owner: VideoUploadOwner) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return SHA256.hash(data: try encoder.encode(owner)).map { String(format: "%02x", $0) }.joined()
  }
}
