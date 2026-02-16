import Foundation
import OSLog
import WebKit

// MARK: - TileURLSchemeHandler

/// Serves tile resources from local cache via a custom URL scheme
/// Each tile gets a unique scheme (e.g., tile-{cid}://) for origin isolation
@available(iOS 26.0, macOS 26.0, *)
struct TileURLSchemeHandler: URLSchemeHandler {
  typealias TaskSequence = AsyncThrowingStream<URLSchemeTaskResult, Error>

  private let resources: [String: CachedTileResource]
  private let logger = Logger(subsystem: "blue.catbird", category: "TileURLSchemeHandler")

  init(resources: [String: CachedTileResource]) {
    self.resources = resources
  }

  func reply(for request: URLRequest) -> TaskSequence {
    let resources = self.resources

    return AsyncThrowingStream { continuation in
      let path = request.url?.path ?? "/"
      let normalizedPath = path.isEmpty ? "/" : path

      guard let resource = resources[normalizedPath] else {
        let errorResponse = HTTPURLResponse(
          url: request.url ?? URL(string: "about:blank")!,
          statusCode: 404,
          httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "text/plain"]
        )!
        continuation.yield(.response(errorResponse))
        continuation.yield(.data("Not Found".data(using: .utf8)!))
        continuation.finish()
        return
      }

      guard
        let response = TileSecurityPolicy.secureResponse(
          url: request.url ?? URL(string: "about:blank")!,
          contentType: resource.contentType,
          contentLength: resource.data.count
        )
      else {
        continuation.finish()
        return
      }

      continuation.yield(.response(response))
      continuation.yield(.data(resource.data))
      continuation.finish()
    }
  }

  /// Generate the custom URL scheme for a tile CID
  static func scheme(for tileCID: String) -> String {
    let sanitized = tileCID
      .replacingOccurrences(of: ":", with: "")
      .prefix(16)
    return "tile-\(sanitized)"
  }
}
