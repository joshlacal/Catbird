//
//  OfflineFixtureURLProtocol.swift
//  Catbird
//
//  Fail-loud URLProtocol for offline `-CatbirdCatalog`, preview-fixture, and
//  snapshot-testing sessions. Serves harvested verbatim XRPC JSON and
//  deterministic local placeholder PNGs, and records/rejects any unhandled
//  request so accidental live network calls never slip past visual QA.
//

#if DEBUG
import CoreGraphics
import Foundation
import ImageIO
import Nuke
import OSLog
@testable import Petrel
import UniformTypeIdentifiers

final class OfflineFixtureURLProtocol: URLProtocol, @unchecked Sendable {

  struct RecordedRequest: Sendable, Equatable {
    let method: String
    let url: String
    let handled: Bool
    let reason: String
  }

  private struct RGBSwatch: Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
  }

  private static let logger = Logger(subsystem: "blue.catbird", category: "OfflineFixtureURLProtocol")
  private static let lock = NSLock()
  nonisolated(unsafe) private static var isStrictMode = true
  nonisolated(unsafe) private static var customXRPCResponses: [String: Data] = [:]
  nonisolated(unsafe) private static var recorded: [RecordedRequest] = []
  nonisolated(unsafe) private static var unexpectedHandler: (@Sendable (URLRequest) -> Void)?
  nonisolated(unsafe) private static var installed = false
  nonisolated(unsafe) private static var imageCache: [UInt32: Data] = [:]

  /// Neutral-warm editorial swatches intentionally outside the blue hue band (205..225 deg)
  /// so deterministic placeholder images never false-trigger accent-leak pixel scanners.
  private static let swatchPalette: [RGBSwatch] = [
    RGBSwatch(red: 214, green: 206, blue: 198),
    RGBSwatch(red: 192, green: 186, blue: 178),
    RGBSwatch(red: 176, green: 184, blue: 174),
    RGBSwatch(red: 204, green: 188, blue: 176),
    RGBSwatch(red: 184, green: 178, blue: 188),
    RGBSwatch(red: 198, green: 194, blue: 184)
  ]

  /// Installs this protocol into Foundation URL loading, Petrel's `NetworkService`,
  /// and `Nuke.ImagePipeline.shared` so neither API nor media requests leave the device.
  static func install(
    strict: Bool = true,
    customResponses: [String: Data] = [:],
    onUnexpectedRequest: (@Sendable (URLRequest) -> Void)? = nil
  ) async {
    lock.withLock {
      isStrictMode = strict
      customXRPCResponses = customResponses
      unexpectedHandler = onUnexpectedRequest
      recorded.removeAll(keepingCapacity: true)
    }

    _ = URLProtocol.registerClass(OfflineFixtureURLProtocol.self)
    await NetworkService.setNetworkTestProtocolClasses([OfflineFixtureURLProtocol.self])

    let shouldConfigureImagePipeline = lock.withLock { () -> Bool in
      let needsInstall = !installed
      installed = true
      return needsInstall
    }
    if shouldConfigureImagePipeline {
      let sessionConfig = URLSessionConfiguration.ephemeral
      sessionConfig.protocolClasses = [OfflineFixtureURLProtocol.self]
      sessionConfig.urlCache = nil
      sessionConfig.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
      var pipelineConfig = ImagePipeline.Configuration()
      pipelineConfig.dataLoader = DataLoader(configuration: sessionConfig)
      pipelineConfig.imageCache = ImageCache(costLimit: 1024 * 1024 * 32)
      ImagePipeline.shared = ImagePipeline(configuration: pipelineConfig)
    }
  }

  /// Clears recorded request logs and optional custom overrides.
  static func reset(clearCustomResponses: Bool = false) {
    lock.withLock {
      recorded.removeAll(keepingCapacity: true)
      if clearCustomResponses {
        customXRPCResponses.removeAll(keepingCapacity: true)
      }
    }
  }

  /// Registers a custom raw JSON payload for an XRPC method (e.g. `app.bsky.feed.getTimeline`).
  static func setResponse(_ data: Data, forXRPCMethod method: String) {
    lock.withLock {
      customXRPCResponses[method] = data
    }
  }

  /// All requests observed since installation/reset.
  static var recordedRequests: [RecordedRequest] {
    lock.withLock { recorded }
  }

  /// Unhandled requests that attempted to reach the live network.
  static var unhandledRequests: [RecordedRequest] {
    lock.withLock { recorded.filter { !$0.handled } }
  }

  // MARK: - URLProtocol

  override static func canInit(with request: URLRequest) -> Bool {
    guard let scheme = request.url?.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let httpMethod = request.httpMethod ?? "GET"

    if Self.isMediaURL(url) {
      let pngData = Self.deterministicPNG(for: url.absoluteString)
      Self.record(method: httpMethod, url: url.absoluteString, handled: true, reason: "deterministic-image")
      deliver(data: pngData, url: url, contentType: "image/png")
      return
    }

    if let (xrpcMethod, data) = Self.resolveXRPC(url: url) {
      Self.record(method: httpMethod, url: url.absoluteString, handled: true, reason: "xrpc:\(xrpcMethod)")
      deliver(data: data, url: url, contentType: "application/json")
      return
    }

    Self.record(method: httpMethod, url: url.absoluteString, handled: false, reason: "unhandled-offline")
    let (strict, handler) = Self.lock.withLock { (Self.isStrictMode, Self.unexpectedHandler) }
    Self.logger.error(
      "[OfflineFixtureURLProtocol] Blocked unhandled network request (\(strict ? "strict" : "relaxed", privacy: .public)): \(httpMethod, privacy: .public) \(url.absoluteString, privacy: .public)"
    )
    handler?(request)
    client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
  }

  override func stopLoading() {}

  // MARK: - Helpers

  private func deliver(data: Data, url: URL, contentType: String) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: [
        "Content-Type": contentType,
        "Content-Length": "\(data.count)"
      ]
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func resolveXRPC(url: URL) -> (String, Data)? {
    guard url.path.hasPrefix("/xrpc/") else { return nil }
    let xrpcMethod = String(url.path.dropFirst("/xrpc/".count))
    let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let overrideData = lock.withLock { customXRPCResponses[xrpcMethod] }
    guard let data = overrideData ?? PreviewFixtures.rawData(forXRPCMethod: xrpcMethod, queryItems: queryItems) else {
      return nil
    }
    return (xrpcMethod, data)
  }

  private static func record(method: String, url: String, handled: Bool, reason: String) {
    lock.withLock {
      recorded.append(RecordedRequest(method: method, url: url, handled: handled, reason: reason))
    }
  }

  private static func isMediaURL(_ url: URL) -> Bool {
    let host = (url.host ?? "").lowercased()
    let path = url.path.lowercased()
    if host.contains("cdn.bsky.app") || host.contains("video.bsky.app") || host.contains("av-cdn.bsky.app") {
      return true
    }
    if path.contains("/img/avatar") || path.contains("/img/banner") || path.contains("/img/feed_") {
      return true
    }
    let ext = url.pathExtension.lowercased()
    return ext == "png" || ext == "jpg" || ext == "jpeg" || ext == "webp" || ext == "gif" || ext == "avif"
  }

  /// Generates a deterministic, neutral-toned 64×64 PNG keyed by a stable FNV-1a hash of the URL.
  static func deterministicPNG(for key: String) -> Data {
    var hash: UInt32 = 2_166_136_261
    for byte in key.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    let bucket = hash % UInt32(swatchPalette.count)

    if let cached = lock.withLock({ imageCache[bucket] }) {
      return cached
    }

    let swatch = swatchPalette[Int(bucket)]
    let encoded = encodeSwatchPNG(swatch: swatch, dimension: 64)
    lock.withLock {
      imageCache[bucket] = encoded
    }
    return encoded
  }

  private static func encodeSwatchPNG(swatch: RGBSwatch, dimension: Int) -> Data {
    var pixels = [UInt8](repeating: 255, count: dimension * dimension * 4)
    for row in 0..<dimension {
      for column in 0..<dimension {
        let offset = (row * dimension + column) * 4
        let delta: Int = ((column / 16) + (row / 16)) % 2 == 0 ? 0 : -10
        pixels[offset] = UInt8(clamping: Int(swatch.red) + delta)
        pixels[offset + 1] = UInt8(clamping: Int(swatch.green) + delta)
        pixels[offset + 2] = UInt8(clamping: Int(swatch.blue) + delta)
        pixels[offset + 3] = 255
      }
    }

    let output = NSMutableData()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard
      let provider = CGDataProvider(data: Data(pixels) as CFData),
      let cgImage = CGImage(
        width: dimension,
        height: dimension,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: dimension * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ),
      let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
    else {
      return Data()
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
  }
}
#endif
