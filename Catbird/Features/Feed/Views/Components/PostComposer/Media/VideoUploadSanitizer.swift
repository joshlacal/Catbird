import AVFoundation
import CoreMedia
import Foundation
import OSLog

// MARK: - Sanitized Copy

/// A copy of a video attachment that holds only its audio and video samples. It was read back
/// and found free of container and track metadata before it was handed out. Only
/// `VideoUploadSanitizer` makes one.
struct SanitizedVideo: Sendable, Equatable {
  let url: URL
  let mimeType: String
  let byteCount: Int

  fileprivate init(url: URL, mimeType: String, byteCount: Int) {
    self.url = url
    self.mimeType = mimeType
    self.byteCount = byteCount
  }
}

enum VideoUploadSanitizationError: LocalizedError, Equatable {
  case unreadable, exportFailed, metadataRemained, tooLarge, insufficientStorage

  var errorDescription: String? {
    switch self {
    case .unreadable:
      return "This video’s format isn’t supported for upload. Your attachment is still here."
    case .exportFailed:
      return "Couldn’t prepare your video for upload. Your attachment is still here; try again."
    case .metadataRemained:
      return "Couldn’t remove location and device details from this video, so it wasn’t uploaded. Your attachment is still here."
    case .tooLarge:
      return VideoUploadPolicy.sizeMessage
    case .insufficientStorage:
      return "There isn’t enough free space on this device to prepare your video for upload. Free up some space and try again. Your attachment is still here."
    }
  }
}

// MARK: - Sanitizer

/// Makes the copy of a video attachment that is uploaded instead of the attachment itself.
///
/// The copy is a passthrough remux: the attachment's compressed audio and video samples are
/// copied unchanged into a new movie that has no container or track metadata (QuickTime user
/// data, `mdta` keys such as location, make, model, software and creation date), no timed
/// metadata, text, timecode or other non-audio/video tracks, no boxes the parser does not
/// report, zeroed header times, and no vendor or compressor name in its sample descriptions.
/// The copy is read back before use and the upload fails closed if anything remains.
///
/// Copies are stored under the attachment's SHA-256, the format version and the copy's own
/// SHA-256. The remux is deterministic, so every attempt for the same attachment bytes gets the
/// identical file, even after a copy is made again, and a saved multipart session resumes.
actor VideoUploadSanitizer {
  static let shared: Result<VideoUploadSanitizer, Error> = Result { try VideoUploadSanitizer() }

  /// Raise whenever `remux`, `VideoUploadCopyStructure` or `verifyContainsOnlySamples` changes, so
  /// no copy made under an older rule is uploaded again. Copies named with another version are
  /// deleted when a sanitizer starts.
  static let formatVersion = 2

  /// Free space required beyond the size of the attachment before a copy is made: the new movie
  /// box and file-system overhead.
  static let exportHeadroomBytes: Int64 = 16 * 1_048_576

  /// How long an export may run before it is treated as stuck and cancelled. A passthrough remux
  /// only copies bytes; this allows the largest accepted attachment at 1 MB/s.
  static let exportTimeLimit: Duration = .seconds(300)

  static let logger = Logger(subsystem: "blue.catbird", category: "VideoUploadSanitizer")
  private let rootURL: URL
  private let partialDirectory: URL
  private let availableCapacity: @Sendable (URL) -> Int64?
  private let exportDeadline: @Sendable () async throws -> Void
  private let fileManager = FileManager.default
  /// Attachments and copies this process has already hashed or verified, by path, valid while
  /// the file is unchanged. A retry then reads neither file again.
  private var knownAttachments: [String: KnownAttachment] = [:]
  private var knownCopies: [String: KnownCopy] = [:]

  /// - Parameters:
  ///   - availableCapacity: Free bytes on the volume of the given directory, or nil when unknown.
  ///   - exportDeadline: Returns once an export has run for as long as it may.
  init(
    rootURL: URL? = nil,
    availableCapacity: @escaping @Sendable (URL) -> Int64? = { VideoUploadSanitizer.availableCapacity(at: $0) },
    exportDeadline: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: VideoUploadSanitizer.exportTimeLimit) }
  ) throws {
    if let rootURL {
      self.rootURL = rootURL
    } else {
      // The same volume as the checkpoint store, so its snapshot of a copy is an APFS clone.
      self.rootURL = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Catbird/VideoUploadCopies", isDirectory: true)
    }
    partialDirectory = self.rootURL.appendingPathComponent("Partial", isDirectory: true)
    self.availableCapacity = availableCapacity
    self.exportDeadline = exportDeadline
    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    // Exports interrupted by a kill are never referenced again, and none runs before init.
    if FileManager.default.fileExists(atPath: partialDirectory.path) {
      try FileManager.default.removeItem(at: partialDirectory)
    }
    try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
    try Self.removeCopies(madeUnderAnotherVersionIn: self.rootURL)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var root = self.rootURL
    try root.setResourceValues(values)
  }

  /// The metadata-free copy of `attachmentURL`, made on the first call for these bytes and
  /// reused afterwards. The attachment itself is only read.
  func sanitizedCopy(of attachmentURL: URL) async throws -> SanitizedVideo {
    try Task.checkCancellation()
    guard attachmentURL.isFileURL, let format = OutputFormat(attachmentURL) else {
      throw VideoUploadSanitizationError.unreadable
    }
    let source = try attachmentFingerprint(attachmentURL)
    let prefix = "\(source.digest)-v\(Self.formatVersion)-"
    if let known = knownCopy(prefix: prefix) { return known }
    if let cached = try await reusableCopy(prefix: prefix, format: format) {
      remember(cached, prefix: prefix)
      return cached
    }
    guard Self.hasRoom(forCopyOf: source.count, available: availableCapacity(rootURL)) else {
      throw VideoUploadSanitizationError.insufficientStorage
    }

    let partial = partialDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(format.pathExtension)
    defer { try? fileManager.removeItem(at: partial) }
    let clock = ContinuousClock()
    let started = clock.now
    let remuxed = try await Self.remux(attachmentURL, to: partial, fileType: format.fileType, deadline: exportDeadline)
    try VideoUploadCopyStructure.scrub(partial)
    try await Self.verifyContainsOnlySamples(partial)
    let written = try await Self.trackSignatures(of: partial)
    guard Self.keepsEveryTrack(inserted: remuxed.kept, written: written) else {
      // Passthrough left out a track it was given (for example an audio codec the container
      // can't carry). Uploading would silently lose that track.
      Self.logger.error(
        "Passthrough copy kept \(written.count) of \(remuxed.kept.count) audio/video track(s); not uploading"
      )
      throw VideoUploadSanitizationError.unreadable
    }
    let copy = try VideoUploadCheckpointStore.fingerprint(partial)
    try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: partial.path)
    try Task.checkCancellation()

    // No suspension point from here on: the directory check and the rename are one step.
    if let finished = finishedCopy(prefix: prefix, format: format) {
      // Another attempt for the same bytes finished first; its verified copy is used.
      remember(finished, prefix: prefix)
      return finished
    }
    let destination = rootURL.appendingPathComponent(prefix + copy.digest)
      .appendingPathExtension(format.pathExtension)
    try fileManager.moveItem(at: partial, to: destination)
    let elapsed = started.duration(to: clock.now).components
    let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    Self.logger.info(
      "Prepared metadata-free upload copy: \(copy.count) bytes, \(remuxed.dropped) non-audio/video track(s) dropped, \(milliseconds) ms"
    )
    let made = SanitizedVideo(url: destination, mimeType: format.mimeType, byteCount: copy.count)
    remember(made, prefix: prefix)
    return made
  }

  static func hasRoom(forCopyOf byteCount: Int, available: Int64?) -> Bool {
    guard let available else { return true }
    return available >= Int64(byteCount) + exportHeadroomBytes
  }

  static func availableCapacity(at url: URL) -> Int64? {
    try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage
  }

  /// Maps a failed export to the error shown to the user.
  static func exportFailure(_ error: Error) -> VideoUploadSanitizationError {
    var current: NSError? = error as NSError
    while let nsError = current {
      let outOfSpace =
        (nsError.domain == AVFoundationErrorDomain && nsError.code == AVError.Code.diskFull.rawValue)
        || (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError)
        || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC))
      if outOfSpace { return .insufficientStorage }
      current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return .exportFailed
  }

  /// The format version in a copy's name (`<attachment SHA-256>-v<version>-<copy SHA-256>.<ext>`),
  /// or nil for any other name.
  static func copyFormatVersion(of name: String) -> Int? {
    let stem = (name as NSString).deletingPathExtension
    let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 64, parts[2].count == 64,
      parts[0].allSatisfy(\.isHexDigit), parts[2].allSatisfy(\.isHexDigit),
      parts[1].first == "v", let version = Int(parts[1].dropFirst())
    else { return nil }
    return version
  }

  /// Deletes copies an older (or newer) rule made; they are never uploaded again. No checkpoint
  /// refers to a copy: the checkpoint store keeps its own snapshot.
  private static func removeCopies(madeUnderAnotherVersionIn root: URL) throws {
    for name in try FileManager.default.contentsOfDirectory(atPath: root.path) {
      guard let version = copyFormatVersion(of: name), version != formatVersion else { continue }
      try FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }
  }

  // MARK: - Known Files

  /// What tells a file apart from one that replaced or rewrote it. Read with `stat`, which
  /// caches nothing.
  private struct FileIdentity: Equatable {
    let device: UInt64
    let fileNumber: UInt64
    let size: UInt64
    let modified: Date

    init?(_ url: URL) {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
        let size = (attributes[.size] as? NSNumber)?.uint64Value,
        let modified = attributes[.modificationDate] as? Date
      else { return nil }
      (self.device, self.fileNumber, self.size, self.modified) = (device, fileNumber, size, modified)
    }
  }

  private struct KnownAttachment {
    let identity: FileIdentity
    let count: Int
    let digest: String
  }

  private struct KnownCopy {
    let identity: FileIdentity
    let copy: SanitizedVideo
  }

  /// The attachment's size and SHA-256, hashed once per unchanged file.
  private func attachmentFingerprint(_ url: URL) throws -> (count: Int, digest: String) {
    let identity = FileIdentity(url)
    if let identity, let known = knownAttachments[url.path], known.identity == identity {
      return (known.count, known.digest)
    }
    let fingerprint = try VideoUploadCheckpointStore.fingerprint(url)
    // Remembered only if nothing rewrote the file while it was hashed.
    if let identity, FileIdentity(url) == identity {
      knownAttachments[url.path] = KnownAttachment(identity: identity, count: fingerprint.count, digest: fingerprint.digest)
    }
    return fingerprint
  }

  /// A copy this process made or verified, if it is still the same file.
  private func knownCopy(prefix: String) -> SanitizedVideo? {
    guard let known = knownCopies[prefix] else { return nil }
    guard FileIdentity(known.copy.url) == known.identity else {
      knownCopies[prefix] = nil
      return nil
    }
    return known.copy
  }

  private func remember(_ copy: SanitizedVideo, prefix: String) {
    guard let identity = FileIdentity(copy.url) else { return }
    knownCopies[prefix] = KnownCopy(identity: identity, copy: copy)
  }

  // MARK: - Cached Copies

  private struct CachedCopy {
    let url: URL
    let digest: String
  }

  private func cachedCopies(prefix: String, format: OutputFormat) throws -> [CachedCopy] {
    let names = try fileManager.contentsOfDirectory(atPath: rootURL.path).sorted()
    let suffix = "." + format.pathExtension
    return names.compactMap { name in
      guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
      let digest = String(name.dropFirst(prefix.count).dropLast(suffix.count))
      guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { return nil }
      return CachedCopy(url: rootURL.appendingPathComponent(name), digest: digest)
    }
  }

  /// A cached copy whose bytes still match the digest in its name and that still reads back
  /// clean. A copy that is not is deleted so it is made again; the remux is deterministic, so the
  /// new copy has the same bytes and name. A copy that could not be read at all (for example
  /// while the device is locked) is kept, and the attempt fails so it can be retried.
  private func reusableCopy(prefix: String, format: OutputFormat) async throws -> SanitizedVideo? {
    for cached in try cachedCopies(prefix: prefix, format: format) {
      let current: (count: Int, digest: String)
      do {
        current = try VideoUploadCheckpointStore.fingerprint(cached.url)
      } catch is CancellationError {
        throw CancellationError()
      } catch is VideoUploadFileError {
        // Empty, not a regular file, or changing while read: not a copy this sanitizer left.
        discard(cached)
        continue
      } catch {
        Self.logger.error("Couldn’t read cached upload copy: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        throw VideoUploadSanitizationError.exportFailed
      }
      guard current.digest == cached.digest else {
        discard(cached)
        continue
      }
      do {
        try await Self.verifyContainsOnlySamples(cached.url)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        discard(cached)
        continue
      }
      return SanitizedVideo(url: cached.url, mimeType: format.mimeType, byteCount: current.count)
    }
    return nil
  }

  private func discard(_ cached: CachedCopy) {
    Self.logger.error("Discarding cached upload copy that no longer reads back clean")
    try? fileManager.removeItem(at: cached.url)
  }

  /// A copy moved into place by another attempt while this one was exporting. It was verified
  /// before it was moved, so only its bytes are checked.
  private func finishedCopy(prefix: String, format: OutputFormat) -> SanitizedVideo? {
    guard let copies = try? cachedCopies(prefix: prefix, format: format) else { return nil }
    for cached in copies {
      if let current = try? VideoUploadCheckpointStore.fingerprint(cached.url), current.digest == cached.digest {
        return SanitizedVideo(url: cached.url, mimeType: format.mimeType, byteCount: current.count)
      }
    }
    return nil
  }

  // MARK: - Output Format

  private struct OutputFormat {
    let fileType: AVFileType
    let pathExtension: String
    let mimeType: String

    /// Keeps the attachment's container: MPEG-4 for mp4/m4v, QuickTime otherwise.
    init?(_ url: URL) {
      switch VideoUploadPolicy.mimeType(for: url) {
      case "video/mp4"?:
        (fileType, pathExtension, mimeType) = (.mp4, "mp4", "video/mp4")
      case .some:
        (fileType, pathExtension, mimeType) = (.mov, "mov", "video/quicktime")
      case nil:
        return nil
      }
    }
  }
}

// MARK: - Upload Copies

extension VideoUploadSanitizer: VideoUploadCopyMaking {
  /// The metadata-free copy the multipart engine uploads in place of the attachment.
  func uploadCopy(of attachmentURL: URL) async throws -> VideoUploadCopy {
    let copy = try await sanitizedCopy(of: attachmentURL)
    guard Int64(copy.byteCount) <= VideoUploadPolicy.maximumBytes else {
      throw VideoUploadSanitizationError.tooLarge
    }
    return VideoUploadCopy(url: copy.url, mimeType: copy.mimeType)
  }
}
