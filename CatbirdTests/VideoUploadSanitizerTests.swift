import AVFoundation
import CryptoKit
import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Video upload metadata stripping", .timeLimit(.minutes(1)))
struct VideoUploadSanitizerTests {
  typealias Fixture = VideoMetadataFixture
  typealias Container = VideoMetadataFixture.Container

  // MARK: - Positive Controls

  @Test("The fixture carries identifying metadata at every level", arguments: Container.allCases)
  func fixtureCarriesMetadataAtEveryLevel(container: Container) async throws {
    let fixture = try await Fixture.make(container)
    let bytes = try Data(contentsOf: fixture)
    for marker in Fixture.markers(for: container) {
      #expect(bytes.range(of: Data(marker.utf8)) != nil, "fixture bytes hold \(marker)")
    }
    let asset = AVURLAsset(url: fixture)
    #expect(try await !asset.loadMetadata(for: .quickTimeMetadata).isEmpty)
    #expect(try await !asset.loadMetadata(for: container.userDataFormat).isEmpty)
    #expect(try await asset.load(.creationDate) != nil)
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    #expect(try await !video.load(.metadata).isEmpty)
    if container == .quickTime {
      #expect(try await !asset.loadTracks(withMediaType: .metadata).isEmpty)
    }
    #expect(try Fixture.headerTimes(in: bytes).allSatisfy { $0 == Fixture.captureStamp })
  }

  // MARK: - Uploaded Bytes

  @Test("The bytes sent to the video service carry no identifying metadata", arguments: Container.allCases)
  func uploadedPartsCarryNoIdentifyingMetadata(container: Container) async throws {
    let fixture = try await Fixture.make(container)
    let original = try digest(of: fixture)
    let upload = try await uploadThroughComposerRoute(fixture)
    let uploaded = upload.bytes

    #expect(upload.blob == VideoMultipartUploadChecks.blob)
    let starts = await upload.transport.starts
    #expect(starts.count == 1)
    #expect(starts.first?.mimeType == container.mimeType)
    #expect(starts.first?.sizeBytes == uploaded.count)
    for marker in Fixture.markers(for: container) {
      #expect(uploaded.range(of: Data(marker.utf8)) == nil, "uploaded bytes hold \(marker)")
    }
    let readBack = try await expectNoMetadata(uploaded, container: container)
    // The export stamps when the copy was made; the copy says nothing about when it was shot.
    #expect(try Fixture.headerTimes(in: uploaded).allSatisfy { $0 == 0 })
    try await VideoUploadSanitizer.verifyContainsOnlySamples(readBack)
    #expect(try digest(of: fixture) == original, "the attachment itself is never rewritten")
  }

  @Test("Boxes AVFoundation does not report never reach the upload")
  func unreportedBoxesNeverReachTheUpload() async throws {
    let fixture = try await Fixture.make(.quickTime)
    try Fixture.appendUnreportedBoxes(to: fixture)
    #expect(try await AVURLAsset(url: fixture).load(.isPlayable))
    let dirty = try Data(contentsOf: fixture)
    for marker in Fixture.unreportedMarkers {
      #expect(dirty.range(of: Data(marker.utf8)) != nil, "fixture bytes hold \(marker)")
    }
    let uploaded = try await uploadThroughComposerRoute(fixture).bytes
    for marker in Fixture.unreportedMarkers + Fixture.markers(for: .quickTime) {
      #expect(uploaded.range(of: Data(marker.utf8)) == nil, "uploaded bytes hold \(marker)")
    }
  }

  // MARK: - Remux

  @Test("The copy is a passthrough remux of the audio and video samples", arguments: Container.allCases)
  func copyIsAPassthroughRemux(container: Container) async throws {
    let fixture = try await Fixture.make(container)
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    #expect(copy.mimeType == container.mimeType)
    #expect(copy.url.pathExtension == container.pathExtension)
    let source = AVURLAsset(url: fixture)
    let result = AVURLAsset(url: copy.url)
    try await expectSameVideo(source, result)
    try await expectSameAudio(source, result)
    let duration = try await result.load(.duration).seconds
    let sourceDuration = try await source.load(.duration).seconds
    #expect(abs(duration - sourceDuration) <= 1 / Double(Fixture.framesPerSecond))
    #expect(try await result.loadTracks(withMediaType: .metadata).isEmpty)
  }

  private func expectSameVideo(_ source: AVURLAsset, _ result: AVURLAsset) async throws {
    let sourceVideo = try #require(try await source.loadTracks(withMediaType: .video).first)
    let videos = try await result.loadTracks(withMediaType: .video)
    #expect(videos.count == 1)
    let video = try #require(videos.first)
    // tkhd stores the matrix in fixed point, so compare with what the fixture reads back as.
    let transform = try await video.load(.preferredTransform)
    let sourceTransform = try await sourceVideo.load(.preferredTransform)
    #expect(transform == sourceTransform)
    let size = try await video.load(.naturalSize)
    let sourceSize = try await sourceVideo.load(.naturalSize)
    #expect(size == sourceSize)
    let subType = try await mediaSubType(video)
    let sourceSubType = try await mediaSubType(sourceVideo)
    #expect(subType == sourceSubType)
    let sourceSamples = try await compressedSamples(of: sourceVideo, in: source)
    let copiedSamples = try await compressedSamples(of: video, in: result)
    #expect(sourceSamples.count == Fixture.frameCount)
    let sourceTimes: [CMTime] = sourceSamples.map { $0.time }
    let copiedTimes: [CMTime] = copiedSamples.map { $0.time }
    #expect(copiedTimes == sourceTimes)
    let sourceBytes: [Data] = sourceSamples.map { $0.bytes }
    let copiedBytes: [Data] = copiedSamples.map { $0.bytes }
    #expect(copiedBytes == sourceBytes, "video samples are copied unchanged")
  }

  private func expectSameAudio(_ source: AVURLAsset, _ result: AVURLAsset) async throws {
    let sourceAudio = try #require(try await source.loadTracks(withMediaType: .audio).first)
    let audios = try await result.loadTracks(withMediaType: .audio)
    #expect(audios.count == 1)
    let audio = try #require(audios.first)
    let sourceFormat = try await audioFormat(sourceAudio)
    let copiedFormat = try await audioFormat(audio)
    #expect(copiedFormat.mFormatID == kAudioFormatMPEG4AAC)
    #expect(copiedFormat.mSampleRate == sourceFormat.mSampleRate)
    #expect(copiedFormat.mChannelsPerFrame == sourceFormat.mChannelsPerFrame)
    let duration: Double = try await audio.load(.timeRange).duration.seconds
    let sourceDuration: Double = try await sourceAudio.load(.timeRange).duration.seconds
    #expect(abs(duration - sourceDuration) <= 0.05)
  }

  @Test("A disabled fallback audio track survives, still disabled", arguments: Container.allCases)
  func disabledFallbackAudioSurvives(container: Container) async throws {
    let fixture = try await Fixture.make(container, disabledFallbackAudio: true)
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    var enabled: [Bool] = []
    for track in try await AVURLAsset(url: copy.url).loadTracks(withMediaType: .audio) {
      enabled.append(try await track.load(.isEnabled))
    }
    #expect(enabled == [true, false])
  }

  // MARK: - Read-Back Gate

  @Test("The read-back gate rejects the dirty fixture and passes its copy", arguments: Container.allCases)
  func readBackRejectsMetadata(container: Container) async throws {
    let fixture = try await Fixture.make(container)
    await #expect(throws: VideoUploadSanitizationError.metadataRemained) {
      try await VideoUploadSanitizer.verifyContainsOnlySamples(fixture)
    }
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    try await VideoUploadSanitizer.verifyContainsOnlySamples(copy.url)
  }

  @Test("The read-back gate rejects a box AVFoundation reads as clean")
  func readBackRejectsUnreportedBoxes() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    let tampered = fixture.deletingLastPathComponent().appendingPathComponent("tampered.mov")
    try Data(contentsOf: copy.url).write(to: tampered)
    try Fixture.appendUnreportedBoxes(to: tampered)
    let asset = AVURLAsset(url: tampered)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.load(.metadata).isEmpty, "AVFoundation does not report the uuid or free box")
    await #expect(throws: VideoUploadSanitizationError.metadataRemained) {
      try await VideoUploadSanitizer.verifyContainsOnlySamples(tampered)
    }
  }

  // MARK: - Copies and Retries

  /// Regression guard for the deferral's checkpoint objection: the copy is made once per
  /// attachment's bytes, so a retry resumes the saved session.
  @Test("A retry after a relaunch resumes the same session with the same copy")
  func retryResumesTheSameSession() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let copies = folder.appendingPathComponent("copies")
    let checkpoints = folder.appendingPathComponent("checkpoints")
    let transport = try Self.recordingTransport()
    await transport.failPart(2, with: [
      VideoMultipartTransportError(statusCode: 400, code: "Rejected", message: "synthetic")
    ])
    let firstCopy = try await VideoUploadSanitizer(rootURL: copies).sanitizedCopy(of: fixture)
    try #require(firstCopy.byteCount > 2 * Self.partSizeBytes, "the copy spans at least three parts")

    await #expect(throws: VideoMultipartTransportError.self) {
      _ = try await self.upload(fixture, transport: transport, sanitizer: VideoUploadSanitizer(rootURL: copies),
                                store: VideoUploadCheckpointStore(rootURL: checkpoints))
    }
    #expect(try await VideoUploadCheckpointStore(rootURL: checkpoints).load(owner: VideoMultipartUploadChecks.owner)?.phase == .uploading)

    // A relaunch: new engine, store and sanitizer instances over the same files.
    let relaunched = try VideoUploadSanitizer(rootURL: copies)
    let blob = try await upload(fixture, transport: transport, sanitizer: relaunched,
                                store: VideoUploadCheckpointStore(rootURL: checkpoints))
    #expect(blob == VideoMultipartUploadChecks.blob)
    #expect(await transport.startCount == 1, "no second reservation")
    #expect(await transport.parts.filter { $0.number == 1 }.count == 1, "acknowledged parts are not sent again")
    let secondCopy = try await relaunched.sanitizedCopy(of: fixture)
    #expect(secondCopy == firstCopy)
    #expect(try copyFiles(in: copies) == [firstCopy.url.lastPathComponent])
    #expect(await transport.uploaded() == (try Data(contentsOf: firstCopy.url)))
  }

  /// Regression guard: changed attachment bytes never reuse another attachment's copy.
  @Test("Changed attachment bytes get a new copy")
  func changedBytesGetANewCopy() async throws {
    let first = try await Fixture.make(.quickTime, seed: 0x40)
    let second = try await Fixture.make(.quickTime, seed: 0x80)
    let sanitizer = try sanitizer(for: first)
    let firstCopy = try await sanitizer.sanitizedCopy(of: first)
    let secondCopy = try await sanitizer.sanitizedCopy(of: second)
    #expect(firstCopy.url != secondCopy.url)
    #expect(try digest(of: firstCopy.url) != digest(of: secondCopy.url))
  }

  @Test("Concurrent requests for the same bytes share one copy")
  func concurrentCopiesShareOneFile() async throws {
    let fixture = try await Fixture.make(.mpeg4)
    let sanitizer = try sanitizer(for: fixture)
    async let first = sanitizer.sanitizedCopy(of: fixture)
    async let second = sanitizer.sanitizedCopy(of: fixture)
    let (a, b) = try await (first, second)
    #expect(a == b)
    #expect(try copyFiles(in: fixture.deletingLastPathComponent().appendingPathComponent("copies")).count == 1)
  }

  @Test("A cached copy that gained metadata is discarded and made again")
  func cachedCopyWithMetadataIsRemade() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    let sanitizer = try VideoUploadSanitizer(rootURL: copies)
    // Named like a cached copy of this attachment, with matching digest, but holding metadata.
    let planted = copies.appendingPathComponent(
      "\(try digest(of: fixture))-v\(VideoUploadSanitizer.formatVersion)-\(try digest(of: fixture)).mov"
    )
    try FileManager.default.copyItem(at: fixture, to: planted)
    let copy = try await sanitizer.sanitizedCopy(of: fixture)
    #expect(copy.url != planted)
    #expect(!FileManager.default.fileExists(atPath: planted.path))
    let bytes = try Data(contentsOf: copy.url)
    for marker in Fixture.markers(for: .quickTime) {
      #expect(bytes.range(of: Data(marker.utf8)) == nil, "copy holds \(marker)")
    }
    try await VideoUploadSanitizer.verifyContainsOnlySamples(copy.url)
  }

  @Test("A cached copy whose bytes changed is discarded and made again")
  func corruptedCachedCopyIsRemade() async throws {
    let fixture = try await Fixture.make(.mpeg4)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    let first = try await VideoUploadSanitizer(rootURL: copies).sanitizedCopy(of: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.url.path)
    var corrupted = try Data(contentsOf: first.url)
    corrupted.removeLast(corrupted.count / 3)
    try corrupted.write(to: first.url)

    let remade = try await VideoUploadSanitizer(rootURL: copies).sanitizedCopy(of: fixture)
    let bytes = try Data(contentsOf: remade.url)
    #expect(bytes != corrupted)
    #expect(remade.url.lastPathComponent.hasSuffix("-\(try digest(of: remade.url)).mp4"), "name records the bytes")
    try await VideoUploadSanitizer.verifyContainsOnlySamples(remade.url)
    #expect(try copyFiles(in: copies).count == 1)
  }

  // MARK: - Failures Send Nothing

  @Test("An unreadable attachment sends nothing and leaves no files")
  func unreadableAttachmentSendsNothing() async throws {
    let attachment = try VideoMultipartTransportChecks.fixtureFile(Data(0..<10))
    let folder = attachment.deletingLastPathComponent()
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    await #expect(throws: VideoUploadSanitizationError.unreadable) {
      _ = try await self.upload(attachment, transport: transport, sanitizer: self.sanitizer(for: attachment), store: store)
    }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
    #expect(try Data(contentsOf: attachment) == Data(0..<10))
  }

  @Test("Too little free space fails before any export and sends nothing")
  func lowStorageSendsNothing() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let original = try digest(of: fixture)
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    let sanitizer = try VideoUploadSanitizer(rootURL: folder.appendingPathComponent("copies"), availableCapacity: { _ in
      VideoUploadSanitizer.exportHeadroomBytes
    })
    await #expect(throws: VideoUploadSanitizationError.insufficientStorage) {
      _ = try await self.upload(fixture, transport: transport, sanitizer: sanitizer, store: store)
    }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
    #expect(try digest(of: fixture) == original)
  }

  @Test("Out-of-space export failures get the free-space message")
  func outOfSpaceExportFailuresAreRecognized() {
    #expect(VideoUploadSanitizer.exportFailure(AVError(.diskFull)) == .insufficientStorage)
    #expect(VideoUploadSanitizer.exportFailure(CocoaError(.fileWriteOutOfSpace)) == .insufficientStorage)
    let wrapped = NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue, userInfo: [
      NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)),
    ])
    #expect(VideoUploadSanitizer.exportFailure(wrapped) == .insufficientStorage)
    #expect(VideoUploadSanitizer.exportFailure(AVError(.unknown)) == .exportFailed)
    #expect(VideoUploadSanitizer.hasRoom(forCopyOf: 10, available: nil))
    #expect(VideoUploadSanitizer.hasRoom(forCopyOf: 10, available: 10 + VideoUploadSanitizer.exportHeadroomBytes))
    #expect(!VideoUploadSanitizer.hasRoom(forCopyOf: 11, available: 10 + VideoUploadSanitizer.exportHeadroomBytes))
  }

  @Test("Cancelling while the copy is being made leaves no partial or cached file")
  func cancellingWhilePreparingLeavesNoCopy() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let original = try digest(of: fixture)
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    // The free-space check runs right before the export starts; cancel the upload there.
    let sanitizer = try VideoUploadSanitizer(rootURL: folder.appendingPathComponent("copies"), availableCapacity: { _ in
      withUnsafeCurrentTask { $0?.cancel() }
      return nil
    })
    let attempt = Task { try await self.upload(fixture, transport: transport, sanitizer: sanitizer, store: store) }
    await #expect(throws: CancellationError.self) { _ = try await attempt.value }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
    #expect(try digest(of: fixture) == original)
  }

  @Test("A changed owner never starts a remux")
  func ownerChangeRemuxesNothing() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    await #expect(throws: VideoMultipartError.self) {
      _ = try await self.upload(fixture, transport: transport, sanitizer: self.sanitizer(for: fixture), store: store,
                                isOwnerCurrent: { false })
    }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
  }

  // MARK: - Helpers

  struct Upload {
    let bytes: Data
    let blob: Blob
    let transport: ScriptedVideoTransport
  }

  /// Small enough that every fixture copy spans several parts.
  static let partSizeBytes = 512

  /// A service that plans parts for whatever size is started, reports the parts it has, and
  /// completes processing on finish.
  static func recordingTransport() throws -> ScriptedVideoTransport {
    let job = try VideoMultipartUploadChecks.job(
      "canonical", state: "JOB_STATE_COMPLETED", blob: VideoMultipartUploadChecks.blob
    )
    return ScriptedVideoTransport(
      finishes: [.success(.init(completedJobId: "canonical", jobStatus: job))],
      partSizeBytes: partSizeBytes, partCount: nil, reportsReceivedParts: true
    )
  }

  private func sanitizer(for attachment: URL) throws -> VideoUploadSanitizer {
    try VideoUploadSanitizer(rootURL: attachment.deletingLastPathComponent().appendingPathComponent("copies"))
  }

  /// Uploads through `MediaUploadManager`'s multipart route, the composer's only use of the engine.
  private func upload(
    _ attachment: URL, transport: ScriptedVideoTransport, sanitizer: VideoUploadSanitizer,
    store: VideoUploadCheckpointStore, isOwnerCurrent: @escaping @Sendable () async -> Bool = { true }
  ) async throws -> Blob {
    try await MediaUploadManager.uploadMultipartVideo(
      attachmentURL: attachment, owner: VideoMultipartUploadChecks.owner, durationMilliseconds: 1_000,
      transport: transport, store: store, sanitizer: sanitizer,
      configuration: VideoMultipartUploadChecks.configuration(),
      progress: { _ in }, isOwnerCurrent: isOwnerCurrent, canAuthorizeCleanup: isOwnerCurrent,
      authorizeNewSession: {}
    )
  }

  /// Uploads `attachment` through the multipart route the composer uses and returns what the
  /// video service received.
  private func uploadThroughComposerRoute(_ attachment: URL) async throws -> Upload {
    let folder = attachment.deletingLastPathComponent()
    let transport = try Self.recordingTransport()
    let blob = try await upload(
      attachment, transport: transport, sanitizer: sanitizer(for: attachment),
      store: VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    )
    return Upload(bytes: await transport.uploaded(), blob: blob, transport: transport)
  }

  private func expectNothingSent(
    transport: ScriptedVideoTransport, store: VideoUploadCheckpointStore, folder: URL
  ) async throws {
    #expect(await transport.starts.isEmpty)
    #expect(await transport.parts.isEmpty)
    #expect(try await store.load(owner: VideoMultipartUploadChecks.owner) == nil)
    let copies = folder.appendingPathComponent("copies")
    #expect(try copyFiles(in: copies).isEmpty)
    let partial = copies.appendingPathComponent("Partial")
    #expect(try FileManager.default.contentsOfDirectory(atPath: partial.path).isEmpty)
  }

  /// Names of the cached copies (not the Partial folder) in `copies`.
  private func copyFiles(in copies: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: copies.path)
      .filter { $0.contains("-v\(VideoUploadSanitizer.formatVersion)-") }
  }

  /// Writes `bytes` to a file and reads it back the way a downloader of the blob would.
  @discardableResult
  private func expectNoMetadata(_ bytes: Data, container: Container) async throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("video-readback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("uploaded").appendingPathExtension(container.pathExtension)
    try bytes.write(to: url)
    let asset = AVURLAsset(url: url)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.load(.metadata).isEmpty)
    #expect(try await asset.load(.commonMetadata).isEmpty)
    #expect(try await asset.load(.creationDate) == nil)
    for format in try await asset.load(.availableMetadataFormats) {
      #expect(try await asset.loadMetadata(for: format).isEmpty, "asset \(format.rawValue)")
    }
    #expect(try await asset.loadTracks(withMediaType: .metadata).isEmpty)
    let tracks = try await asset.load(.tracks)
    #expect(!tracks.isEmpty)
    for track in tracks {
      #expect(track.mediaType == .video || track.mediaType == .audio, "track \(track.mediaType.rawValue)")
      #expect(try await track.load(.metadata).isEmpty)
      for format in try await track.load(.availableMetadataFormats) {
        #expect(try await track.loadMetadata(for: format).isEmpty, "track \(format.rawValue)")
      }
    }
    return url
  }

  private func compressedSamples(of track: AVAssetTrack, in asset: AVAsset) async throws -> [(time: CMTime, bytes: Data)] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(output)
    #expect(reader.startReading())
    var samples: [(time: CMTime, bytes: Data)] = []
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      var bytes = Data(count: CMBlockBufferGetDataLength(block))
      let status = bytes.withUnsafeMutableBytes { buffer in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: buffer.count, destination: buffer.baseAddress!)
      }
      #expect(status == kCMBlockBufferNoErr)
      samples.append((CMSampleBufferGetPresentationTimeStamp(sample), bytes))
    }
    #expect(reader.status == .completed)
    return samples
  }

  private func mediaSubType(_ track: AVAssetTrack) async throws -> FourCharCode {
    let description = try #require(try await track.load(.formatDescriptions).first)
    return CMFormatDescriptionGetMediaSubType(description)
  }

  private func audioFormat(_ track: AVAssetTrack) async throws -> AudioStreamBasicDescription {
    let description = try #require(try await track.load(.formatDescriptions).first)
    return try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
  }

  private func digest(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}
