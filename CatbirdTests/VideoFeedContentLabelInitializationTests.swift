import Foundation
import Petrel
import SwiftUI
import Testing
@testable import Catbird

@MainActor
@Suite("Video content label initialization")
struct VideoFeedContentLabelInitializationTests {
  @Test("Record self-labels gate media before preferences load", arguments: [
    ("porn", ContentVisibility.hide),
    ("SEXUAL", ContentVisibility.hide),
    ("graphic-media", ContentVisibility.warn),
    ("NuDiTy", ContentVisibility.warn),
    ("bot-account", ContentVisibility.show)
  ])
  func selfLabelsApplyImmediately(value: String, expected: ContentVisibility) {
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: nil, selfLabelValues: [value]
    ) == expected)
  }

  @Test("Server and self labels preserve the most restrictive initial policy")
  func mixedLabels() throws {
    let warning = ComAtprotoLabelDefs.Label(
      src: try DID(didString: "did:plc:labeltest"),
      uri: try URI(uriString: "at://example.test/app.bsky.feed.post/test"),
      val: "graphic",
      cts: ATProtocolDate(date: Date(timeIntervalSince1970: 0))
    )
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: [warning], selfLabelValues: ["porn"]
    ) == .hide)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(
      labels: [warning], selfLabelValues: ["bot-account"]
    ) == .warn)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(labels: [warning]) == .warn)
    #expect(ContentLabelManager<EmptyView>.getInitialContentVisibility(labels: nil) == .show)
  }
}
