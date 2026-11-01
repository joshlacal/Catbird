import AVFoundation
import CryptoKit
import Foundation
import os
import Petrel
import Testing
@testable import Catbird

@Suite("Video upload metadata stripping", .timeLimit(.minutes(1)))
struct VideoUploadSanitizerTests {
  typealias Fixture = VideoMetadataFixture
  typealias Container = VideoMetadataFixture.Container
  typealias Codec = VideoMetadataFixture.Codec

  // MARK: - Positive Controls

  @Test("The fixture carries identifying metadata at every level", arguments: Container.allCases, Codec.allCases)
  func fixtureCarriesMetadataAtEveryLevel(container: Container, codec: Codec) async throws {
    let fixture = try await Fixture.make(container, codec: codec)
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
    let description = try #require(try await video.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(description) == codec.mediaSubType)
    // AVFoundation reads the encoder name, so a passthrough export writes it again.
    let name = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FormatName)
    #expect(name as? String == Fixture.compressorName)
    if codec == .hevcHLG {
      let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
      #expect(transfer as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
    if container == .quickTime {
      #expect(try await !asset.loadTracks(withMediaType: .metadata).isEmpty)
    }
    #expect(try Fixture.headerTimes(in: bytes).allSatisfy { $0 == Fixture.captureStamp })
  }

  // MARK: - Uploaded Bytes

  @Test("The bytes sent to the video service carry no identifying metadata", arguments: Container.allCases, Codec.allCases)
  func uploadedPartsCarryNoIdentifyingMetadata(container: Container, codec: Codec) async throws {
    let fixture = try await Fixture.make(container, codec: codec)
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

  @Test("The copy is a passthrough remux of the audio and video samples", arguments: Container.allCases, Codec.allCases)
  func copyIsAPassthroughRemux(container: Container, codec: Codec) async throws {
    let fixture = try await Fixture.make(container, codec: codec)
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    #expect(copy.mimeType == container.mimeType)
    #expect(copy.url.pathExtension == container.pathExtension)
    let source = AVURLAsset(url: fixture)
    let result = AVURLAsset(url: copy.url)
    try await expectSameVideo(source, result, codec: codec)
    try await expectSameAudio(source, result)
    let duration = try await result.load(.duration).seconds
    let sourceDuration = try await source.load(.duration).seconds
    #expect(abs(duration - sourceDuration) <= 1 / Double(Fixture.framesPerSecond))
    #expect(try await result.loadTracks(withMediaType: .metadata).isEmpty)
  }

  private func expectSameVideo(_ source: AVURLAsset, _ result: AVURLAsset, codec: Codec) async throws {
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
    let description = try #require(try await video.load(.formatDescriptions).first)
    let sourceDescription = try #require(try await sourceVideo.load(.formatDescriptions).first)
    #expect(CMFormatDescriptionGetMediaSubType(description) == codec.mediaSubType)
    // HDR video keeps the colour tagging that tells players how to show it.
    for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                kCMFormatDescriptionExtension_YCbCrMatrix] {
      let copied = CMFormatDescriptionGetExtension(description, extensionKey: key) as? String
      #expect(copied == CMFormatDescriptionGetExtension(sourceDescription, extensionKey: key) as? String, "\(key)")
    }
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

  @Test("A rotation written only in the movie header survives", arguments: Container.allCases)
  func movieHeaderRotationSurvives(container: Container) async throws {
    let fixture = try await Fixture.make(container, rotationPlacement: .movieHeader)
    let source = AVURLAsset(url: fixture)
    let sourceVideo = try #require(try await source.loadTracks(withMediaType: .video).first)
    #expect(try await sourceVideo.load(.preferredTransform) == .identity, "fixture: the track header has no rotation")
    let expected = try await displayTransform(of: source)
    #expect(expected != .identity, "fixture: the movie header rotates the picture")
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    #expect(try await displayTransform(of: AVURLAsset(url: copy.url)) == expected)
  }

  /// What a player applies to the video track: its own transform, then the movie's.
  private func displayTransform(of asset: AVURLAsset) async throws -> CGAffineTransform {
    let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let track = try await video.load(.preferredTransform)
    return track.concatenating(try await asset.load(.preferredTransform))
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

  @Test("A copy missing a track, or with a track's enabled flag changed, is refused")
  func lostTracksAreRefused() {
    typealias Track = VideoUploadSanitizer.TrackSignature
    let video = Track(mediaType: AVMediaType.video.rawValue, isEnabled: true)
    let audio = Track(mediaType: AVMediaType.audio.rawValue, isEnabled: true)
    let fallback = Track(mediaType: AVMediaType.audio.rawValue, isEnabled: false)
    #expect(VideoUploadSanitizer.keepsEveryTrack(inserted: [video, audio, fallback], written: [fallback, video, audio]))
    #expect(!VideoUploadSanitizer.keepsEveryTrack(inserted: [video, audio, fallback], written: [video, audio]))
    #expect(!VideoUploadSanitizer.keepsEveryTrack(inserted: [video, fallback], written: [video, audio]))
    #expect(!VideoUploadSanitizer.keepsEveryTrack(inserted: [video, audio], written: [video, audio, audio]))
  }

  /// Regression guard for resuming after a copy is made again: a saved session is matched by
  /// the copy's SHA-256.
  @Test("Making a copy again gives identical bytes", arguments: Codec.allCases)
  func remadeCopyIsIdentical(codec: Codec) async throws {
    let fixture = try await Fixture.make(.quickTime, codec: codec)
    let folder = fixture.deletingLastPathComponent()
    let first = try await VideoUploadSanitizer(rootURL: folder.appendingPathComponent("copies-a")).sanitizedCopy(of: fixture)
    let second = try await VideoUploadSanitizer(rootURL: folder.appendingPathComponent("copies-b")).sanitizedCopy(of: fixture)
    #expect(first.url.lastPathComponent == second.url.lastPathComponent)
    #expect(try Data(contentsOf: first.url) == Data(contentsOf: second.url))
  }

  // MARK: - Read-Back Gate

  @Test("The read-back gate rejects the dirty fixture and passes its copy", arguments: Container.allCases, Codec.allCases)
  func readBackRejectsMetadata(container: Container, codec: Codec) async throws {
    let fixture = try await Fixture.make(container, codec: codec)
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

  @Test("The read-back gate rejects sample descriptions that name a vendor or encoder")
  func readBackRejectsNamedSampleDescriptions() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copy = try await sanitizer(for: fixture).sanitizedCopy(of: fixture)
    let tampered = fixture.deletingLastPathComponent().appendingPathComponent("named.mov")
    var bytes = try Data(contentsOf: copy.url)
    try Fixture.nameSampleDescriptions(&bytes)
    try bytes.write(to: tampered)
    let asset = AVURLAsset(url: tampered)
    #expect(try await asset.load(.isPlayable))
    #expect(try await asset.load(.metadata).isEmpty, "AVFoundation reports no metadata item for them")
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

  @Test("A retry in the same session hashes and verifies neither file again")
  func retryReadsNeitherFileAgain() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    let sanitizer = try VideoUploadSanitizer(rootURL: copies)
    let copy = try await sanitizer.sanitizedCopy(of: fixture)
    // Neither file can be read now; a retry only checks that both are the same files.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copy.url.path)
    #expect(try await sanitizer.sanitizedCopy(of: fixture) == copy)
    await #expect(throws: (any Error).self, "a new process hashes the attachment again") {
      _ = try await VideoUploadSanitizer(rootURL: copies.appendingPathComponent("new-process")).sanitizedCopy(of: fixture)
    }

    // Rewritten attachment bytes are hashed again and get their own copy.
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.url.path)
    try Data(contentsOf: try await Fixture.make(.quickTime, seed: 0x80)).write(to: fixture)
    let rewritten = try await sanitizer.sanitizedCopy(of: fixture)
    #expect(rewritten.url != copy.url)
    #expect(try copyFiles(in: copies).count == 2)
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

  @Test("Two requests for the same bytes that both export share one copy")
  func concurrentCopiesShareOneFile() async throws {
    let fixture = try await Fixture.make(.mpeg4, frames: 300)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    let race = ExportRace()
    let sanitizer = try VideoUploadSanitizer(rootURL: copies, availableCapacity: { _ in
      race.exportStarting()
      return nil
    })
    // The second request is queued on the sanitizer before the first starts exporting, so it
    // runs while the first exports, finds no copy and exports too; the rename race decides
    // which file both get.
    race.startSecond { Task { try await sanitizer.sanitizedCopy(of: fixture) } }
    let first = try await sanitizer.sanitizedCopy(of: fixture)
    let secondRequest = try #require(race.second)
    let second = try await secondRequest.value
    #expect(race.exports == 2, "both requests exported")
    #expect(first == second)
    #expect(try copyFiles(in: copies).count == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: copies.appendingPathComponent("Partial").path).isEmpty)
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
    let sanitizer = try VideoUploadSanitizer(rootURL: copies)
    let first = try await sanitizer.sanitizedCopy(of: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: first.url.path)
    var corrupted = try Data(contentsOf: first.url)
    corrupted.removeLast(corrupted.count / 3)
    try corrupted.write(to: first.url)

    let remade = try await sanitizer.sanitizedCopy(of: fixture)
    let bytes = try Data(contentsOf: remade.url)
    #expect(bytes != corrupted)
    #expect(remade.url.lastPathComponent.hasSuffix("-\(try digest(of: remade.url)).mp4"), "name records the bytes")
    try await VideoUploadSanitizer.verifyContainsOnlySamples(remade.url)
    #expect(try copyFiles(in: copies).count == 1)
  }

  @Test("A cached copy that can't be read right now is kept, and a retry uses it")
  func unreadableCachedCopyIsKept() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    let copy = try await VideoUploadSanitizer(rootURL: copies).sanitizedCopy(of: fixture)
    let bytes = try Data(contentsOf: copy.url)
    // Start the reader before planting a non-memoized copy, so this tests read-back failure
    // rather than startup reclamation of a previous process's unowned files.
    let reader = try VideoUploadSanitizer(rootURL: copies)
    try bytes.write(to: copy.url)
    // Like a protected file while the device is locked: there, but not readable.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: copy.url.path)
    await #expect(throws: VideoUploadSanitizationError.exportFailed) {
      _ = try await reader.sanitizedCopy(of: fixture)
    }
    #expect(FileManager.default.fileExists(atPath: copy.url.path), "the copy is not deleted")
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.url.path)
    #expect(try await reader.sanitizedCopy(of: fixture) == copy)
  }

  @Test("Copies made under another format version are deleted when a sanitizer starts")
  func copiesFromOtherFormatVersionsAreDeleted() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let copies = fixture.deletingLastPathComponent().appendingPathComponent("copies")
    _ = try VideoUploadSanitizer(rootURL: copies)
    let hex = String(repeating: "ab", count: 32)
    let older = copies.appendingPathComponent("\(hex)-v\(VideoUploadSanitizer.formatVersion - 1)-\(hex).mov")
    let unrelated = copies.appendingPathComponent("unrelated.mov")
    try Data("older rule".utf8).write(to: older)
    try Data("not a copy".utf8).write(to: unrelated)
    _ = try VideoUploadSanitizer(rootURL: copies)
    #expect(!FileManager.default.fileExists(atPath: older.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
  }

  @Test("Copies are kept out of device backups")
  func copiesAreExcludedFromBackup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-copies-\(UUID().uuidString)")
    _ = try VideoUploadSanitizer(rootURL: root)
    var reread = root
    reread.removeAllCachedResourceValues()
    #expect(try reread.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
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

  @Test("An export still running at its time limit fails, sends nothing and leaves no file")
  func exportPastItsTimeLimitFails() async throws {
    let fixture = try await Fixture.make(.quickTime, frames: 300)
    let folder = fixture.deletingLastPathComponent()
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    // The time limit is already up when the export starts.
    let sanitizer = try VideoUploadSanitizer(rootURL: folder.appendingPathComponent("copies"), exportDeadline: {})
    await #expect(throws: VideoUploadSanitizationError.exportFailed) {
      _ = try await self.upload(fixture, transport: transport, sanitizer: sanitizer, store: store)
    }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
  }

  @Test("Cancelling before the export starts leaves no partial or cached file")
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

  @Test("Cancelling while the partial copy is being written leaves no partial or cached file")
  func cancellingDuringExportLeavesNoCopy() async throws {
    let fixture = try await Fixture.make(.quickTime, frames: 600)
    let folder = fixture.deletingLastPathComponent()
    let original = try digest(of: fixture)
    var cancelledWhileWriting = 0
    // The watcher cancels as soon as the export's partial file appears; an attempt whose copy
    // finished first does not count, so try a few times.
    for attempt in 1...5 where cancelledWhileWriting == 0 {
      let copies = folder.appendingPathComponent("copies-\(attempt)")
      let sanitizer = try VideoUploadSanitizer(rootURL: copies)
      let partial = copies.appendingPathComponent("Partial")
      let preparing = Task { try await sanitizer.sanitizedCopy(of: fixture) }
      let watcher = FirstEntryWatcher(directory: partial) { preparing.cancel() }
      let result = await preparing.result
      let sawPartial = watcher.stop()
      #expect(try FileManager.default.contentsOfDirectory(atPath: partial.path).isEmpty, "attempt \(attempt) left a partial file")
      guard case .failure(let error) = result else { continue }
      #expect(error is CancellationError, "attempt \(attempt) failed with \(error)")
      #expect(try copyFiles(in: copies).isEmpty, "attempt \(attempt) left a copy")
      if sawPartial { cancelledWhileWriting += 1 }
    }
    #expect(cancelledWhileWriting == 1, "a cancellation landed while the partial copy was on disk")
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

  @Test("A completed multipart upload releases its temporary sanitized copy and its snapshot")
  func completedUploadReleasesTemporaryCopy() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let original = try digest(of: fixture)
    let transport = try Self.recordingTransport()
    let checkpointRoot = folder.appendingPathComponent("checkpoints")
    let store = try VideoUploadCheckpointStore(rootURL: checkpointRoot)
    let sanitizer = try sanitizer(for: fixture)
    let blob = try await upload(fixture, transport: transport, sanitizer: sanitizer, store: store)
    #expect(blob == VideoMultipartUploadChecks.blob)
    #expect(try copyFiles(in: folder.appendingPathComponent("copies")).isEmpty)
    #expect(try digest(of: fixture) == original)

    let checkpoint = try #require(try await store.load(owner: VideoMultipartUploadChecks.owner))
    #expect(checkpoint.phase == .complete)
    let uploaded = await transport.uploaded()
    #expect(checkpoint.sha256 == SHA256.hash(data: uploaded).map { String(format: "%02x", $0) }.joined())
    let files = try #require(FileManager.default.enumerator(
      at: checkpointRoot, includingPropertiesForKeys: nil))
    let leftovers = files.allObjects.compactMap { $0 as? URL }.filter { ["video", "part"].contains($0.pathExtension) }
    #expect(leftovers.isEmpty, "a completed upload keeps no snapshot or part file")
  }

  @Test("Losing ownership after sanitization releases the copy without creating an upload")
  func ownerChangeAfterSanitizationReleasesTemporaryCopy() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    let checks = OwnerChangingAfterPreparation()
    await #expect(throws: VideoMultipartError.self) {
      _ = try await self.upload(
        fixture, transport: transport, sanitizer: self.sanitizer(for: fixture), store: store,
        isOwnerCurrent: { await checks.isCurrent() })
    }
    try await expectNothingSent(transport: transport, store: store, folder: folder)
    #expect(FileManager.default.fileExists(atPath: fixture.path))
  }

  @Test("A failed checkpoint preparation releases only its temporary copy")
  func failedCheckpointPreparationReleasesTemporaryCopy() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let original = try Data(contentsOf: fixture)
    let transport = try Self.recordingTransport()
    let store = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("checkpoints"))
    // A real existing lease makes prepare reject the competing run before reading its copy.
    let held = try await store.prepare(
      sourceURL: fixture, owner: VideoMultipartUploadChecks.owner, mimeType: "video/quicktime")
    await #expect(throws: VideoUploadFileError.self) {
      _ = try await self.upload(fixture, transport: transport, sanitizer: self.sanitizer(for: fixture), store: store)
    }
    #expect(await transport.starts.isEmpty)
    #expect(try copyFiles(in: folder.appendingPathComponent("copies")).isEmpty)
    #expect(try Data(contentsOf: fixture) == original)
    #expect(try await store.load(owner: held.owner)?.operationID == held.operationID)
    await store.release(owner: held.owner, runID: held.runID)
  }

  @Test("One upload cannot release a copy another upload still needs")
  func concurrentUploadConsumersKeepCopyUntilBothFinish() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let sanitizer = try sanitizer(for: fixture)
    let blocked = CopyConsumerGate()
    let firstTransport = try Self.recordingTransport()
    let firstStore = try VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("first-checkpoints"))
    let first = Task {
      try await self.upload(fixture, transport: firstTransport, sanitizer: sanitizer, store: firstStore,
                            isOwnerCurrent: { await blocked.isCurrent() })
    }
    // First upload has received its copy but has not yet made its independent snapshot.
    await blocked.gate.waitUntilEntered()
    let secondTransport = try Self.recordingTransport()
    let second = await Task {
      try await self.upload(
        fixture, transport: secondTransport, sanitizer: sanitizer,
        store: VideoUploadCheckpointStore(rootURL: folder.appendingPathComponent("second-checkpoints")))
    }.result
    let retainedCopies = try? copyFiles(in: folder.appendingPathComponent("copies")).count
    // Always release the blocked consumer, including when the second run failed.
    await blocked.gate.open()
    let firstResult = await first.result
    #expect(try second.get() == VideoMultipartUploadChecks.blob)
    #expect(retainedCopies == 1)
    #expect(try firstResult.get() == VideoMultipartUploadChecks.blob)
    #expect(await firstTransport.uploaded() == secondTransport.uploaded())
    #expect(try copyFiles(in: folder.appendingPathComponent("copies")).isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.path))
  }

  @Test("A fresh sanitizer reclaims recognizable current-version crash leftovers and preserves unrelated files")
  func startupReclaimsCurrentVersionCrashLeftovers() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let copies = folder.appendingPathComponent("copies")
    let leftover = try await VideoUploadSanitizer(rootURL: copies).sanitizedCopy(of: fixture)
    let unrelated = copies.appendingPathComponent("unrelated.mov")
    try Data("keep".utf8).write(to: unrelated)
    let relaunched = try VideoUploadSanitizer(rootURL: copies)
    #expect(!FileManager.default.fileExists(atPath: leftover.url.path))
    #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.path))
    let regenerated = try await relaunched.sanitizedCopy(of: fixture)
    #expect(regenerated.url == leftover.url, "deterministic bytes still match retained multipart snapshots")
    try await VideoUploadSanitizer.verifyContainsOnlySamples(regenerated.url)
  }

  @Test("Duplicate and stale copy tokens cannot release another active reader")
  func copyTokensReleaseOnlyTheirOwnReader() async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let sanitizer = try sanitizer(for: fixture)
    let first = try await sanitizer.uploadCopy(of: fixture)
    let second = try await sanitizer.uploadCopy(of: fixture)
    #expect(first.url == second.url)
    #expect(first.leaseID != second.leaseID)
    await sanitizer.releaseUploadCopy(first)
    #expect(FileManager.default.fileExists(atPath: second.url.path))
    await sanitizer.releaseUploadCopy(first)
    #expect(FileManager.default.fileExists(atPath: second.url.path))
    await sanitizer.releaseUploadCopy(second)
    #expect(!FileManager.default.fileExists(atPath: second.url.path))
    let later = try await sanitizer.uploadCopy(of: fixture)
    #expect(later.url == second.url, "regenerated bytes retain the retry identity")
    await sanitizer.releaseUploadCopy(second)
    #expect(FileManager.default.fileExists(atPath: later.url.path))
    await sanitizer.releaseUploadCopy(later)
    #expect(try copyFiles(in: folder.appendingPathComponent("copies")).isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.path))
  }

  @Test("The legacy copy scope holds through its awaited operation and releases on every exit",
        arguments: ["success", "error", "cancel", "size"])
  func scopedLegacyCopyLifetime(outcome: String) async throws {
    let fixture = try await Fixture.make(.quickTime)
    let folder = fixture.deletingLastPathComponent()
    let original = try digest(of: fixture)
    let sanitizer = try sanitizer(for: fixture)
    let gate = VideoTestGate()
    let operation = Task {
      try await sanitizer.withSanitizedCopy(of: fixture) { copy in
        #expect(FileManager.default.fileExists(atPath: copy.url.path))
        await gate.wait()
        #expect(FileManager.default.fileExists(atPath: copy.url.path))
        try Task.checkCancellation()
        if outcome == "error" { throw VideoUploadSanitizationError.exportFailed }
        if outcome == "size" { throw VideoUploadSanitizationError.tooLarge }
        return copy.byteCount
      }
    }
    await gate.waitUntilEntered()
    let retained = try? copyFiles(in: folder.appendingPathComponent("copies")).count
    if outcome == "cancel" { operation.cancel() }
    await gate.open()
    let result = await operation.result
    #expect(retained == 1, "the awaited consumer still owns the copy")
    switch result {
    case .success(let count):
      #expect(outcome == "success")
      #expect(count > 0)
    case .failure(let error):
      switch outcome {
      case "cancel": #expect(error is CancellationError)
      case "error": #expect(error as? VideoUploadSanitizationError == .exportFailed)
      case "size": #expect(error as? VideoUploadSanitizationError == .tooLarge)
      default: Issue.record("Unexpected scoped upload failure: \(error)")
      }
    }
    #expect(try copyFiles(in: folder.appendingPathComponent("copies")).isEmpty)
    #expect(try digest(of: fixture) == original)
  }

  private actor CopyConsumerGate {
    let gate = VideoTestGate()
    private var checks = 0

    func isCurrent() async -> Bool {
      checks += 1
      if checks == 2 { await gate.wait() }
      return true
    }
  }

  private actor OwnerChangingAfterPreparation {
    private var checks = 0

    func isCurrent() -> Bool {
      checks += 1
      return checks == 1
    }
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
      for description in try await track.load(.formatDescriptions) {
        let name = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_FormatName)
        let vendor = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_Vendor)
        // With the compressor name cleared, AVFoundation reports the codec's four-character code.
        #expect(name as? String != Fixture.compressorName, "track \(track.mediaType.rawValue) encoder name")
        #expect(vendor == nil, "track \(track.mediaType.rawValue) vendor")
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

  private func audioFormat(_ track: AVAssetTrack) async throws -> AudioStreamBasicDescription {
    let description = try #require(try await track.load(.formatDescriptions).first)
    return try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
  }

  private func digest(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
  }
}

// MARK: - Concurrency Helpers

/// Starts a second request for the same attachment the moment the first is about to export, and
/// counts how many requests got that far. The sanitizer calls `exportStarting` through its
/// free-space check, which runs on the sanitizer right before each export.
final class ExportRace: Sendable {
  private struct State: Sendable {
    var exports = 0
    var makeSecond: (@Sendable () -> Task<SanitizedVideo, any Error>)?
    var second: Task<SanitizedVideo, any Error>?
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  var exports: Int { state.withLock { $0.exports } }
  var second: Task<SanitizedVideo, any Error>? { state.withLock { $0.second } }

  func startSecond(_ make: @escaping @Sendable () -> Task<SanitizedVideo, any Error>) {
    state.withLock { $0.makeSecond = make }
  }

  func exportStarting() {
    let make = state.withLock { state -> (@Sendable () -> Task<SanitizedVideo, any Error>)? in
      state.exports += 1
      return state.exports == 1 ? state.makeSecond : nil
    }
    guard let make else { return }
    let task = make()
    state.withLock { $0.second = task }
  }
}

/// Watches a directory from its own thread and calls `onFirstEntry` as soon as anything is in it.
final class FirstEntryWatcher: Sendable {
  private struct State: Sendable {
    var stopped = false
    var sawEntry = false
  }
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(directory: URL, onFirstEntry: @escaping @Sendable () -> Void) {
    let state = self.state
    Thread {
      while !state.withLock({ $0.stopped }) {
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path), !entries.isEmpty {
          state.withLock { $0.sawEntry = true }
          onFirstEntry()
          return
        }
        usleep(100)
      }
    }.start()
  }

  /// Stops watching and says whether an entry was seen.
  func stop() -> Bool {
    state.withLock { state in
      state.stopped = true
      return state.sawEntry
    }
  }
}
