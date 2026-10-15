import AVFoundation
import CoreMedia
import Foundation

// MARK: - Remux

extension VideoUploadSanitizer {
  /// Whether the written copy has exactly the audio and video tracks that were put into the
  /// composition, each still enabled or disabled as it was.
  static func keepsEveryTrack(inserted: [TrackSignature], written: [TrackSignature]) -> Bool {
    inserted.sorted() == written.sorted()
  }

  struct TrackSignature: Hashable, Comparable, Sendable {
    let mediaType: String
    let isEnabled: Bool

    static func < (lhs: Self, rhs: Self) -> Bool {
      (lhs.mediaType, lhs.isEnabled ? 1 : 0) < (rhs.mediaType, rhs.isEnabled ? 1 : 0)
    }
  }

  struct RemuxResult: Sendable {
    let kept: [TrackSignature]
    let dropped: Int
  }

  /// Exports the copy, giving up with `.exportFailed` once `deadline` returns.
  static func remux(
    _ sourceURL: URL, to outputURL: URL, fileType: AVFileType,
    deadline: @escaping @Sendable () async throws -> Void
  ) async throws -> RemuxResult {
    try await withThrowingTaskGroup(of: RemuxResult?.self) { group in
      group.addTask { try await exportComposition(of: sourceURL, to: outputURL, fileType: fileType) }
      group.addTask {
        try await deadline()
        return nil
      }
      // The export still running when this returns or throws is cancelled and awaited, so it has
      // stopped writing before the partial file is removed.
      defer { group.cancelAll() }
      guard let result = try await group.next() ?? nil else {
        logger.error("Passthrough export ran past its time limit")
        throw VideoUploadSanitizationError.exportFailed
      }
      return result
    }
  }

  /// Copies only the audio and video tracks into a composition and exports it without
  /// re-encoding. The composition carries no metadata of its own.
  private static func exportComposition(of sourceURL: URL, to outputURL: URL, fileType: AVFileType) async throws -> RemuxResult {
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
      // Some editors write a rotation only in the movie header. The copy's movie header is the
      // identity, so the movie's transform is folded into every track's.
      let movieTransform = try await asset.load(.preferredTransform)
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
        copy.preferredTransform = transform.concatenating(movieTransform)
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

  static func trackSignatures(of url: URL) async throws -> [TrackSignature] {
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
