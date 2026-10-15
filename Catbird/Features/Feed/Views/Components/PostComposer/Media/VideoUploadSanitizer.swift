import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Petrel

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
/// report, and zeroed header times. The copy is read back before use and the upload fails
/// closed if anything remains.
///
/// Copies are stored under the attachment's SHA-256, the format version and the copy's own
/// SHA-256, so every attempt for the same attachment bytes gets the identical file and a saved
/// multipart session resumes.
actor VideoUploadSanitizer {
  static let shared: Result<VideoUploadSanitizer, Error> = Result { try VideoUploadSanitizer() }

  /// Raise whenever `remux`, `VideoUploadCopyStructure` or `verifyContainsOnlySamples` changes, so
  /// no copy made under an older rule is uploaded again.
  static let formatVersion = 1

  /// Free space required beyond the size of the attachment before a copy is made: the new movie
  /// box and file-system overhead.
  static let exportHeadroomBytes: Int64 = 16 * 1_048_576

  private static let logger = Logger(subsystem: "blue.catbird", category: "VideoUploadSanitizer")
  private let rootURL: URL
  private let partialDirectory: URL
  private let availableCapacity: @Sendable (URL) -> Int64?
  private let fileManager = FileManager.default

  /// - Parameter availableCapacity: Free bytes on the volume of the given directory, or nil when
  ///   unknown.
  init(
    rootURL: URL? = nil,
    availableCapacity: @escaping @Sendable (URL) -> Int64? = { VideoUploadSanitizer.availableCapacity(at: $0) }
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
    try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    // Exports interrupted by a kill are never referenced again, and none runs before init.
    if FileManager.default.fileExists(atPath: partialDirectory.path) {
      try FileManager.default.removeItem(at: partialDirectory)
    }
    try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
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
    let source = try VideoUploadCheckpointStore.fingerprint(attachmentURL)
    let prefix = "\(source.digest)-v\(Self.formatVersion)-"
    if let cached = try await reusableCopy(prefix: prefix, format: format) { return cached }
    guard Self.hasRoom(forCopyOf: source.count, available: availableCapacity(rootURL)) else {
      throw VideoUploadSanitizationError.insufficientStorage
    }

    let partial = partialDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(format.pathExtension)
    defer { try? fileManager.removeItem(at: partial) }
    let clock = ContinuousClock()
    let started = clock.now
    let remuxed = try await Self.remux(attachmentURL, to: partial, fileType: format.fileType)
    try VideoUploadCopyStructure.scrubHeaderTimes(in: partial)
    try await Self.verifyContainsOnlySamples(partial)
    let written = try await Self.trackSignatures(of: partial)
    guard written.sorted() == remuxed.kept.sorted() else {
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
    return SanitizedVideo(url: destination, mimeType: format.mimeType, byteCount: copy.count)
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
  /// clean. Anything else is deleted so the copy is made again.
  private func reusableCopy(prefix: String, format: OutputFormat) async throws -> SanitizedVideo? {
    for cached in try cachedCopies(prefix: prefix, format: format) {
      do {
        let current = try VideoUploadCheckpointStore.fingerprint(cached.url)
        guard current.digest == cached.digest else { throw VideoUploadFileError.snapshotChanged }
        try await Self.verifyContainsOnlySamples(cached.url)
        return SanitizedVideo(url: cached.url, mimeType: format.mimeType, byteCount: current.count)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Self.logger.error("Discarding cached upload copy that no longer reads back clean")
        try? fileManager.removeItem(at: cached.url)
      }
    }
    return nil
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

  // MARK: - Remux

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

  private struct TrackSignature: Hashable, Comparable {
    let mediaType: String
    let isEnabled: Bool

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.mediaType, lhs.isEnabled ? 1 : 0) < (rhs.mediaType, rhs.isEnabled ? 1 : 0)
    }
  }

  private struct RemuxResult {
    let kept: [TrackSignature]
    let dropped: Int
  }

  /// Copies only the audio and video tracks into a composition and exports it without
  /// re-encoding. The composition carries no metadata of its own.
  private static func remux(_ sourceURL: URL, to outputURL: URL, fileType: AVFileType) async throws -> RemuxResult {
    let composition = AVMutableComposition()
    let result = try await copyTracks(of: AVURLAsset(
      url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
    ), into: composition)
    guard result.kept.contains(where: { $0.mediaType == AVMediaType.video.rawValue }) else {
      throw VideoUploadSanitizationError.unreadable
    }
    guard await AVAssetExportSession.compatibility(
      ofExportPreset: AVAssetExportPresetPassthrough, with: composition, outputFileType: fileType
    ), let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
    else { throw VideoUploadSanitizationError.unreadable }
    session.metadata = []
    // Defense in depth: the composition carries no metadata, and `.forSharing()` alone would
    // keep copyright and commercial items and timed metadata tracks.
    session.metadataItemFilter = .forSharing()
    do {
      try await session.export(to: outputURL, as: fileType)
    } catch {
      try Task.checkCancellation()
      let nsError = error as NSError
      logger.error("Passthrough export failed: \(nsError.domain, privacy: .public) \(nsError.code)")
      throw exportFailure(error)
    }
    return result
  }

  private static func copyTracks(of asset: AVURLAsset, into composition: AVMutableComposition) async throws -> RemuxResult {
    var kept: [TrackSignature] = []
    var dropped = 0
    do {
      for track in try await asset.load(.tracks) {
        // Timed metadata (still-image time, detected faces, timed location), text, subtitles,
        // closed captions, timecode, haptics and depth are dropped. Captions are uploaded
        // separately as WebVTT.
        guard track.mediaType == .video || track.mediaType == .audio else {
          dropped += 1
          continue
        }
        let (timeRange, transform, isEnabled) = try await track.load(.timeRange, .preferredTransform, .isEnabled)
        let (languageCode, extendedLanguageTag, naturalTimeScale, preferredVolume) = try await track.load(
          .languageCode, .extendedLanguageTag, .naturalTimeScale, .preferredVolume
        )
        guard timeRange.duration.isNumeric, timeRange.duration > .zero else {
          dropped += 1
          continue
        }
        guard let copy = composition.addMutableTrack(
          withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { throw VideoUploadSanitizationError.unreadable }
        try copy.insertTimeRange(timeRange, of: track, at: timeRange.start)
        // Track metadata is never copied; composition tracks have none.
        copy.preferredTransform = transform
        copy.isEnabled = isEnabled
        copy.languageCode = languageCode
        copy.extendedLanguageTag = extendedLanguageTag
        copy.naturalTimeScale = naturalTimeScale
        copy.preferredVolume = preferredVolume
        kept.append(TrackSignature(mediaType: track.mediaType.rawValue, isEnabled: isEnabled))
      }
    } catch let error as VideoUploadSanitizationError {
      throw error
    } catch {
      try Task.checkCancellation()
      throw VideoUploadSanitizationError.unreadable
    }
    return RemuxResult(kept: kept, dropped: dropped)
  }

  private static func trackSignatures(of url: URL) async throws -> [TrackSignature] {
    do {
      var signatures: [TrackSignature] = []
      for track in try await AVURLAsset(url: url).load(.tracks) {
        signatures.append(TrackSignature(mediaType: track.mediaType.rawValue, isEnabled: try await track.load(.isEnabled)))
      }
      return signatures
    } catch {
      try Task.checkCancellation()
      throw VideoUploadSanitizationError.unreadable
    }
  }
}

// MARK: - Multipart Upload

extension VideoMultipartUpload {
  /// Uploads the metadata-free copy of the attachment; the attachment's own bytes are never read
  /// by the transport. A retry finds the same copy, so the saved session resumes.
  func run(
    attachmentURL: URL,
    sanitizer: VideoUploadSanitizer,
    owner: VideoUploadOwner,
    durationMilliseconds: Int? = nil,
    allowNewSessionAfterTerminal: Bool = false,
    progress: @escaping @Sendable (VideoMultipartProgress) async -> Void,
    isOwnerCurrent: @escaping @Sendable () async -> Bool,
    canAuthorizeCleanup: (@Sendable () async -> Bool)? = nil,
    authorizeNewSession: @Sendable () async throws -> Void = {}
  ) async throws -> Blob {
    try Task.checkCancellation()
    // A removed attachment or switched account never starts a full-file remux.
    guard await isOwnerCurrent() else { throw VideoMultipartError.ownerChanged }
    await progress(.init(phase: .preparing, fraction: 0))
    let copy = try await sanitizer.sanitizedCopy(of: attachmentURL)
    guard Int64(copy.byteCount) <= VideoUploadPolicy.maximumBytes else {
      throw VideoUploadSanitizationError.tooLarge
    }
    return try await run(
      sourceURL: copy.url, owner: owner, mimeType: copy.mimeType,
      durationMilliseconds: durationMilliseconds,
      allowNewSessionAfterTerminal: allowNewSessionAfterTerminal,
      progress: progress, isOwnerCurrent: isOwnerCurrent,
      canAuthorizeCleanup: canAuthorizeCleanup, authorizeNewSession: authorizeNewSession
    )
  }
}
