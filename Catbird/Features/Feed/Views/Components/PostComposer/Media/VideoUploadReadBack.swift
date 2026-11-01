import AVFoundation
import Foundation

// MARK: - Read-Back

extension VideoUploadSanitizer {
  /// Throws `.metadataRemained` unless the movie at `url` holds nothing but audio and video
  /// samples and the structure needed to play them, and `.unreadable` if it has no video track.
  ///
  /// Checks what AVFoundation reports (asset, common and per-format metadata, creation date, and
  /// the same for every track) and walks the boxes themselves, which also catches boxes
  /// AVFoundation does not report (`uuid`/XMP, unknown `meta`, non-empty `free` padding) and
  /// sample-description vendor and compressor names. The log names what was found, never a
  /// value, so a rule a new OS trips can be recognized from the field.
  static func verifyContainsOnlySamples(_ url: URL) async throws {
    let hasVideo: Bool
    do {
      hasVideo = try await reportsOnlySamples(AVURLAsset(url: url))
    } catch let error as VideoUploadSanitizationError {
      throw error
    } catch {
      try Task.checkCancellation()
      throw VideoUploadSanitizationError.unreadable
    }
    guard hasVideo else { throw VideoUploadSanitizationError.unreadable }
    if let finding = try VideoUploadCopyStructure.firstUnexpectedContent(in: url) {
      throw rejected(finding)
    }
  }

  /// Throws `.metadataRemained` if AVFoundation reports any metadata or a non-audio/video track;
  /// returns whether there is a video track.
  private static func reportsOnlySamples(_ asset: AVURLAsset) async throws -> Bool {
    try await rejectReportedItems(of: asset)
    var hasVideo = false
    for track in try await asset.load(.tracks) {
      guard track.mediaType == .video || track.mediaType == .audio else {
        throw rejected("\(track.mediaType.rawValue) track")
      }
      try await rejectReportedItems(of: track)
      hasVideo = hasVideo || track.mediaType == .video
    }
    return hasVideo
  }

  private static func rejectReportedItems(of asset: AVURLAsset) async throws {
    if let item = try await asset.load(.metadata).first { throw rejected("asset item", item) }
    if let item = try await asset.load(.commonMetadata).first { throw rejected("asset common item", item) }
    if try await asset.load(.creationDate) != nil { throw rejected("asset creation date") }
    for format in try await asset.load(.availableMetadataFormats) {
      if let item = try await asset.loadMetadata(for: format).first { throw rejected("asset \(format.rawValue) item", item) }
    }
  }

  private static func rejectReportedItems(of track: AVAssetTrack) async throws {
    if let item = try await track.load(.metadata).first { throw rejected("track item", item) }
    if let item = try await track.load(.commonMetadata).first { throw rejected("track common item", item) }
    for format in try await track.load(.availableMetadataFormats) {
      if let item = try await track.loadMetadata(for: format).first { throw rejected("track \(format.rawValue) item", item) }
    }
  }

  private static func rejected(_ finding: String, _ item: AVMetadataItem? = nil) -> VideoUploadSanitizationError {
    let key = item.map { " \($0.identifier?.rawValue ?? "unidentified")" } ?? ""
    logger.error("Upload copy read-back found \(finding, privacy: .public)\(key, privacy: .public)")
    return .metadataRemained
  }
}

// MARK: - Boxes

/// A box (atom) of an ISO base media or QuickTime file. Offsets are relative to the start of the
/// data or file that was walked.
struct ContainerBox: Sendable, Equatable {
  let type: String
  let offset: Int
  let headerSize: Int
  let size: Int

  var payloadRange: Range<Int> { (offset + headerSize)..<(offset + size) }
}

/// The single top-level movie box of a file, read into memory.
struct ContainerMovieBox {
  /// Where the box sits in the file.
  let box: ContainerBox
  /// The whole box, header included; zero-based.
  let data: Data

  /// The box's children, relative to `data`.
  var payloadRange: Range<Int> { box.headerSize..<box.size }
}

enum ContainerBoxReader {
  /// The largest movie box read into memory. A ten-minute 4K clip's is a few megabytes.
  static let maximumMovieBoxBytes = 64 * 1_048_576

  /// Boxes laid end to end in `range` of zero-based `data`, or nil when a size is malformed or
  /// runs past the range.
  static func boxes(in data: Data, range: Range<Int>) -> [ContainerBox]? {
    var boxes: [ContainerBox] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
      guard let box = box(in: data, at: offset, available: range.upperBound - offset) else { return nil }
      boxes.append(box)
      offset += box.size
    }
    return boxes
  }

  /// The first child of `container` with `type`.
  static func child(_ type: String, of container: ContainerBox, in data: Data) -> ContainerBox? {
    boxes(in: data, range: container.payloadRange)?.first { $0.type == type }
  }

  /// Top-level boxes of the file, read header by header so sample data is never loaded. Nil when
  /// a size is malformed.
  static func topLevelBoxes(of handle: FileHandle) throws -> [ContainerBox]? {
    let fileSize = Int(try handle.seekToEnd())
    var boxes: [ContainerBox] = []
    var offset = 0
    while offset < fileSize {
      try handle.seek(toOffset: UInt64(offset))
      let header = try handle.read(upToCount: 16) ?? Data()
      guard let box = box(in: header, at: 0, available: fileSize - offset) else { return nil }
      boxes.append(ContainerBox(type: box.type, offset: offset, headerSize: box.headerSize, size: box.size))
      offset += box.size
    }
    return boxes
  }

  /// The file's only moov box, or nil when there is not exactly one or it is implausibly large.
  static func movieBox(of handle: FileHandle) throws -> ContainerMovieBox? {
    guard let movies = try topLevelBoxes(of: handle)?.filter({ $0.type == "moov" }), movies.count == 1,
      let movie = movies.first, movie.size <= maximumMovieBoxBytes
    else { return nil }
    try handle.seek(toOffset: UInt64(movie.offset))
    guard let data = try handle.read(upToCount: movie.size), data.count == movie.size else { return nil }
    return ContainerMovieBox(box: movie, data: data)
  }

  /// Byte ranges, relative to `movie.data`, of the creation and modification times of every
  /// mvhd, tkhd and mdhd box. Nil when the boxes are malformed.
  static func headerTimeFields(in movie: ContainerMovieBox) -> [Range<Int>]? {
    let data = movie.data
    var fields: [Range<Int>] = []
    func collect(in range: Range<Int>) -> Bool {
      guard let children = boxes(in: data, range: range) else { return false }
      for child in children {
        switch child.type {
        case "trak", "mdia":
          guard collect(in: child.payloadRange) else { return false }
        case "mvhd", "tkhd", "mdhd":
          // Version 1 boxes hold 64-bit times; both follow the version and flags.
          let payload = child.payloadRange
          guard !payload.isEmpty else { return false }
          let width = data[payload.lowerBound] == 1 ? 8 : 4
          let creation = (payload.lowerBound + 4)..<(payload.lowerBound + 4 + width)
          let modification = creation.upperBound..<(creation.upperBound + width)
          guard modification.upperBound <= payload.upperBound else { return false }
          fields.append(creation)
          fields.append(modification)
        default:
          continue
        }
      }
      return true
    }
    return collect(in: movie.payloadRange) ? fields : nil
  }

  /// Byte ranges, relative to `movie.data`, of the vendor of every audio and video sample
  /// description and the compressor name of every video one. Cameras name themselves there
  /// ("GoPro AVC encoder", "DJI.AVC"), and a passthrough export copies both from the source. Nil
  /// when the boxes are malformed.
  static func sampleDescriptionFields(in movie: ContainerMovieBox) -> [Range<Int>]? {
    let data = movie.data
    guard let tracks = boxes(in: data, range: movie.payloadRange) else { return nil }
    var fields: [Range<Int>] = []
    for track in tracks where track.type == "trak" {
      guard let media = child("mdia", of: track, in: data), let handler = child("hdlr", of: media, in: data),
        handler.payloadRange.count >= 12
      else { return nil }
      // Version and flags, then the component type, then the handler type.
      let handlerStart = handler.payloadRange.lowerBound + 8
      let handlerType = String(bytes: data[handlerStart..<(handlerStart + 4)], encoding: .isoLatin1)
      // Only audio and video tracks reach a copy, and their descriptions are laid out by type.
      guard handlerType == "vide" || handlerType == "soun" else { continue }
      let isVideo = handlerType == "vide"
      guard let information = child("minf", of: media, in: data),
        let table = child("stbl", of: information, in: data),
        let descriptions = child("stsd", of: table, in: data), descriptions.payloadRange.count >= 8,
        let entries = boxes(
          in: data, range: (descriptions.payloadRange.lowerBound + 8)..<descriptions.payloadRange.upperBound
        )
      else { return nil }
      for entry in entries {
        // Reserved bytes, the data reference index, version and revision come before the vendor.
        // A video description's 32-byte compressor name follows its dimensions, resolution, data
        // size and frame count.
        let start = entry.payloadRange.lowerBound
        guard entry.payloadRange.count >= (isVideo ? 74 : 16) else { return nil }
        fields.append((start + 12)..<(start + 16))
        if isVideo { fields.append((start + 42)..<(start + 74)) }
      }
    }
    return fields
  }

  static func payloadIsZero(_ box: ContainerBox, in handle: FileHandle) throws -> Bool {
    try handle.seek(toOffset: UInt64(box.payloadRange.lowerBound))
    var remaining = box.payloadRange.count
    while remaining > 0 {
      try Task.checkCancellation()
      guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)), !chunk.isEmpty else { return false }
      guard chunk.allSatisfy({ $0 == 0 }) else { return false }
      remaining -= chunk.count
    }
    return true
  }

  /// The box whose header starts at `offset`. `available` is the number of bytes from there to
  /// the end of the enclosing box or file, which may be more than `data` holds.
  private static func box(in data: Data, at offset: Int, available: Int) -> ContainerBox? {
    let readable = min(available, data.count - offset)
    guard readable >= 8 else { return nil }
    let declared = uint32(data, at: offset)
    var size = Int(declared)
    var headerSize = 8
    if declared == 1 {
      guard readable >= 16 else { return nil }
      let large = uint64(data, at: offset + 8)
      guard large <= UInt64(available) else { return nil }
      size = Int(large)
      headerSize = 16
    } else if declared == 0 {
      size = available
    }
    guard size >= headerSize, size <= available else { return nil }
    let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .isoLatin1) ?? ""
    return ContainerBox(type: type, offset: offset, headerSize: headerSize, size: size)
  }

  private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
  }

  private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
    data[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
  }
}

// MARK: - Upload Copy Structure

/// The box layout of a metadata-free passthrough copy.
enum VideoUploadCopyStructure {
  /// `free` and `skip` are allowed only when they hold nothing but zero bytes.
  static let topLevelTypes: Set<String> = ["ftyp", "wide", "mdat", "moov", "free", "skip"]
  /// `udta` and `meta` are allowed only when they hold nothing but zero bytes.
  static let movieTypes: Set<String> = ["mvhd", "trak", "udta", "meta"]
  /// `tapt` holds the QuickTime clean, production and encoded aperture sizes.
  static let trackTypes: Set<String> = ["tkhd", "tapt", "edts", "mdia", "tref"]
  static let mediaTypes: Set<String> = ["mdhd", "hdlr", "minf", "elng"]

  /// Zeroes, in place, the creation and modification times in every mvhd, tkhd and mdhd box
  /// (an export sets them to when the copy was made) and the vendor and compressor name of every
  /// sample description (an export copies them from the source). No size or offset changes.
  static func scrub(_ url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    guard let movie = try ContainerBoxReader.movieBox(of: handle),
      let times = ContainerBoxReader.headerTimeFields(in: movie),
      let descriptions = ContainerBoxReader.sampleDescriptionFields(in: movie)
    else { throw VideoUploadSanitizationError.metadataRemained }
    for field in times + descriptions {
      try handle.seek(toOffset: UInt64(movie.box.offset + field.lowerBound))
      try handle.write(contentsOf: Data(count: field.count))
    }
    try handle.synchronize()
  }

  /// What, if anything, the file holds beyond the boxes above with all-zero padding and user
  /// data, zero header times and unnamed sample descriptions. Sample data and the sample tables
  /// themselves are not inspected. The answer names a box path or field, never a value.
  static func firstUnexpectedContent(in url: URL) throws -> String? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let topLevel = try ContainerBoxReader.topLevelBoxes(of: handle) else { return "malformed top-level box" }
    for box in topLevel {
      guard topLevelTypes.contains(box.type) else { return "top-level \(box.type) box" }
      if box.type == "free" || box.type == "skip" {
        guard try ContainerBoxReader.payloadIsZero(box, in: handle) else { return "non-empty top-level \(box.type) box" }
      }
    }
    guard let movie = try ContainerBoxReader.movieBox(of: handle) else { return "no single movie box" }
    guard let times = ContainerBoxReader.headerTimeFields(in: movie) else { return "malformed movie header" }
    guard times.allSatisfy({ isZero(movie.data[$0]) }) else { return "header creation or modification time" }
    guard let descriptions = ContainerBoxReader.sampleDescriptionFields(in: movie) else {
      return "malformed sample description"
    }
    guard descriptions.allSatisfy({ isZero(movie.data[$0]) }) else { return "sample description vendor or compressor name" }
    return unexpectedMovieContent(movie)
  }

  private static func unexpectedMovieContent(_ movie: ContainerMovieBox) -> String? {
    let data = movie.data
    guard let children = ContainerBoxReader.boxes(in: data, range: movie.payloadRange) else { return "malformed moov" }
    guard children.contains(where: { $0.type == "trak" }) else { return "movie without tracks" }
    for child in children {
      switch child.type {
      case "udta", "meta":
        guard isZero(data[child.payloadRange]) else { return "non-empty moov/\(child.type)" }
      case "trak":
        if let finding = unexpectedContent(in: child, of: data, allowed: trackTypes, path: "moov/trak") { return finding }
      default:
        guard movieTypes.contains(child.type) else { return "moov/\(child.type)" }
      }
    }
    return nil
  }

  private static func unexpectedContent(
    in container: ContainerBox, of data: Data, allowed: Set<String>, path: String
  ) -> String? {
    guard let children = ContainerBoxReader.boxes(in: data, range: container.payloadRange) else { return "malformed \(path)" }
    for child in children {
      guard allowed.contains(child.type) else { return "\(path)/\(child.type)" }
      if child.type == "mdia",
        let finding = unexpectedContent(in: child, of: data, allowed: mediaTypes, path: "\(path)/mdia") {
        return finding
      }
    }
    return nil
  }

  private static func isZero(_ bytes: Data) -> Bool {
    bytes.allSatisfy { $0 == 0 }
  }
}
