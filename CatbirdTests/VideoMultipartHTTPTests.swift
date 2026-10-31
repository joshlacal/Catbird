import Foundation
#if !MULTIPART_HARNESS
import Testing
@testable import Catbird
#endif

enum VideoMultipartHTTPChecks {
  static func boundedAdapterAndCancellation() async throws {
    let client = URLSessionVideoHTTPClient(configuration: {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [OfflineVideoURLProtocol.self]
      return configuration
    })
    let (bytes, response) = try await client.perform(request("ok"), fileURL: nil, onProgress: nil)
    try VideoMultipartTransportChecks.verify(bytes == Data("{}".utf8) && response.statusCode == 200, "URLSession adapter returns local response")
    for mode in ["declared-large", "streamed-large"] {
      do {
        _ = try await client.perform(request(mode), fileURL: nil, onProgress: nil)
        throw CheckFailure("oversized response accepted")
      } catch let error as VideoMultipartTransportError {
        try VideoMultipartTransportChecks.verify(["InvalidResponse", "ResponseTooLarge"].contains(error.code ?? ""), "response byte cap returns typed failure")
      }
    }
    let operation = Task { try await client.perform(request("suspend"), fileURL: nil, onProgress: nil) }
    await OfflineVideoURLProtocol.started.wait()
    operation.cancel()
    do { _ = try await operation.value; throw CheckFailure("canceled URLSession request returned") }
    catch is CancellationError {}
  }

  private static func request(_ path: String) -> URLRequest {
    URLRequest(url: URL(string: "https://multipart-test.invalid/\(path)")!, timeoutInterval: 1)
  }
}

/// Handles every harness URL locally. No fixture can fall through to DNS or the network.
private final class OfflineVideoURLProtocol: URLProtocol, @unchecked Sendable {
  static let started = VideoTestGate()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    switch request.url!.lastPathComponent {
    case "suspend": Task { await Self.started.open() }
    case "declared-large":
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                          headerFields: ["Content-Length": "4194305"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocolDidFinishLoading(self)
    case "streamed-large":
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 4 * 1024 * 1024 + 1))
      client?.urlProtocolDidFinishLoading(self)
    default:
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "2"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data("{}".utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
  override func stopLoading() {}
}

#if !MULTIPART_HARNESS
@Suite("Multipart URLSession boundary")
struct VideoMultipartHTTPTests {
  @Test func localResponseBoundsAndCancellation() async throws { try await VideoMultipartHTTPChecks.boundedAdapterAndCancellation() }
}
#endif
