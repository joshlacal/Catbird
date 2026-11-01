#if os(iOS)
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

/// Pins the product route, rather than a bare linked `Text`: iOS 26 must offer Tight and draw
/// post links at the same shortened height as plain text.
@MainActor
@Suite("Tappable post line height", .serialized)
struct TappableTextViewLineHeightTests {
  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  @Test("Tight remains available on iOS 26")
  func tightIsAvailableOnIOS26() {
    guard #available(iOS 26.0, *) else { return }
    #expect(FontManager.supportsLineHeight)
    #expect(FontManager.lineSpacingOptions(supportsLineHeight: FontManager.supportsLineHeight)
      .contains { $0.value == "tight" })
    #expect(FontManager.displayedLineSpacing("tight", supportsLineHeight: FontManager.supportsLineHeight) == "tight")
  }

  @Test("Tight shortens the real plain and linked post view equally on iOS 26 and later",
    arguments: [CGFloat?.none, 15, 22])
  func tightShortensLinkedPosts(textSize: CGFloat?) async throws {
    guard #available(iOS 26.0, *) else { return }
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://tight-post.invalid")))
    let appState = AppState(userDID: "did:plc:tightpost", client: client, regulatoryChecker: NoAgePrompt())
    let scene = SceneNavigationContext(appState: appState, sceneID: UUID())
    defer {
      scene.invalidate()
      appState.cleanup()
    }
    let copy = "First line of a post\nHello @alice.test today\nVisit example.test now\nLast line with gjpqy"
    let plain = AttributedString(copy)
    var linked = plain
    linked[try #require(linked.range(of: "@alice.test"))].link = URL(string: "mention://did%3Aplc%3Aalice")
    linked[try #require(linked.range(of: "example.test"))].link = URL(string: "https://example.test")

    func height(_ text: AttributedString, spacing: String) -> CGFloat {
      let manager = FontManager()
      manager.lineSpacing = spacing
      manager.dynamicTypeEnabled = false
      let host = UIHostingController(rootView:
        TappableTextView(attributedString: text, textSize: textSize)
          .environment(appState)
          .environment(scene)
          .environment(\.fontManager, manager)
          .fixedSize(horizontal: false, vertical: true))
      return host.sizeThatFits(in: CGSize(width: 360, height: CGFloat.greatestFiniteMagnitude)).height
    }

    let normal = height(plain, spacing: "normal")
    let tightPlain = height(plain, spacing: "tight")
    let tightLinked = height(linked, spacing: "tight")
    #expect(tightPlain < normal - 4, "plain Tight \(tightPlain), Normal \(normal)")
    #expect(tightLinked < normal - 4, "linked Tight \(tightLinked), Normal \(normal)")
    #expect(abs(tightLinked - tightPlain) <= 0.34,
      "same post: linked Tight \(tightLinked), plain Tight \(tightPlain)")
  }

  @Test("Tight's native adapter retains link destinations and chosen link presentation",
    arguments: ["disabled", "color", "underline", "both"])
  func nativeAdapterRetainsLinkStyles(style: String) throws {
    let font = UIFont.systemFont(ofSize: 17)
    var text = AttributedString("ÁÉ 👩🏽‍💻\n@alice.test #swift example.test\ngjpqy")
    let links = [
      ("@alice.test", "mention://did%3Aplc%3Aalice"),
      ("#swift", "tag://swift"),
      ("example.test", "https://example.test"),
    ]
    for (token, destination) in links {
      text[try #require(text.range(of: token))].link = URL(string: destination)
    }
    text = text.applyingPostBodyLinkAccent(highlightLinks: style != "disabled", linkStyle: style)
    let output = TightLinkedPostText.makeText(text, font: font, color: .black, kerning: 0.2, factor: 1.075)
    #expect(output.string == String(text.characters))
    for (token, destination) in links {
      let location = (output.string as NSString).range(of: token).location
      #expect(output.attribute(.link, at: location, effectiveRange: nil) == nil)
      #expect(output.attribute(.feedLink, at: location, effectiveRange: nil) as? URL == URL(string: destination))
      let underlined = output.attribute(.underlineStyle, at: location, effectiveRange: nil) as? Int
      #expect((underlined == NSUnderlineStyle.single.rawValue) == (style == "underline" || style == "both"))
      let color = try #require(output.attribute(.foregroundColor, at: location, effectiveRange: nil) as? UIColor)
      if style == "disabled" || style == "underline" {
        #expect(color.isEqual(UIColor.black))
      } else {
        #expect(!color.isEqual(UIColor.black))
      }
    }
    #expect(output.attribute(.feedLink, at: 0, effectiveRange: nil) == nil)
    let paragraph = try #require(output.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(abs(paragraph.minimumLineHeight - 18.275) < 0.001)
    #expect(paragraph.maximumLineHeight == paragraph.minimumLineHeight)
  }

  @Test("The adapter preserves explicit attributed fonts and colors")
  func nativeAdapterRetainsRunFormatting() throws {
    guard #available(iOS 26.0, *) else { return }
    var text = AttributedString("Styled @alice.test")
    let range = try #require(text.range(of: "Styled"))
    text[range].font = .system(size: 21, weight: .semibold, design: .serif)
    text[range].foregroundColor = .red
    let output = TightLinkedPostText.makeText(
      text, font: .systemFont(ofSize: 17), color: .black, kerning: 0, factor: 1.075,
      fontContext: EnvironmentValues().fontResolutionContext)
    let styledFont = try #require(output.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(abs(styledFont.pointSize - 21) < 0.001)
    #expect((output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor)?.isEqual(UIColor(Color.red)) == true)
    let ordinaryFont = try #require(output.attribute(.font, at: 8, effectiveRange: nil) as? UIFont)
    #expect(ordinaryFont.pointSize == 17)
  }

  @Test("The hosted Tight adapter draws first-line accents and final descenders whole")
  func hostedAdapterDoesNotClipInk() async throws {
    guard #available(iOS 26.0, *) else { return }
    if #available(iOS 27.0, *) { return }
    let manager = FontManager()
    manager.lineSpacing = "tight"
    manager.dynamicTypeEnabled = false
    let plain = AttributedString("ÁÉÍ 👩🏽‍💻 Ångström\nmiddle line\nlast gjpqy")
    var linked = plain
    linked[try #require(linked.range(of: "middle"))].link = URL(string: "https://example.test")
    func pixels(_ text: AttributedString) async throws -> RenderedPixels {
      let host = UIHostingController(rootView:
        PostAttributedText(text, textColor: .black)
          .appFont(size: 17)
          .foregroundStyle(.black)
          .fixedSize(horizontal: false, vertical: true)
          .padding(12)
          .ignoresSafeArea()
          .environment(\.fontManager, manager)
          .environment(\.colorScheme, .light))
      let size = host.sizeThatFits(in: CGSize(width: 324, height: CGFloat.greatestFiniteMagnitude))
      host.view.frame = CGRect(origin: .zero, size: size)
      let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(origin: .zero, size: size)
      window.rootViewController = host
      window.isHidden = false
      defer { window.isHidden = true; window.rootViewController = nil }
      window.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
      host.view.layoutIfNeeded()
      return try RenderedPixels(of: host.view, scale: 3)
    }
    let reference = try await pixels(plain)
    let native = try await pixels(linked)
    #expect(reference.darkPixelCount() > 1000)
    #expect(native.darkPixelCount() > 1000)
    let expectedBands = reference.inkRows()
    let drawnBands = native.inkRows()
    let first = (try #require(expectedBands.first), try #require(drawnBands.first))
    let last = (try #require(expectedBands.last), try #require(drawnBands.last))
    #expect(abs(first.0.lowerBound - first.1.lowerBound) <= 1)
    #expect(abs(last.0.upperBound - last.1.upperBound) <= 1)
  }

  /// Exercises the actual iOS 26 branch and its environment URL handler. A plain `Text` or a
  /// representable that loses `.feedLink` would not provide these link actions or hit regions.
  @Test("The hosted Tight adapter forwards taps and VoiceOver links through openURL",
    arguments: [false, true])
  func hostedLinksForwardURLs(rightToLeft: Bool) async throws {
    guard #available(iOS 26.0, *) else { return }
    if #available(iOS 27.0, *) { return }
    var text = AttributedString(rightToLeft ? "مرحبا @alice.test\nتابع #swift" : "Hello @alice.test\nFollow #swift")
    let mention = try #require(URL(string: "mention://did%3Aplc%3Aalice"))
    let tag = try #require(URL(string: "tag://swift"))
    text[try #require(text.range(of: "@alice.test"))].link = mention
    text[try #require(text.range(of: "#swift"))].link = tag
    let manager = FontManager()
    manager.lineSpacing = "tight"
    var opened: [URL] = []
    let host = UIHostingController(rootView:
      PostAttributedText(text)
        .appFont(AppTextRole.body)
        .environment(\.fontManager, manager)
        .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.dynamicTypeSize, .xxxLarge)
        .environment(\.openURL, OpenURLAction { url in opened.append(url); return .handled }))
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 360, height: 200)
    window.rootViewController = host
    window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil }
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(50))
    host.view.layoutIfNeeded()
    func findText(in view: UIView) -> FeedPostTextView? {
      if let text = view as? FeedPostTextView { return text }
      return view.subviews.lazy.compactMap { findText(in: $0) }.first
    }
    let native = try #require(findText(in: host.view))
    native.layoutIfNeeded()
    #expect(native.effectiveUserInterfaceLayoutDirection == (rightToLeft ? .rightToLeft : .leftToRight))
    #expect(native.accessibilityCustomActions?.map(\.name) == ["@alice.test", "#swift"])
    for url in [mention, tag] {
      let point = try #require((0..<Int(native.bounds.height)).lazy.compactMap { y in
        (0..<Int(native.bounds.width)).lazy.map { x in CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5) }
          .first { native.link(at: $0) == url }
      }.first)
      native.activateLink(at: point)
    }
    #expect(opened == [mention, tag])
    let rotor = try #require(native.accessibilityCustomRotors?.first)
    let predicate = UIAccessibilityCustomRotorSearchPredicate()
    predicate.currentItem = UIAccessibilityCustomRotorItemResult(targetElement: native, targetRange: nil)
    predicate.searchDirection = .next
    let first = try #require(rotor.itemSearchBlock(predicate)?.targetElement as? UIAccessibilityElement)
    #expect(first.accessibilityTraits.contains(.link))
    #expect(first.accessibilityLabel == "@alice.test")
    #expect(first.accessibilityActivate())
    let action = try #require(native.accessibilityCustomActions?.last)
    #expect(action.actionHandler?(action) == true)
    #expect(opened == [mention, tag, mention, tag])
  }
}
#endif
