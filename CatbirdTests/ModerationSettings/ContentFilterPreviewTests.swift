import Foundation
import Petrel
import Testing

@testable import Catbird

// The Content Preview section states the moderation engine's own decision for a
// sample post with each builtin label, so it can never disagree with feeds.

private func prefs(_ stored: [String: String] = [:], adult: Bool = true) -> ModerationPrefs {
  ModerationPrefs(
    adultContentEnabled: adult,
    contentLabelPrefs: stored.map { ContentLabelPreference(labelerDid: nil, label: $0.key, visibility: $0.value) },
    labelerDIDs: [])
}

@Suite("Content filter preview")
struct ContentFilterPreviewTests {
  @Test("Defaults with adult content on")
  func defaults() {
    let prefs = prefs()
    #expect(ContentFilterPreview.outcome(for: "porn", prefs: prefs) == .removedFromFeeds(canRevealMedia: true))
    #expect(ContentFilterPreview.outcome(for: "sexual", prefs: prefs) == .mediaBlurred(canReveal: true))
    #expect(ContentFilterPreview.outcome(for: "graphic-media", prefs: prefs) == .mediaBlurred(canReveal: true))
    #expect(ContentFilterPreview.outcome(for: "nudity", prefs: prefs) == .shown)
  }

  @Test("Each preference maps to the engine's outcome", arguments: ["porn", "sexual", "graphic-media", "nudity"])
  func eachPreference(identifier: String) {
    #expect(ContentFilterPreview.outcome(for: identifier, prefs: prefs([identifier: "ignore"])) == .shown)
    #expect(ContentFilterPreview.outcome(for: identifier, prefs: prefs([identifier: "warn"])) == .mediaBlurred(canReveal: true))
    #expect(ContentFilterPreview.outcome(for: identifier, prefs: prefs([identifier: "hide"])) == .removedFromFeeds(canRevealMedia: true))
  }

  @Test("Adult-only labels are removed and can't be revealed while adult content is off")
  func adultOff() {
    let prefs = prefs(["porn": "ignore", "sexual": "ignore", "graphic-media": "ignore", "nudity": "warn"], adult: false)
    for identifier in ["porn", "sexual", "graphic-media"] {
      #expect(ContentFilterPreview.outcome(for: identifier, prefs: prefs) == .removedFromFeeds(canRevealMedia: false))
    }
    #expect(ContentFilterPreview.outcome(for: "nudity", prefs: prefs) == .mediaBlurred(canReveal: true))
  }

  @Test("The preview agrees with the policy's decision for a real post shape")
  func agreesWithEngineUI() throws {
    let prefs = prefs(["sexual": "hide"])
    let label = ComAtprotoLabelDefs.Label(
      src: try DID(didString: ModerationPrefs.blueskyModerationDID),
      uri: URI(uriString: "at://did:plc:someone/app.bsky.feed.post/abc"), val: "sexual",
      cts: ATProtocolDate(date: Date()))
    var decision = ModerationDecision(did: "did:plc:someone")
    decision.addLabel(label, target: .content, options: ModerationOptions(userDID: "did:plc:viewer", prefs: prefs))
    #expect(decision.ui(.contentList).filter)
    #expect(decision.ui(.contentMedia).blur && !decision.ui(.contentMedia).noOverride)
    #expect(!decision.ui(.contentView).blur)
    #expect(ContentFilterPreview.outcome(for: "sexual", prefs: prefs) == .removedFromFeeds(canRevealMedia: true))
  }

  @Test("Summaries never claim post text is hidden by a media label")
  func summaries() {
    let outcomes: [ContentFilterPreview.Outcome] = [
      .shown, .mediaBlurred(canReveal: true), .mediaBlurred(canReveal: false),
      .removedFromFeeds(canRevealMedia: true), .removedFromFeeds(canRevealMedia: false),
    ]
    #expect(Set(outcomes.map(\.summary)).count == outcomes.count)
    #expect(outcomes.allSatisfy { !$0.summary.localizedCaseInsensitiveContains("text is hidden") })
  }
}
