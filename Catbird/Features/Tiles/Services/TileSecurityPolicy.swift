import Foundation
import OSLog
import WebKit

// MARK: - TileSecurityPolicy

/// Generates HTTP response headers enforcing the DASL Web Tiles security model
/// See: https://dasl.ing/tiles.html#tile-execution-contexts
enum TileSecurityPolicy {
  /// CSP header value per the Web Tiles specification
  static let contentSecurityPolicy = [
    "default-src 'self' blob: data:",
    "script-src 'self' blob: data: 'unsafe-inline' 'wasm-unsafe-eval'",
    "script-src-attr 'none'",
    "style-src 'self' blob: data: 'unsafe-inline'",
    "form-src 'self'",
    "manifest-src 'none'",
    "object-src 'none'",
    "base-uri 'none'",
    "sandbox allow-downloads allow-forms allow-modals allow-popups allow-popups-to-escape-sandbox allow-same-origin allow-scripts",
  ].joined(separator: "; ")

  /// All security headers required by the tile spec
  static var securityHeaders: [String: String] {
    [
      "Content-Security-Policy": contentSecurityPolicy,
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Resource-Policy": "cross-origin",
      "Origin-Agent-Cluster": "?1",
      "Permissions-Policy": "interest-cohort=(), browsing-topics=()",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
      "X-DNS-Prefetch-Control": "off",
    ]
  }

  /// Create an HTTPURLResponse with tile security headers
  static func secureResponse(
    url: URL,
    contentType: String,
    contentLength: Int
  ) -> HTTPURLResponse? {
    var headers = securityHeaders
    headers["Content-Type"] = contentType
    headers["Content-Length"] = "\(contentLength)"

    return HTTPURLResponse(
      url: url,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )
  }
}
