import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Catbird

struct CopilotImageSupportTests {
  @Test func requiresOSAvailableModelAndVision() {
    #expect(CopilotImageSupport.gateReason(supportedOS: false, modelAvailable: true, supportsVision: true) != nil)
    #expect(CopilotImageSupport.gateReason(supportedOS: true, modelAvailable: false, supportsVision: true) != nil)
    #expect(CopilotImageSupport.gateReason(supportedOS: true, modelAvailable: true, supportsVision: false) != nil)
    #expect(CopilotImageSupport.gateReason(supportedOS: true, modelAvailable: true, supportsVision: true) == nil)
  }

  @Test func candidatesBelongOnlyToSelectedStillImagesAndExactRecord() throws {
    let original = context()
    let candidates = original.imageCandidates
    #expect(candidates.count == 2)
    #expect(candidates.map(\.label) == ["Image 1", "Image 3"])
    #expect(candidates.first?.thumbnailURL?.absoluteString == "https://example.test/first")
    #expect(Set(candidates.map(\.id)).count == 2)
    #expect(original.imageCandidates == candidates)
    guard case .post(let uri, _, let author, let text, let snapshot) = original else { return }
    let replaced = CopilotContext.post(uri: uri, cid: "replacement", authorDID: author, text: text, evidence: snapshot)
    #expect(replaced.imageCandidates.isEmpty)
    #expect(CopilotContext.post(uri: uri, cid: "cid", authorDID: "did:plc:other", text: text, evidence: snapshot).imageCandidates.isEmpty)
    #expect(CopilotContext.search(query: "images").imageCandidates.isEmpty)
  }

  @Test func neverLoadsWithoutAnExplicitCurrentSelection() async throws {
    let calls = LoadCalls()
    let original = context()
    let none = try await CopilotImageSupport.prepare(selectedImageID: nil, context: original, unavailableReason: nil,
      authorize: { true }, load: { url in await calls.record(url); return try Self.image() })
    #expect(none.image == nil && none.evidence == nil)
    let invalid = try await CopilotImageSupport.prepare(selectedImageID: "stale-or-invented", context: original,
      unavailableReason: nil, authorize: { true }, load: { url in await calls.record(url); return try Self.image() })
    #expect(invalid.image == nil)
    #expect(invalid.evidence?.text.contains("no longer belongs") == true)
    #expect(await calls.urls.isEmpty)
  }

  @Test func loadsExactlyOneChosenImageAndReportsItsCoverage() async throws {
    let original = context()
    let selected = try #require(original.imageCandidates.last)
    let calls = LoadCalls()
    let prepared = try await CopilotImageSupport.prepare(selectedImageID: selected.id, context: original,
      unavailableReason: nil, authorize: { true }, load: { url in await calls.record(url); return try Self.image() })
    #expect(await calls.urls == [selected.thumbnailURL!])
    #expect(prepared.image != nil)
    #expect(prepared.candidate?.id == selected.id)
    #expect(prepared.evidence?.origin == "selected_image")
    #expect(prepared.evidence?.text.contains("Image 3 inspected on device") == true)
    #expect(prepared.evidence?.sources.first?.uri == "at://did:plc:a/app.bsky.feed.post/1")
  }

  @Test func selectedHydratedOriginalIsPreferredOverItsPreview() async throws {
    let uri = "at://did:plc:a/app.bsky.feed.post/fullsize"
    let fullsize = URL(string: "https://example.test/original")!
    let snapshot = CopilotPostEvidence(selectedPost: .init(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Text",
      media: [.init(kind: .image, altText: "Supplied alt", thumbnailURL: URL(string: "https://example.test/thumb"), imageURL: fullsize)]),
      quotedPosts: [], coverage: [])
    let context = CopilotContext.post(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Text", evidence: snapshot)
    let calls = LoadCalls()
    let prepared = try await CopilotImageSupport.prepare(selectedImageID: context.imageCandidates.first?.id,
      context: context, unavailableReason: nil, authorize: { true }, load: { url in await calls.record(url); return try Self.image() })
    #expect(await calls.urls == [fullsize])
    #expect(prepared.evidence?.text.contains("resized still image") == true)
    #expect(prepared.evidence?.text.contains("1024 pixels") == true)
  }

  @Test func unsupportedAndLoadFailureUseTruthfulMetadataCoverage() async throws {
    let original = context()
    let selected = try #require(original.imageCandidates.first)
    let calls = LoadCalls()
    let unsupported = try await CopilotImageSupport.prepare(selectedImageID: selected.id, context: original,
      unavailableReason: "Model has no vision", authorize: { true }, load: { url in await calls.record(url); return try Self.image() })
    #expect(await calls.urls.isEmpty)
    #expect(unsupported.image == nil)
    #expect(unsupported.evidence?.text.contains("Image not inspected: Model has no vision") == true)
    let failed = try await CopilotImageSupport.prepare(selectedImageID: selected.id, context: original,
      unavailableReason: nil, authorize: { true }, load: { _ in throw TestError.loadFailed })
    #expect(failed.image == nil)
    #expect(failed.evidence?.text.contains("Available text and attachment metadata only") == true)
    #expect(original.imageCandidates.first?.altText == "First supplied description")
  }

  @Test func cancellationAfterImageLoadCannotBecomeFallbackOrEvidence() async {
    let original = context()
    let task = Task {
      try await CopilotImageSupport.prepare(selectedImageID: original.imageCandidates.first?.id,
        context: original, unavailableReason: nil, authorize: { true }, load: { _ in
          withUnsafeCurrentTask { $0?.cancel() }
          return try Self.image()
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func loaderRestrictsURLBytesAndDimensionsAndRejectsAnimatedOrInvalidData() throws {
    #expect(CopilotImageSupport.isAllowedURL(URL(string: "https://example.test/image")!))
    #expect(!CopilotImageSupport.isAllowedURL(URL(string: "file:///tmp/image.png")!))
    #expect(!CopilotImageSupport.isAllowedURL(URL(string: "https://user:password@example.test/image")!))
    #expect(throws: (any Error).self) { try CopilotImageSupport.decodeThumbnail(Data("not an image".utf8)) }
    #expect(throws: (any Error).self) {
      try CopilotImageSupport.decodeThumbnail(Data(repeating: 0, count: CopilotImageSupport.maximumDownloadBytes + 1))
    }
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try Self.image(width: 2_048, height: 1_024), nil)
    #expect(CGImageDestinationFinalize(destination))
    let decoded = try CopilotImageSupport.decodeThumbnail(data as Data)
    #expect(decoded.width <= CopilotImageSupport.maximumImageDimension)
    #expect(decoded.height <= CopilotImageSupport.maximumImageDimension)
    let animated = NSMutableData()
    let gif = try #require(CGImageDestinationCreateWithData(animated, "com.compuserve.gif" as CFString, 2, nil))
    let animationProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
    CGImageDestinationSetProperties(gif, animationProperties as CFDictionary)
    let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]]
    // Distinct, timed frames prevent the encoder from coalescing this fixture
    // into a still image. Qualify the fixture itself before testing rejection.
    CGImageDestinationAddImage(gif, try Self.image(gray: 0), frameProperties as CFDictionary)
    CGImageDestinationAddImage(gif, try Self.image(gray: 1), frameProperties as CFDictionary)
    #expect(CGImageDestinationFinalize(gif))
    let animatedSource = try #require(CGImageSourceCreateWithData(animated as CFData, nil))
    try #require(CGImageSourceGetCount(animatedSource) == 2)
    #expect(throws: (any Error).self) { try CopilotImageSupport.decodeThumbnail(animated as Data) }
  }

  @Test func imageCostTrimsWholePairsAndFallbackIsRecountedWithoutImage() async throws {
    let prepared = CopilotPreparedImage(candidate: context().imageCandidates.first, image: try Self.image(),
      evidence: .init(origin: "selected_image", text: "Inspected", sources: [], wasTruncated: false))
    let turns = (0..<4).map { index in
      CopilotStoredTurn(role: index.isMultiple(of: 2) ? .user : .assistant, text: "Turn",
                        createdAt: Date(timeIntervalSince1970: Double(index)))
    }
    let trimmed = try await CopilotImageSupport.selectHistory(turns: turns, preparedImage: prepared,
      modelContextSize: 4_096, reservedTokenCount: 1_000, candidateTokenCount: { history, image in
        100 + history.count * 700 + (image.image == nil ? 0 : 1_000)
      })
    #expect(trimmed.image.image != nil)
    #expect(trimmed.history.retainedTurns.map(\.id) == Array(turns.suffix(2)).map(\.id))
    let fallback = try await CopilotImageSupport.selectHistory(turns: turns, preparedImage: prepared,
      modelContextSize: 4_096, reservedTokenCount: 1_000, candidateTokenCount: { history, image in
        if image.image == nil {
          #expect(image.evidence?.text.contains("Image not inspected") == true)
          return 100 + history.count * 700
        }
        return 4_000 + history.count * 700
      })
    #expect(fallback.history.fits)
    #expect(fallback.image.image == nil)
    #expect(fallback.image.evidence?.text.contains("context budget") == true)
    #expect(fallback.history.retainedTurns.count == 4)
  }

  @Test func cancellationDuringImageTokenCountingStopsBeforeFallback() async throws {
    let prepared = CopilotPreparedImage(candidate: nil, image: try Self.image(), evidence: nil)
    let task = Task {
      try await CopilotImageSupport.selectHistory(turns: [], preparedImage: prepared,
        modelContextSize: 4_096, reservedTokenCount: 1_000, candidateTokenCount: { _, _ in
          withUnsafeCurrentTask { $0?.cancel() }
          return 4_000
        })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func oldHistoryDecodesAndSelectedIdentityRoundTripsWithoutBytes() throws {
    let id = UUID()
    let old = Data("{\"id\":\"\(id.uuidString)\",\"role\":\"user\",\"text\":\"Describe it\",\"createdAt\":0}".utf8)
    let legacy = try JSONDecoder().decode(CopilotStoredTurn.self, from: old)
    #expect(legacy.selectedImageID == nil)
    let selected = CopilotStoredTurn(role: .user, text: "Describe this", selectedImageID: context().imageCandidates.first?.id)
    let data = try JSONEncoder().encode(selected)
    let roundTrip = try JSONDecoder().decode(CopilotStoredTurn.self, from: data)
    #expect(roundTrip.selectedImageID == selected.selectedImageID)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["image"] == nil && object["imageData"] == nil && object["attachment"] == nil)
  }

  @Test func standaloneGenerationGuardRejectsChangedTokens() throws {
    var generation = CopilotTurnGeneration()
    let original = generation.advance()
    try generation.check(original)
    // Unit coverage of the guard; actor lifecycle coverage lives in CopilotAgentTurnIntegrationTests.
    for _ in 0..<3 {
      _ = generation.advance()
      #expect(throws: CancellationError.self) { try generation.check(original) }
      try generation.check(generation.value)
    }
  }

  @Test func generationCheckRespectsTaskCancellation() async {
    let task = Task {
      var generation = CopilotTurnGeneration()
      let original = generation.advance()
      withUnsafeCurrentTask { $0?.cancel() }
      try generation.check(original)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  private func context() -> CopilotContext {
    let uri = "at://did:plc:a/app.bsky.feed.post/1"
    let evidence = CopilotPostEvidence(
      selectedPost: .init(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Selected", media: [
        .init(kind: .image, altText: "First supplied description", thumbnailURL: URL(string: "https://example.test/first")),
        .init(kind: .video, altText: "Video description"),
        .init(kind: .image, altText: "Third supplied description", thumbnailURL: URL(string: "https://example.test/third"))
      ]),
      quotedPosts: [.init(uri: "at://did:plc:q/app.bsky.feed.post/2", media: [.init(kind: .image, altText: "Quoted")])],
      coverage: ["Supplied metadata only"]
    )
    return .post(uri: uri, cid: "cid", authorDID: "did:plc:a", text: "Selected", evidence: evidence)
  }

  private static func image(width: Int = 2, height: Int = 2, gray: CGFloat = 0.5) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return try #require(context.makeImage())
  }

  private actor LoadCalls {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
  }
  private enum TestError: Error { case loadFailed }
}
