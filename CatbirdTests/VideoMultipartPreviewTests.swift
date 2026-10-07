#if !MULTIPART_HARNESS || PREVIEW_HARNESS
import Foundation
#if !PREVIEW_HARNESS
import Testing
@testable import Catbird
#endif

enum VideoMultipartPreviewChecks {
  @MainActor
  static func stableAttachmentIdentity() throws {
    let id = UUID()
    var item = PostComposerViewModel.MediaItem(id: id)
    item.altText = "Retained video description"
    item.rawVideoURL = URL(fileURLWithPath: "/tmp/synthetic-video-reference.mp4")
    let stored = CodableMediaItem(from: item)
    let decoded = try JSONDecoder().decode(CodableMediaItem.self, from: JSONEncoder().encode(stored))
    let restored = decoded.toMediaItem()
    try check(restored.id == id && decoded.attachmentID == id, "attachment identity survives draft serialization")
    try check(restored.rawVideoURL == item.rawVideoURL && restored.altText == item.altText, "identity changes preserve source and alt text")
    var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
    oldJSON.removeValue(forKey: "attachmentID")
    let old = try JSONDecoder().decode(CodableMediaItem.self, from: JSONSerialization.data(withJSONObject: oldJSON))
    try check(old.attachmentID == nil, "old draft without attachment ID remains decodable")
    let firstRestore = old.toMediaItem()
    let resaved = CodableMediaItem(from: firstRestore)
    let secondRestore = try JSONDecoder().decode(CodableMediaItem.self, from: JSONEncoder().encode(resaved)).toMediaItem()
    try check(firstRestore.id == secondRestore.id, "first save assigns stable ID to older attachment")
  }

  @MainActor
  static func failedGIFRemainsRecoverable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-gif-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.gif")
    // Deliberately decodable still bytes expose accidental flattening in restoration.
    let bytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=")!
    try bytes.write(to: source)
    let id = UUID()
    let json: [String: Any] = [
      "attachmentID": id.uuidString, "altText": "An animation that must not become a still",
      "isLoading": true, "isAudioVisualizerVideo": false, "isGifConversion": true,
      "rawImageURLString": source.absoluteString,
    ]
    let stored = try JSONDecoder().decode(CodableMediaItem.self, from: JSONSerialization.data(withJSONObject: json))
    let restored = stored.toMediaItem()
    try check(restored.id == id && restored.isGifConversion, "failed GIF retains attachment and conversion intent")
    try check(restored.image == nil && !restored.isLoading, "failed GIF does not become a ready still or orphaned spinner")
    try check(restored.rawData == bytes && restored.rawImageURL == source, "retry retains exact GIF source bytes and reference")
    try check(restored.rawVideoURL == nil && restored.altText == json["altText"] as? String, "conversion failure preserves meaningful metadata")
    try check(try Data(contentsOf: source) == bytes, "restoration never deletes or rewrites the source")
    let resaved = CodableMediaItem(from: restored)
    try check(resaved.rawImageURLString != nil, "autosave retains a source even if shared-container persistence fails")
  }

  static func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw PreviewCheckFailure(message: message) }
  }
}
private struct PreviewCheckFailure: Error { let message: String }

#if !PREVIEW_HARNESS
@Suite("Multipart draft identity and GIF preservation")
@MainActor
struct VideoMultipartPreviewTests {
  @Test func stableDraftIdentity() throws { try VideoMultipartPreviewChecks.stableAttachmentIdentity() }
  @Test func failedAnimationRemainsRetryable() throws { try VideoMultipartPreviewChecks.failedGIFRemainsRecoverable() }
  @Test func uncertainStartExplainsReservation() throws {
    let message = try #require(PostComposerErrorCopy.message(for: VideoMultipartError.startUncertain, isThread: false))
    #expect(message.contains("allowance"))
    #expect(message.contains("preserved"))
  }
  @Test func processingTimeoutExplainsSavedJob() throws {
    let message = try #require(PostComposerErrorCopy.message(for: VideoMultipartError.processingTimedOut, isThread: false))
    #expect(message.contains("saved job"))
    #expect(message.contains("without uploading"))
  }
  @Test func smallerPDSBlobLimitHasActionableCopy() throws {
    let error = VideoMultipartError.processingFailed(code: "pds_upload_unsupported_blob_size", message: "private service detail")
    let message = try #require(PostComposerErrorCopy.message(for: error, isThread: true))
    #expect(message.contains("smaller video"))
    #expect(message.contains("draft has been kept"))
    #expect(!message.contains("private service detail"))
    #expect(!message.contains("pds_upload_unsupported_blob_size"))
  }
  @Test func videoAuthorizationFailureDoesNotRequestSignOut() throws {
    let error = VideoMultipartTransportError(statusCode: 401, code: "AuthRequired", message: "sign out of everything")
    let message = try #require(PostComposerErrorCopy.message(for: error, isThread: false))
    #expect(message.contains("draft has been kept"))
    #expect(!message.lowercased().contains("sign out"))
    #expect(!message.contains("AuthRequired"))
  }
}
#endif
#endif
