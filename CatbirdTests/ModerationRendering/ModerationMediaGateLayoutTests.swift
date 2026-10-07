#if canImport(UIKit)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit

@testable import Catbird

// The card media gate is at least the height of a media block and grows with
// its text, so a long explanation or a large type size never clips the title,
// the explanation or the Show button. The cover is laid out in a window at a
// fixed width and its rendered height is read back.

@MainActor
@Suite("Moderation rendering: media gate layout")
struct ModerationMediaGateLayoutTests {
  private typealias F = RenderingFixtures

  private static let width: CGFloat = 320

  /// The last height SwiftUI laid the cover out at.
  private final class MeasuredHeight: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CGFloat = 0
    var value: CGFloat {
      get { lock.withLock { stored } }
      set { lock.withLock { stored = newValue } }
    }
  }

  /// The height the card cover renders at `width`, hosted in a window of the
  /// test app's scene like the presentation suites do.
  private func coverHeight(_ moderationUI: ModerationUI) async throws -> CGFloat {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let measured = MeasuredHeight()
    let content = ModerationMediaGate(ui: moderationUI) { Color.clear }
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured.value = $0 }
      .frame(width: Self.width)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: Self.width, height: 1200)
    let controller = UIHostingController(rootView: content)
    controller.view.frame = window.bounds
    window.rootViewController = controller
    window.isHidden = false
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }
    try await Task.sleep(for: .milliseconds(80))
    window.layoutIfNeeded()
    controller.view.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(40))
    return measured.value
  }

  @Test("A short explanation keeps the media-block height; a long one grows the card")
  func cardCoverGrowsWithItsText() async throws {
    let short = PostModerationPresentation.make(
      post: try F.post(labels: [try F.label("porn")], embed: F.imageEmbed), policy: F.policy(labels: ["porn": "warn"])).media
    #expect(short.blur)
    let shortHeight = try await coverHeight(short)
    #expect(shortHeight >= 160 && shortHeight <= 220, "one line of explanation stays close to the media-block size: \(shortHeight)")

    let explanation = String(
      repeating: "This label marks episodes that give away the ending of a long-running series. ", count: 8)
    let policy = F.customLabelerPolicy(
      blurs: "media", severity: "none",
      locales: [
        ComAtprotoLabelDefs.LabelValueDefinitionStrings(
          lang: LanguageCodeContainer(languageCode: "en"), name: "Spoilers", description: explanation)
      ])
    let long = PostModerationPresentation.make(
      post: try F.post(labels: [try F.label("custom", src: F.customLabelerDID)], embed: F.imageEmbed), policy: policy).media
    #expect(long.blur)
    #expect(ModerationGateText.explanation(for: long) == explanation)
    let longHeight = try await coverHeight(long)
    #expect(longHeight > 240, "the cover grows with its explanation instead of clipping it: \(longHeight)")
    #expect(longHeight > shortHeight)
  }
}
#endif
