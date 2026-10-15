import AVFoundation
import CoreMedia
import Foundation

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
  static let audioChunks = 43

  static let assetLocation = "+37.3349-122.0090+010.000/"
  static let userDataLocation = "+48.8584+002.2945/"
  static let trackLocation = "+51.5007-000.1246/"
  static let trackUserDataLocation = "+40.6892-074.0445/"
  static let timedLocation = "+35.6586+139.7454/"
  static let unreportedMarkers = ["CBFX-XMP-LAT", "CBFX-XMP-MODEL", "CBFX-TRAILER"]

  /// Every identifying value written by `make`, in either container.
  static func markers(for container: Container) -> [String] {
    var markers = [
      assetLocation, "CBFX-mdta-make", "CBFX-mdta-model", "CBFX-mdta-software", "2015-06-01T12:00:00+0000",
      userDataLocation, "CBFX-udta-make", "CBFX-udta-model", "2015-06-02T08:30:00Z",
      "CBFX-itunes-tool", "CBFX-3gp-author",
      trackLocation, "CBFX-track-mdta-model", trackUserDataLocation,
    ]
    if container == .quickTime { markers.append(timedLocation) }
    return markers
  }

  /// A 1 s, 64×48 H.264 movie rotated 90° with a mono AAC track and metadata in the movie, in the
  /// video track and (QuickTime only) in a timed metadata track. Video frames are filled with
  /// `seed + frame`, so different seeds give different bytes. Header times are the capture date.
  static func make(_ container: Container, seed: UInt8 = 0x40, disabledFallbackAudio: Bool = false) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-metadata-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("attachment").appendingPathExtension(container.pathExtension)
    try await write(to: url, fileType: container.fileType, seed: seed, timedMetadata: container == .quickTime,
                    disabledFallbackAudio: disabledFallbackAudio)
    var data = try Data(contentsOf: url)
    if container == .mpeg4 {
      // The MPEG-4 writer keeps only the items it has ISO boxes for. Phones and editors also
      // write QuickTime user data and mdta keys into MP4 files, so carry the QuickTime twin's.
      let twin = folder.appendingPathComponent("twin.mov")
      try await write(to: twin, fileType: .mov, seed: seed, timedMetadata: false, disabledFallbackAudio: false)
      data = try mergeQuickTimeMetadata(from: Data(contentsOf: twin), into: data)
      try FileManager.default.removeItem(at: twin)
    }
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

  /// Creation and modification times of every mvhd, tkhd and mdhd box.
  static func headerTimes(in data: Data) throws -> [UInt64] {
    try headerTimeFields(in: data).map { readInteger(data, at: $0.offset, width: $0.width) }
  }

  static func stampHeaderTimes(_ data: inout Data, seconds1904: UInt64) throws {
    for field in try headerTimeFields(in: data) {
      for index in 0..<field.width {
        data[field.offset + index] = UInt8(truncatingIfNeeded: seconds1904 >> (8 * UInt64(field.width - 1 - index)))
      }
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

  private static func readInteger(_ data: Data, at offset: Int, width: Int) -> UInt64 {
    data[offset..<offset + width].reduce(0) { $0 << 8 | UInt64($1) }
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

  private static func item(_ identifier: AVMetadataIdentifier, _ value: String, location: Bool = false) -> AVMutableMetadataItem {
    let item = AVMutableMetadataItem()
    item.identifier = identifier
    item.value = value as NSString
    if location { item.dataType = kCMMetadataDataType_QuickTimeMetadataLocation_ISO6709 as String }
    return item
  }

  private static func write(
    to url: URL, fileType: AVFileType, seed: UInt8, timedMetadata: Bool, disabledFallbackAudio: Bool
  ) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
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

    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
    ])
    video.expectsMediaDataInRealTime = false
    video.transform = rotation
    video.metadata = [
      item(.quickTimeMetadataLocationISO6709, trackLocation, location: true),
      item(.quickTimeMetadataModel, "CBFX-track-mdta-model"),
      item(.quickTimeUserDataLocationISO6709, trackUserDataLocation),
    ]
    let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
    ])
    writer.add(video)

    let audioSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
    ]
    var audioInputs: [AVAssetWriterInput] = []
    for index in 0..<(disabledFallbackAudio ? 2 : 1) {
      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      audio.expectsMediaDataInRealTime = false
      audio.marksOutputTrackAsEnabled = index == 0
      writer.add(audio)
      audioInputs.append(audio)
    }

    var timed: AVAssetWriterInputMetadataAdaptor?
    if timedMetadata {
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
    while frame < frameCount || chunks.contains(where: { $0 < audioChunks }) || !timedDone {
      var appended = false
      if frame < frameCount, video.isReadyForMoreMediaData {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw FixtureError("no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(seed) + Int32(frame), CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard pixels.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: framesPerSecond)) else {
          throw FixtureError("video append: \(String(describing: writer.error))")
        }
        frame += 1
        if frame == frameCount { video.markAsFinished() }
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
