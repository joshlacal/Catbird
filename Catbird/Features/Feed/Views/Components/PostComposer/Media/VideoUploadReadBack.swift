import AVFoundation
import Foundation

// MARK: - Read-Back

extension VideoUploadSanitizer {
  /// Throws `.metadataRemained` unless the movie at `url` holds nothing but audio and video
  /// samples and the structure needed to play them, and `.unreadable` if it has no video track.
  ///
  /// Checks what AVFoundation reports (asset, common and per-format metadata, creation date, and
  /// the same for every track) and walks the boxes themselves, which also catches boxes
  /// AVFoundation does not report (`uuid`/XMP, unknown `meta`, non-empty `free` padding).
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
    guard try VideoUploadCopyStructure.holdsOnlySampleBoxes(url) else {
      throw VideoUploadSanitizationError.metadataRemained
    }
  }

  /// Throws `.metadataRemained` if AVFoundation reports any metadata or a non-audio/video track;
  /// returns whether there is a video track.
  private static func reportsOnlySamples(_ asset: AVURLAsset) async throws -> Bool {
    guard try await asset.load(.metadata).isEmpty, try await asset.load(.commonMetadata).isEmpty,
      try await asset.load(.creationDate) == nil
    else { throw VideoUploadSanitizationError.metadataRemained }
    for format in try await asset.load(.availableMetadataFormats) {
      guard try await asset.loadMetadata(for: format).isEmpty else { throw VideoUploadSanitizationError.metadataRemained }
    }
    var hasVideo = false
    for track in try await asset.load(.tracks) {
      guard track.mediaType == .video || track.mediaType == .audio,
        try await track.load(.metadata).isEmpty, try await track.load(.commonMetadata).isEmpty
      else { throw VideoUploadSanitizationError.metadataRemained }
      for format in try await track.load(.availableMetadataFormats) {
        guard try await track.loadMetadata(for: format).isEmpty else { throw VideoUploadSanitizationError.metadataRemained }
      }
      hasVideo = hasVideo || track.mediaType == .video
    }
    return hasVideo
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

  /// Zeroes the creation and modification times in every mvhd, tkhd and mdhd box, which an
  /// export sets to when the copy was made.
  static func scrubHeaderTimes(in url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    guard let movie = try ContainerBoxReader.movieBox(of: handle),
      let fields = ContainerBoxReader.headerTimeFields(in: movie)
    else { throw VideoUploadSanitizationError.metadataRemained }
    for field in fields {
      try handle.seek(toOffset: UInt64(movie.box.offset + field.lowerBound))
      try handle.write(contentsOf: Data(count: field.count))
    }
    try handle.synchronize()
  }

  /// Whether the file is made only of the boxes above, with all-zero padding and user data and
  /// zero header times. Sample data and sample tables are not inspected.
  static func holdsOnlySampleBoxes(_ url: URL) throws -> Bool {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let topLevel = try ContainerBoxReader.topLevelBoxes(of: handle) else { return false }
    for box in topLevel {
      guard topLevelTypes.contains(box.type) else { return false }
      if box.type == "free" || box.type == "skip" {
        guard try ContainerBoxReader.payloadIsZero(box, in: handle) else { return false }
      }
    }
    guard let movie = try ContainerBoxReader.movieBox(of: handle),
      let fields = ContainerBoxReader.headerTimeFields(in: movie),
      fields.allSatisfy({ movie.data[$0].allSatisfy { $0 == 0 } })
    else { return false }
    return movieHoldsOnlySampleBoxes(movie)
  }

  private static func movieHoldsOnlySampleBoxes(_ movie: ContainerMovieBox) -> Bool {
    let data = movie.data
    guard let children = ContainerBoxReader.boxes(in: data, range: movie.payloadRange),
      children.contains(where: { $0.type == "trak" })
    else { return false }
    return children.allSatisfy { child in
      switch child.type {
      case "udta", "meta":
        return data[child.payloadRange].allSatisfy { $0 == 0 }
      case "trak":
        return holdsOnly(trackTypes, in: child, of: data)
      default:
        return movieTypes.contains(child.type)
      }
    }
  }

  private static func holdsOnly(_ allowed: Set<String>, in container: ContainerBox, of data: Data) -> Bool {
    guard let children = ContainerBoxReader.boxes(in: data, range: container.payloadRange) else { return false }
    return children.allSatisfy { child in
      allowed.contains(child.type) && (child.type != "mdia" || holdsOnly(mediaTypes, in: child, of: data))
    }
  }
}
