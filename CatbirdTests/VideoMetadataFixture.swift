import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Movies that carry identifying metadata at every level cameras and editors write it, for the
/// upload metadata tests. Every value is a marker string that can be searched for in bytes.
enum VideoMetadataFixture {
  enum Container: String, CaseIterable, Sendable {
    case quickTime, mpeg4

    var fileType: AVFileType { self == .quickTime ? .mov : .mp4 }
    var pathExtension: String { self == .quickTime ? "mov" : "mp4" }
    var mimeType: String { self == .quickTime ? "video/quicktime" : "video/mp4" }
    /// The format AVFoundation reports QuickTime-style or ISO user data under.
    var userDataFormat: AVMetadataFormat { self == .quickTime ? .quickTimeUserData : .isoUserData }
  }

  /// How the fixture's video is encoded.
  enum Codec: String, CaseIterable, Sendable {
    case h264
    /// HEVC Main 10 tagged BT.2020 with the HLG transfer function: how iPhones record HDR video.
    case hevcHLG

    var mediaSubType: FourCharCode { self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC }

    fileprivate var pixelFormat: OSType {
      self == .h264 ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    fileprivate var outputSettings: [String: Any] {
      switch self {
      case .h264:
        return [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
      case .hevcHLG:
        return [
          AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
          ],
          AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String],
        ]
      }
    }
  }

  /// Where the fixture's 90° rotation is written. Cameras use the track header; some editors
  /// write only the movie header.
  enum RotationPlacement: Sendable {
    case trackHeader, movieHeader
  }

  struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
  }

  /// 2015-06-01T12:00:00Z, written into every mvhd, tkhd and mdhd box.
  static let captureDate = Date(timeIntervalSince1970: 1_433_160_000)
  static var captureStamp: UInt64 { UInt64(captureDate.timeIntervalSince1970) + 2_082_844_800 }
  static let rotation = CGAffineTransform(rotationAngle: .pi / 2)
  static let frameCount = 10
  static let framesPerSecond: Int32 = 10
  static let width = 64
  static let height = 48

  static let assetLocation = "+37.3349-122.0090+010.000/"
  static let userDataLocation = "+48.8584+002.2945/"
  static let trackLocation = "+51.5007-000.1246/"
  static let trackUserDataLocation = "+40.6892-074.0445/"
  static let timedLocation = "+35.6586+139.7454/"
  /// Written into the video sample description, where action cameras and drones name themselves
  /// ("GoPro AVC encoder", "DJI.AVC").
  static let compressorName = "CBFX-compressor"
  static let videoVendor = "CBVV"
  static let audioVendor = "CBVA"
  static let unreportedMarkers = ["CBFX-XMP-LAT", "CBFX-XMP-MODEL", "CBFX-TRAILER"]

  /// Every identifying value written by `make`, in either container.
  static func markers(for container: Container) -> [String] {
    var markers = [
      assetLocation, "CBFX-mdta-make", "CBFX-mdta-model", "CBFX-mdta-software", "2015-06-01T12:00:00+0000",
      userDataLocation, "CBFX-udta-make", "CBFX-udta-model", "2015-06-02T08:30:00Z",
      "CBFX-itunes-tool", "CBFX-3gp-author",
      trackLocation, "CBFX-track-mdta-model", trackUserDataLocation,
      compressorName, videoVendor, audioVendor,
    ]
    if container == .quickTime { markers.append(timedLocation) }
    return markers
  }

  /// A 64×48 movie rotated 90° with a mono AAC track and metadata in the movie, in the video
  /// track, in the sample descriptions and (QuickTime only) in a timed metadata track. Video
  /// frames are filled with `seed + frame`, so different seeds give different bytes. Header times
  /// are the capture date. `frames` at 10 fps sets the length; audio covers the same time.
  static func make(
    _ container: Container, codec: Codec = .h264, seed: UInt8 = 0x40, frames: Int = frameCount,
    disabledFallbackAudio: Bool = false, rotationPlacement: RotationPlacement = .trackHeader
  ) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-metadata-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("attachment").appendingPathExtension(container.pathExtension)
    let options = WriteOptions(
      fileType: container.fileType, codec: codec, seed: seed, frames: frames, timedMetadata: container == .quickTime,
      disabledFallbackAudio: disabledFallbackAudio, trackTransform: rotationPlacement == .trackHeader ? rotation : .identity
    )
    try await write(to: url, options)
    var data = try Data(contentsOf: url)
    if container == .mpeg4 {
      // The MPEG-4 writer keeps only the items it has ISO boxes for. Phones and editors also
      // write QuickTime user data and mdta keys into MP4 files, so carry the QuickTime twin's.
      let twin = folder.appendingPathComponent("twin.mov")
      var twinOptions = options
      (twinOptions.fileType, twinOptions.frames, twinOptions.timedMetadata, twinOptions.disabledFallbackAudio) = (.mov, frameCount, false, false)
      try await write(to: twin, twinOptions)
      data = try mergeQuickTimeMetadata(from: Data(contentsOf: twin), into: data)
      try FileManager.default.removeItem(at: twin)
    }
    try nameSampleDescriptions(&data)
    if rotationPlacement == .movieHeader { try setMovieMatrix(&data, to: rotation) }
    try stampHeaderTimes(&data, seconds1904: captureStamp)
    try data.write(to: url)
    return url
  }

  /// Appends a top-level XMP `uuid` box and a `free` box holding text, neither of which
  /// AVFoundation reports.
  static func appendUnreportedBoxes(to url: URL) throws {
    var data = try Data(contentsOf: url)
    let xmpUUID = UUID(uuidString: "BE7ACFCB-97A9-42E8-9C71-999491E3AFAC")!
    var uuidPayload = withUnsafeBytes(of: xmpUUID.uuid) { Data($0) }
    uuidPayload.append(Data(#"<x:xmpmeta><rdf:Description exif:GPSLatitude="CBFX-XMP-LAT" tiff:Model="CBFX-XMP-MODEL"/></x:xmpmeta>"#.utf8))
    data.append(box("uuid", uuidPayload))
    data.append(box("free", Data("CBFX-TRAILER".utf8)))
    try data.write(to: url)
  }

  // MARK: - Boxes

  struct Box {
    let type: String
    let start: Int
    let headerSize: Int
    let end: Int
    var payload: Range<Int> { (start + headerSize)..<end }
  }

  static func children(_ data: Data, _ range: Range<Int>) throws -> [Box] {
    var boxes: [Box] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
      guard range.upperBound - offset >= 8 else { throw FixtureError("truncated box header at \(offset)") }
      var size = Int(readInteger(data, at: offset, width: 4))
      var header = 8
      if size == 1 {
        size = Int(readInteger(data, at: offset + 8, width: 8))
        header = 16
      } else if size == 0 {
        size = range.upperBound - offset
      }
      guard size >= header, offset + size <= range.upperBound else { throw FixtureError("bad box size at \(offset)") }
      boxes.append(Box(type: String(decoding: data[offset + 4..<offset + 8], as: UTF8.self),
                       start: offset, headerSize: header, end: offset + size))
      offset += size
    }
    return boxes
  }

  static func box(_ type: String, _ payload: Data) -> Data {
    var data = Data()
    let size = UInt32(8 + payload.count)
    data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
    data.append(Data(type.utf8))
    data.append(payload)
    return data
  }

  /// The first child of `range` with each type in turn: `path(data, range, "trak", "mdia")`.
  static func path(_ data: Data, _ range: Range<Int>, _ types: String...) throws -> Box? {
    var current: Box?
    var search = range
    for type in types {
      guard let next = try children(data, search).first(where: { $0.type == type }) else { return nil }
      current = next
      search = next.payload
    }
    return current
  }

  /// Creation and modification times of every mvhd, tkhd and mdhd box.
  static func headerTimes(in data: Data) throws -> [UInt64] {
    try headerTimeFields(in: data).map { readInteger(data, at: $0.offset, width: $0.width) }
  }

  static func stampHeaderTimes(_ data: inout Data, seconds1904: UInt64) throws {
    for field in try headerTimeFields(in: data) {
      writeInteger(&data, seconds1904, at: field.offset, width: field.width)
    }
  }

  /// Writes `transform` into the mvhd matrix, leaving every track header as it is.
  static func setMovieMatrix(_ data: inout Data, to transform: CGAffineTransform) throws {
    guard let mvhd = try path(data, 0..<data.count, "moov", "mvhd") else { throw FixtureError("no mvhd") }
    // Version, flags, two times, timescale, duration, rate, volume and reserved come first.
    let start = mvhd.payload.lowerBound + (data[mvhd.payload.lowerBound] == 1 ? 48 : 36)
    func fixed(_ value: CGFloat) -> UInt64 { UInt64(UInt32(bitPattern: Int32((value * 65_536).rounded()))) }
    let matrix = [fixed(transform.a), fixed(transform.b), 0, fixed(transform.c), fixed(transform.d), 0,
                  fixed(transform.tx), fixed(transform.ty), 1 << 30]
    for (index, value) in matrix.enumerated() { writeInteger(&data, value, at: start + 4 * index, width: 4) }
  }

  /// Vendor and compressor name of every sample description, as (handler type, vendor, name).
  static func sampleDescriptionFields(in data: Data) throws -> [(handler: String, vendor: String, compressorName: String)] {
    try sampleEntries(in: data).map { entry in
      let vendor = String(decoding: data[entry.vendor], as: UTF8.self)
      let name = entry.compressorName.map { range -> String in
        let length = Int(data[range.lowerBound])
        return String(decoding: data[(range.lowerBound + 1)..<(range.lowerBound + 1 + min(length, 31))], as: UTF8.self)
      } ?? ""
      return (entry.handler, vendor, name)
    }
  }

  private static func headerTimeFields(in data: Data) throws -> [(offset: Int, width: Int)] {
    var fields: [(offset: Int, width: Int)] = []
    func walk(_ range: Range<Int>) throws {
      for child in try children(data, range) {
        switch child.type {
        case "moov", "trak", "mdia":
          try walk(child.payload)
        case "mvhd", "tkhd", "mdhd":
          let payload = child.payload.lowerBound
          let width = data[payload] == 1 ? 8 : 4
          fields.append((payload + 4, width))
          fields.append((payload + 4 + width, width))
        default:
          continue
        }
      }
    }
    try walk(0..<data.count)
    guard !fields.isEmpty else { throw FixtureError("no header times found") }
    return fields
  }

  /// Every audio and video sample description: where its vendor and (video only) compressor
  /// name are.
  private static func sampleEntries(in data: Data) throws -> [(handler: String, vendor: Range<Int>, compressorName: Range<Int>?)] {
    guard let moov = try path(data, 0..<data.count, "moov") else { throw FixtureError("no moov") }
    var entries: [(handler: String, vendor: Range<Int>, compressorName: Range<Int>?)] = []
    for trak in try children(data, moov.payload) where trak.type == "trak" {
      guard let hdlr = try path(data, trak.payload, "mdia", "hdlr"),
        let stsd = try path(data, trak.payload, "mdia", "minf", "stbl", "stsd")
      else { continue }
      let handler = String(decoding: data[(hdlr.payload.lowerBound + 8)..<(hdlr.payload.lowerBound + 12)], as: UTF8.self)
      guard handler == "vide" || handler == "soun" else { continue }
      // Version, flags and entry count, then one box per sample description.
      for entry in try children(data, (stsd.payload.lowerBound + 8)..<stsd.payload.upperBound) {
        let fields = entry.payload.lowerBound
        let vendor = (fields + 12)..<(fields + 16)
        entries.append((handler, vendor, handler == "vide" ? (fields + 42)..<(fields + 74) : nil))
      }
    }
    guard !entries.isEmpty else { throw FixtureError("no sample descriptions") }
    return entries
  }

  /// Names the video encoder and both vendors the way third-party cameras do.
  static func nameSampleDescriptions(_ data: inout Data) throws {
    for entry in try sampleEntries(in: data) {
      data.replaceSubrange(entry.vendor, with: Data((entry.handler == "vide" ? videoVendor : audioVendor).utf8))
      if let name = entry.compressorName {
        var field = Data([UInt8(compressorName.utf8.count)]) + Data(compressorName.utf8)
        field.append(Data(count: name.count - field.count))
        data.replaceSubrange(name, with: field)
      }
    }
  }

  private static func readInteger(_ data: Data, at offset: Int, width: Int) -> UInt64 {
    data[offset..<offset + width].reduce(0) { $0 << 8 | UInt64($1) }
  }

  private static func writeInteger(_ data: inout Data, _ value: UInt64, at offset: Int, width: Int) {
    for index in 0..<width {
      data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(width - 1 - index)))
    }
  }

  /// Adds the twin's movie and video-track `udta` items and `meta` boxes to `target`. Its movie box
  /// is last, after the sample data, so no chunk offset moves.
  private static func mergeQuickTimeMetadata(from twin: Data, into target: Data) throws -> Data {
    func movie(_ data: Data) throws -> Box {
      guard let moov = try children(data, 0..<data.count).last, moov.type == "moov" else {
        throw FixtureError("movie box is not last")
      }
      return moov
    }
    func extras(_ data: Data, in container: Box) throws -> (userData: Data, meta: [Data]) {
      let boxes = try children(data, container.payload)
      var userData = Data()
      for box in boxes where box.type == "udta" { userData.append(data[box.payload]) }
      return (userData, boxes.filter { $0.type == "meta" }.map { Data(data[$0.start..<$0.end]) })
    }
    func rebuilt(_ data: Data, _ container: Box, adding added: (userData: Data, meta: [Data]),
                 transformTrack: ((Box) throws -> Data)?) throws -> Data {
      var payload = Data()
      var mergedUserData = false
      var transformed = false
      for child in try children(data, container.payload) {
        if child.type == "udta" {
          payload.append(box("udta", Data(data[child.payload]) + added.userData))
          mergedUserData = true
        } else if child.type == "trak", !transformed, let transformTrack {
          payload.append(try transformTrack(child))
          transformed = true
        } else {
          payload.append(data[child.start..<child.end])
        }
      }
      if !mergedUserData, !added.userData.isEmpty { payload.append(box("udta", added.userData)) }
      added.meta.forEach { payload.append($0) }
      return box(container.type, payload)
    }

    let twinMovie = try movie(twin)
    guard let twinVideo = try children(twin, twinMovie.payload).first(where: { $0.type == "trak" }) else {
      throw FixtureError("twin has no track")
    }
    let movieExtras = try extras(twin, in: twinMovie)
    let trackExtras = try extras(twin, in: twinVideo)
    let targetMovie = try movie(target)
    let movieBox = try rebuilt(target, targetMovie, adding: movieExtras) { track in
      try rebuilt(target, track, adding: trackExtras, transformTrack: nil)
    }
    return Data(target[0..<targetMovie.start]) + movieBox
  }

  // MARK: - Writing

  private struct WriteOptions {
    var fileType: AVFileType
    var codec: Codec
    var seed: UInt8
    var frames: Int
    var timedMetadata: Bool
    var disabledFallbackAudio: Bool
    var trackTransform: CGAffineTransform
  }

  private static func item(_ identifier: AVMetadataIdentifier, _ value: String, location: Bool = false) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    if location { item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String }
    return item
  }

  private static func write(to url: URL, _ options: WriteOptions) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: options.fileType)
    writer.metadata = [
      item(.quickTimeMetadataLocationISO6709, assetLocation, location: true),
      item(.quickTimeMetadataMake, "CBFX-mdta-make"),
      item(.quickTimeMetadataModel, "CBFX-mdta-model"),
      item(.quickTimeMetadataSoftware, "CBFX-mdta-software"),
      item(.quickTimeMetadataCreationDate, "2015-06-01T12:00:00+0000"),
      item(.quickTimeUserDataLocationISO6709, userDataLocation),
      item(.quickTimeUserDataMake, "CBFX-udta-make"),
      item(.quickTimeUserDataModel, "CBFX-udta-model"),
      item(.quickTimeUserDataCreationDate, "2015-06-02T08:30:00Z"),
      item(.iTunesMetadataEncodingTool, "CBFX-itunes-tool"),
      item(.identifier3GPUserDataAuthor, "CBFX-3gp-author"),
    ]

    let video = AVAssetWriterInput(mediaType: .video, outputSettings: options.codec.outputSettings)
    video.expectsMediaDataInRealTime = false
    video.transform = options.trackTransform
    video.metadata = [
      item(.quickTimeMetadataLocationISO6709, trackLocation, location: true),
      item(.quickTimeMetadataModel, "CBFX-track-mdta-model"),
      item(.quickTimeUserDataLocationISO6709, trackUserDataLocation),
    ]
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: options.codec.pixelFormat,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(video)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    var audioInputs: [AVAssetWriterInput] = []
    for index in 0..<(options.disabledFallbackAudio ? 2 : 1) {
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audio.expectsMediaDataInRealTime = false
      audio.marksOutputTrackAsEnabled = index == 0
      writer.add(audio)
      audioInputs.append(audio)
    }
    // 1024-frame AAC packets covering the video's length.
    let audioChunks = Int((Double(options.frames) / Double(framesPerSecond) * 44_100 / 1_024).rounded(.down))

    var timed: AVAssetWriterInputMetadataAdaptor?
    if options.timedMetadata {
      var description: CMFormatDescription?
      let specifications: [[String: Any]] = [[
        kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
          AVMetadataIdentifier.quickTimeMetadataLocationISO6709.rawValue,
        kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
          kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String,
      ]]
      let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
        allocator: nil, metadataType: kCMMetadataFormatType_Boxed,
        metadataSpecifications: specifications as CFArray, formatDescriptionOut: &description
      )
      guard status == noErr, let description else { throw FixtureError("timed metadata format \(status)") }
      let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
      input.expectsMediaDataInRealTime = false
      input.addTrackAssociation(withTrackOf: video, type: AVAssetTrack.AssociationType.metadataReferent.rawValue)
      writer.add(input)
      timed = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
    }

    guard writer.startWriting() else { throw FixtureError("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    guard let pool = pixels.pixelBufferPool else { throw FixtureError("no pixel buffer pool") }
    var frame = 0
    var chunks = Array(repeating: 0, count: audioInputs.count)
    var timedDone = timed == nil
    // Inputs are interleaved: a writer that is not fed in real time waits for every track.
    while frame < options.frames || chunks.contains(where: { $0 < audioChunks }) || !timedDone {
      var appended = false
      if frame < options.frames, video.isReadyForMoreMediaData {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw FixtureError("no pixel buffer") }
        fill(buffer, with: Int32(options.seed) + Int32(frame % 64))
        guard pixels.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
          throw FixtureError("video append: \(String(describing: writer.error))")
        }
        frame += 1
        if frame == options.frames { video.markAsFinished() }
        appended = true
      }
      for (index, audio) in audioInputs.enumerated() where chunks[index] < audioChunks && audio.isReadyForMoreMediaData {
        let buffer = try silence(frames: 1024, startingAt: Int64(chunks[index]) * 1024)
        guard audio.append(buffer) else { throw FixtureError("audio append: \(String(describing: writer.error))") }
        chunks[index] += 1
        if chunks[index] == audioChunks { audio.markAsFinished() }
        appended = true
      }
      if !timedDone, let timed, timed.assetWriterInput.isReadyForMoreMediaData {
        let group = AVTimedMetadataGroup(
          items: [item(.quickTimeMetadataLocationISO6709, timedLocation, location: true)],
          timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        )
        guard timed.append(group) else { throw FixtureError("timed metadata append: \(String(describing: writer.error))") }
        timed.assetWriterInput.markAsFinished()
        timedDone = true
        appended = true
      }
      if !appended { try await Task.sleep(for: .milliseconds(5)) }
    }
    await writer.finishWriting()
    guard writer.status == .completed else { throw FixtureError("finishWriting: \(String(describing: writer.error))") }
  }

  /// Sets every byte of every plane, so frames made with different values encode differently.
  private static func fill(_ buffer: CVPixelBuffer, with value: Int32) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard CVPixelBufferIsPlanar(buffer) else {
      memset(CVPixelBufferGetBaseAddress(buffer), value, CVPixelBufferGetDataSize(buffer))
      return
    }
    for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
      let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
      memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), value, bytes)
    }
  }

  /// Silent 44.1 kHz mono 16-bit PCM for the AAC encoder.
  private static func silence(frames: Int, startingAt start: Int64) throws -> CMSampleBuffer {
    var description = AudioStreamBasicDescription(
      mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
      mBitsPerChannel: 16, mReserved: 0
    )
    var format: CMAudioFormatDescription?
    var status = CMAudioFormatDescriptionCreate(
      allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &format
    )
    guard status == noErr, let format else { throw FixtureError("audio format \(status)") }
    let length = frames * 2
    var block: CMBlockBuffer?
    status = CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil,
      offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
    )
    guard status == noErr, let block else { throw FixtureError("audio block \(status)") }
    status = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
    guard status == noErr else { throw FixtureError("audio fill \(status)") }
    var sample: CMSampleBuffer?
    status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
      allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
      presentationTimeStamp: CMTime(value: start, timescale: 44_100), packetDescriptions: nil, sampleBufferOut: &sample
    )
    guard status == noErr, let sample else { throw FixtureError("audio sample \(status)") }
    return sample
  }
}
