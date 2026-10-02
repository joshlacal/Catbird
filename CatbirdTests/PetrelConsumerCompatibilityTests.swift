import Foundation
import Testing
@testable import Catbird

@Suite("Petrel consumer compatibility")
struct PetrelConsumerCompatibilityTests {
  @Test("Web links remain routable with mixed-case schemes, ports, and escapes", arguments: [
    "HTTPS://example.com:8443/a%2Fb?value=a%26b",
    "http://example.com/hello",
    "https://user:password@example.com:8443/a%2Fb",
  ])
  func webSchemes(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(URLSchemePolicy.isWeb(url))
    #expect(URLSchemePolicy.allowsSystemOpen(url))
    #expect(!URLSchemePolicy.isBluesky(url))
  }

  @Test("Communication links use system handling", arguments: [
    "mailto:person@example.com", "tel:+15551234567", "SMS:+15551234567",
  ])
  func communicationSchemes(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(URLSchemePolicy.allowsSystemOpen(url))
    #expect(!URLSchemePolicy.isWeb(url))
    #expect(!URLSchemePolicy.isBluesky(url))
  }

  @Test("Unsupported schemes cannot escape the allowlist through a trusted host", arguments: [
    "javascript:alert(1)", "data:text/html,hello", "file:///tmp/test.html",
    "otherapp://open", "javascript://bsky.app/profile/example.com",
    "file://bsky.app/profile/example.com", "tel://bsky.app/profile/example.com",
  ])
  func unsupportedSchemes(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    if url.scheme?.lowercased() != "tel" {
      #expect(!URLSchemePolicy.allowsSystemOpen(url))
    }
    #expect(!URLSchemePolicy.isWeb(url))
    #expect(!URLSchemePolicy.isBluesky(url))
  }

  @Test("Bluesky routing accepts web and internal schemes", arguments: [
    "HTTPS://BSKY.APP/profile/example.com", "http://bsky.app/profile/example.com",
    "https://go.bsky.app/abc", "BLUESKY://profile/example.com",
  ])
  func blueskySchemes(_ raw: String) throws {
    let url = try #require(URL(string: raw))
    #expect(URLSchemePolicy.isBluesky(url))
  }

  @Test("Both decoder and transport cancellation stay silent and are never retried")
  func cancellationClassification() {
    let errors: [Error] = [CancellationError(), URLError(.cancelled)]
    for error in errors {
      #expect(error.isCancellation)
      #expect(!error.shouldShowToUser)
      #expect(!error.isRecoverable)
      #expect(FeedErrorHandler.retryDelay(for: error, attempt: 3) == 0)
    }
  }

  @Test("Genuine failures remain visible")
  func genuineFailureClassification() {
    let error = NSError(domain: "PetrelConsumerCompatibility", code: 503)
    #expect(!error.isCancellation)
    #expect(error.shouldShowToUser)
  }
}
