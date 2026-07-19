import Foundation
import Testing
import Petrel
@testable import Catbird

/// Canary for the Petrel lossless-decode round-trip guard regression.
///
/// Petrel 1.0.1's `ATProtocolValueContainer` demotes typed decodes to `.unknownType`
/// whenever the typed re-encode isn't byte-identical DAG-CBOR to the wire object.
/// Generated encoders frame nested defs with `$type` that real clients omit, so every
/// post record containing facets, media embeds, replies, or self-labels demotes — and
/// `PostView.detectPostError()` tombstones it as "Post format error".
///
/// Fix: https://github.com/joshlacal/Petrel/pull/22 (release as 1.0.2).
/// Re-enable this test once the app resolves a Petrel version containing that fix.
@Suite("Fixture record container decode (Petrel guard canary)")
struct FixtureRecordDiagTests {
  @Test(
    "Every fixture post record decodes to a known AppBskyFeedPost",
    .disabled("Blocked on Petrel PR #22 ($type framing round-trip guard) shipping as 1.0.2")
  )
  func everyPostRecordIsKnownType() throws {
    let posts = try #require(PreviewFixtures.postShapes?.posts)
    for post in posts {
      guard case .knownType(let value) = post.record, value is AppBskyFeedPost else {
        Issue.record("record demoted for \(post.uri.uriString()): \(post.record)")
        continue
      }
    }
  }
}
