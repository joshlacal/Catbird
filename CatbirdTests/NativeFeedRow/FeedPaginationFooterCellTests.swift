#if os(iOS)
import Foundation
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

// MARK: - Hosted Reference

/// The SwiftUI footer the feed hosted before `FeedPaginationFooterCell` replaced it, copied
/// unchanged as the reference the native cell must match.
private struct HostedFooterReference: View {
  let state: FeedPaginationFooterState
  let onRetry: () -> Void

  var body: some View {
    Group {
      switch state {
      case .loading:
        ProgressView()
          .accessibilityLabel("Loading more posts")
      case .failed:
        VStack(spacing: 8) {
          Text("Couldn’t load more posts.")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
          Button("Try Again", action: onRetry)
            .buttonStyle(.bordered)
        }
      case .end:
        Text("You’re all caught up")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(Color.secondary)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
  }
}

// MARK: - Feed Pagination Footer Cell Tests

@MainActor
@Suite("Feed pagination footer cell", .serialized)
struct FeedPaginationFooterCellTests {
  struct Size: Sendable, CustomTestStringConvertible {
    let contentSize: UIContentSizeCategory
    let width: CGFloat
    var testDescription: String { "\(contentSize.rawValue) at \(Int(width)) pt" }
  }

  static let states: [FeedPaginationFooterState] = [.loading, .failed, .end]
  /// Large and AX3 (`accessibilityExtraLarge`), each at a phone and a tablet width.
  static let sizes: [Size] = [
    Size(contentSize: .large, width: 390), Size(contentSize: .large, width: 834),
    Size(contentSize: .accessibilityExtraLarge, width: 390),
    Size(contentSize: .accessibilityExtraLarge, width: 834),
  ]

  // MARK: Helpers

  /// A window to lay cells out in: SwiftUI reports geometry and accessibility only for views in
  /// one. Cells sit at `cellY`, clear of the safe areas, which a hosted footer would inset.
  private func makeWindow() throws -> UIWindow {
    let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 834, height: 800)
    window.isHidden = false
    return window
  }

  private static let cellY: CGFloat = 200

  private func attributes(width: CGFloat) -> UICollectionViewLayoutAttributes {
    let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 0, section: 0))
    attributes.size = CGSize(width: width, height: 44)
    return attributes
  }

  /// The hosted footer, configured as the feed's footer registration configured it and laid out at
  /// `width`, with the frames of its content in its own coordinates. SwiftUI reports those frames
  /// through its accessibility elements, so callers enable app accessibility first.
  ///
  /// `height` is SwiftUI's own layout of the footer at `width` (`systemLayoutSizeFitting`);
  /// `selfSizedHeight` is what the hosting configuration answered to the list layout's self-sizing
  /// call (`preferredLayoutAttributesFitting`). The two agree while the message fits on one line;
  /// once it wraps, the self-sizing answer keeps a single line and SwiftUI draws the message
  /// truncated ("Couldn’t load more…"), a defect the native footer does not reproduce.
  private func hostedFooter(
    _ state: FeedPaginationFooterState, size: Size, fontManager: FontManager, in window: UIWindow
  ) async throws -> (height: CGFloat, selfSizedHeight: CGFloat, frames: [String: CGRect]) {
    let cell = UICollectionViewListCell(frame: CGRect(x: 0, y: Self.cellY, width: size.width, height: 44))
    window.addSubview(cell)
    defer { cell.removeFromSuperview() }
    cell.traitOverrides.preferredContentSizeCategory = size.contentSize
    cell.layoutMargins = .zero
    cell.directionalLayoutMargins = .zero
    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    cell.contentConfiguration = UIHostingConfiguration {
      HostedFooterReference(state: state, onRetry: {})
        .environment(\.fontManager, fontManager)
    }
    .margins(.all, 0)
    cell.updateTraitsIfNeeded()
    let selfSizedHeight = cell.preferredLayoutAttributesFitting(attributes(width: size.width)).size.height
    let height = cell.systemLayoutSizeFitting(
      CGSize(width: size.width, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel).height
    cell.frame = CGRect(x: 0, y: Self.cellY, width: size.width, height: height)
    let names = Self.contentNames(state)
    var elements: [AppAccessibility.Element] = []
    for _ in 0..<50 where elements.count < names.count {
      cell.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
      elements = AppAccessibility.elements(in: cell)
    }
    let frames = Dictionary(uniqueKeysWithValues: zip(names, elements.map(\.frame)))
    return (height, selfSizedHeight, frames)
  }

  /// The native footer configured for `state`, self-sized at `width` and laid out at that size.
  private func nativeFooter(
    _ state: FeedPaginationFooterState, size: Size, fontManager: FontManager,
    onRetry: @escaping @MainActor () -> Void = {}
  ) -> FeedPaginationFooterCell {
    let cell = FeedPaginationFooterCell(frame: CGRect(x: 0, y: 0, width: size.width, height: 44))
    cell.traitOverrides.preferredContentSizeCategory = size.contentSize
    cell.updateTraitsIfNeeded()
    cell.configure(state: state, fontManager: fontManager, onRetry: onRetry)
    let height = cell.preferredLayoutAttributesFitting(attributes(width: size.width)).size.height
    cell.frame = CGRect(x: 0, y: 0, width: size.width, height: height)
    cell.layoutIfNeeded()
    return cell
  }

  private static func contentNames(_ state: FeedPaginationFooterState) -> [String] {
    switch state {
    case .loading: ["spinner"]
    case .failed: ["failure", "retry"]
    case .end: ["end"]
    }
  }

  private static func nativeFrames(_ cell: FeedPaginationFooterCell) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    switch cell.state {
    case .loading:
      frames["spinner"] = cell.spinnerForTesting?.frame
    case .failed:
      frames["failure"] = cell.failureLabelForTesting?.frame
      frames["retry"] = cell.retryButtonForTesting.frame
    case .end:
      frames["end"] = cell.endLabelForTesting?.frame
    case nil:
      break
    }
    return frames
  }

  private func visibleViews(_ cell: FeedPaginationFooterCell) -> [UIView] {
    cell.contentView.subviews.filter { !$0.isHidden }
  }

  private func descendants(of view: UIView) -> [UIView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
  }

  // MARK: Content

  @Test("Each state shows the hosted footer's content, creating only the views it needs")
  func content() throws {
    let fontManager = FontManager()
    let size = Self.sizes[0]

    let loading = nativeFooter(.loading, size: size, fontManager: fontManager)
    let spinner = try #require(loading.spinnerForTesting)
    #expect(visibleViews(loading) == [spinner])
    #expect(loading.failureLabelForTesting == nil && loading.endLabelForTesting == nil)
    #expect(spinner.isAnimating)

    let failed = nativeFooter(.failed, size: size, fontManager: fontManager)
    let failure = try #require(failed.failureLabelForTesting)
    let retry = failed.retryButtonForTesting
    #expect(Set(visibleViews(failed).map(ObjectIdentifier.init)) == [ObjectIdentifier(failure), ObjectIdentifier(retry)])
    #expect(failed.spinnerForTesting == nil && failed.endLabelForTesting == nil)
    #expect(failure.attributedText?.string == "Couldn’t load more posts.")
    #expect(failure.numberOfLines == 0)
    #expect(failure.textColor == .secondaryLabel)
    let failureStyle = try #require(
      failure.attributedText?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    #expect(failureStyle.alignment == .center)
    let failureFont = try #require(failure.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(failureFont == AppUIFont.font(
      fontManager, size: Typography.Size.subheadline, weight: .medium, textStyle: .subheadline))
    #expect(retry.configuration?.title == "Try Again")
    let gap = retry.frame.minY - failure.frame.maxY
    #expect(abs(gap - 8) < 0.001)

    let end = nativeFooter(.end, size: size, fontManager: fontManager)
    let endLabel = try #require(end.endLabelForTesting)
    #expect(visibleViews(end) == [endLabel])
    #expect(end.spinnerForTesting == nil && end.failureLabelForTesting == nil)
    #expect(endLabel.attributedText?.string == "You’re all caught up")
    #expect(endLabel.textColor == .secondaryLabel)
    let endFont = try #require(endLabel.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(endFont == AppUIFont.font(
      fontManager, size: Typography.Size.footnote, weight: .regular, textStyle: .footnote))
    #expect(abs(endLabel.frame.minY - 24) < 0.001)
    #expect(abs(end.bounds.height - endLabel.frame.maxY - 24) < 0.001)
  }

  @Test("The text uses the hosted footer's semantic colour in light and dark")
  func semanticColours() throws {
    let failed = nativeFooter(.failed, size: Self.sizes[0], fontManager: FontManager())
    let end = nativeFooter(.end, size: Self.sizes[0], fontManager: FontManager())
    let labels = [try #require(failed.failureLabelForTesting), try #require(end.endLabelForTesting)]
    for style in [UIUserInterfaceStyle.light, .dark] {
      let traits = UITraitCollection(userInterfaceStyle: style)
      let hosted = UIColor(Color.secondary).resolvedColor(with: traits)
      #expect(Self.components(hosted) == Self.components(UIColor.secondaryLabel.resolvedColor(with: traits)))
      for label in labels {
        let color = label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        #expect(color?.resolvedColor(with: traits) == UIColor.secondaryLabel.resolvedColor(with: traits))
      }
    }
  }

  private static func components(_ color: UIColor) -> [Int] {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return [red, green, blue, alpha].map { Int(($0 * 255).rounded()) }
  }

  // MARK: Accessibility

  @Test("VoiceOver reads each state once, as the hosted footer does", arguments: states)
  func accessibility(state: FeedPaginationFooterState) async throws {
    let restore = AppAccessibility.enable()
    defer { restore() }
    let window = try makeWindow()
    defer { window.isHidden = true }
    let fontManager = FontManager()

    let native = nativeFooter(state, size: Self.sizes[0], fontManager: fontManager)
    window.addSubview(native)
    native.frame.origin.y = Self.cellY
    #expect(native.isAccessibilityElement == false)
    // UIKit answers labels and traits once its accessibility runtime has loaded, which can take a
    // moment after it is switched on.
    let expectedCount = Self.contentNames(state).count
    var elements: [AppAccessibility.Element] = []
    for _ in 0..<50 {
      elements = AppAccessibility.elements(in: native)
      if elements.count == expectedCount, elements.allSatisfy({ $0.label != nil }) { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    switch state {
    case .loading:
      #expect(elements.map(\.label) == ["Loading more posts"])
      #expect(elements.first?.traits.contains(.updatesFrequently) == true)
    case .failed:
      #expect(elements.map(\.label) == ["Couldn’t load more posts.", "Try Again"])
      #expect(elements.first?.traits == .staticText)
      let retry = try #require(elements.last)
      #expect(retry.traits.contains(.button))
      #expect(!retry.traits.contains(.notEnabled))
      #expect(retry.object === native.retryButtonForTesting)
    case .end:
      #expect(elements.map(\.label) == ["You’re all caught up"])
      #expect(elements.first?.traits == .staticText)
    }

    let hostedCell = UICollectionViewListCell(
      frame: CGRect(x: 0, y: Self.cellY + 250, width: Self.sizes[0].width, height: 150))
    hostedCell.contentConfiguration = UIHostingConfiguration {
      HostedFooterReference(state: state, onRetry: {})
        .environment(\.fontManager, fontManager)
    }
    .margins(.all, 0)
    window.addSubview(hostedCell)
    var hosted: [AppAccessibility.Element] = []
    for _ in 0..<50 where hosted.count < elements.count {
      hostedCell.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(10))
      hosted = AppAccessibility.elements(in: hostedCell)
    }
    #expect(elements.map(\.label) == hosted.map(\.label))
    #expect(elements.map(\.traits) == hosted.map(\.traits))
  }

  // MARK: Height Parity

  @Test("The cell is as tall as the hosted footer, with its content in the same place", arguments: states, sizes)
  func heightParity(state: FeedPaginationFooterState, size: Size) async throws {
    try await expectParity(state, size: size, matchesSelfSizing: true) { _ in }
  }

  /// Text that wraps, at the default content size category: the message at a narrow width, with
  /// each line-spacing setting and the full Dynamic Type range. Pins line breaking, line spacing
  /// and the widest line's width against SwiftUI's `Text`.
  struct WrappedText: Sendable, CustomTestStringConvertible {
    let state: FeedPaginationFooterState
    let width: CGFloat
    let lineSpacing: String
    let fullTypeRange: Bool
    var testDescription: String {
      "\(state) at \(Int(width)) pt, \(lineSpacing) line spacing\(fullTypeRange ? ", full type range" : "")"
    }
  }

  static let wrappedText: [WrappedText] = [
    WrappedText(state: .failed, width: 150, lineSpacing: "normal", fullTypeRange: false),
    WrappedText(state: .failed, width: 150, lineSpacing: "relaxed", fullTypeRange: false),
    WrappedText(state: .failed, width: 150, lineSpacing: "tight", fullTypeRange: false),
    WrappedText(state: .failed, width: 120, lineSpacing: "relaxed", fullTypeRange: true),
    WrappedText(state: .end, width: 100, lineSpacing: "normal", fullTypeRange: false),
    WrappedText(state: .end, width: 100, lineSpacing: "relaxed", fullTypeRange: true),
  ]

  @Test("Wrapped text is as tall as the hosted footer's, with its lines in the same place", arguments: wrappedText)
  func wrappedTextParity(text: WrappedText) async throws {
    let native = try await expectParity(
      text.state, size: Size(contentSize: .large, width: text.width), matchesSelfSizing: false
    ) {
      $0.lineSpacing = text.lineSpacing
      if text.fullTypeRange { $0.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange }
    }
    // The case must actually wrap, or it pins nothing.
    let label = try #require(text.state == .failed ? native.failureLabelForTesting : native.endLabelForTesting)
    let font = try #require(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(label.frame.height > font.lineHeight * 1.5, "\(label.frame) for a \(font.lineHeight) pt line")
  }

  /// Compares the native and the hosted footer for `state` at `size`, each with a font manager
  /// set up by `settings`, and returns the native cell. With `matchesSelfSizing`, the native height
  /// must also equal the height the hosted footer gave the list layout's self-sizing call.
  @discardableResult
  private func expectParity(
    _ state: FeedPaginationFooterState, size: Size, matchesSelfSizing: Bool, settings: (FontManager) -> Void
  ) async throws -> FeedPaginationFooterCell {
    let restore = AppAccessibility.enable()
    defer { restore() }
    let window = try makeWindow()
    defer { window.isHidden = true }
    let hostedFontManager = FontManager()
    settings(hostedFontManager)
    let nativeFontManager = FontManager()
    settings(nativeFontManager)
    let hosted = try await hostedFooter(state, size: size, fontManager: hostedFontManager, in: window)
    let native = nativeFooter(state, size: size, fontManager: nativeFontManager)
    window.addSubview(native)
    native.frame.origin.y = Self.cellY
    native.layoutIfNeeded()
    let nativeHeight = native.preferredLayoutAttributesFitting(attributes(width: size.width)).size.height
    #expect(abs(nativeHeight - hosted.height) <= 0.5, "native \(nativeHeight) hosted \(hosted.height)")
    if matchesSelfSizing {
      #expect(abs(nativeHeight - hosted.selfSizedHeight) <= 0.5,
        "native \(nativeHeight) hosted self-sized \(hosted.selfSizedHeight)")
    }
    let frames = Self.nativeFrames(native)
    for name in Self.contentNames(state) {
      let expected = try #require(hosted.frames[name], "The hosted footer reported no \(name) frame")
      let actual = try #require(frames[name])
      #expect(abs(actual.minX - expected.minX) <= 1, "\(name) x: native \(actual) hosted \(expected)")
      #expect(abs(actual.minY - expected.minY) <= 1, "\(name) y: native \(actual) hosted \(expected)")
      #expect(abs(actual.width - expected.width) <= 1, "\(name) width: native \(actual) hosted \(expected)")
      #expect(abs(actual.height - expected.height) <= 1, "\(name) height: native \(actual) hosted \(expected)")
    }
    return native
  }

  // MARK: Content Size Changes

  @Test("A content size change after configuring resizes the spinner, the button and the cell")
  func contentSizeChangeAfterConfigure() throws {
    let fontManager = FontManager()
    for state in [FeedPaginationFooterState.loading, .failed] {
      let cell = nativeFooter(state, size: Self.sizes[0], fontManager: fontManager)
      let largeHeight = cell.preferredLayoutAttributesFitting(attributes(width: Self.sizes[0].width)).size.height
      let largeFrame = try #require(Self.nativeFrames(cell)[state == .loading ? "spinner" : "retry"])

      cell.traitOverrides.preferredContentSizeCategory = .accessibilityExtraLarge
      cell.updateTraitsIfNeeded()
      let ax3Height = cell.preferredLayoutAttributesFitting(attributes(width: Self.sizes[0].width)).size.height
      cell.frame.size.height = ax3Height
      cell.layoutIfNeeded()
      let ax3Frame = try #require(Self.nativeFrames(cell)[state == .loading ? "spinner" : "retry"])
      #expect(ax3Height > largeHeight, "\(state): \(largeHeight) -> \(ax3Height)")
      #expect(ax3Frame.height > largeFrame.height, "\(state): \(largeFrame) -> \(ax3Frame)")
      #expect(abs(ax3Height - (ax3Frame.maxY + FeedPaginationFooterCell.verticalPadding)) < 0.001)
    }
  }

  // MARK: Retry

  @MainActor
  private final class Counter {
    var count = 0
  }

  @Test("Tapping Try Again, or activating it with VoiceOver, calls the retry closure exactly once")
  func retryRunsOnce() {
    let first = Counter()
    let second = Counter()
    let fontManager = FontManager()
    let cell = nativeFooter(.loading, size: Self.sizes[0], fontManager: fontManager)
    // Reconfiguring replaces the closure; it never adds a second action.
    cell.configure(state: .failed, fontManager: fontManager) { first.count += 1 }
    cell.configure(state: .failed, fontManager: fontManager) { first.count += 1 }
    let retry = cell.retryButtonForTesting
    retry.sendActions(for: .primaryActionTriggered)
    #expect(first.count == 1)

    cell.configure(state: .failed, fontManager: fontManager) { second.count += 1 }
    retry.sendActions(for: .primaryActionTriggered)
    #expect(first.count == 1)
    #expect(second.count == 1)

    // VoiceOver's double tap.
    #expect(retry.accessibilityActivate())
    #expect(second.count == 2)
    #expect(retry.accessibilityActivate())
    #expect(second.count == 3)
    #expect(first.count == 1)
  }

  // MARK: Cost

  @Test("State changes reuse the same views and never build SwiftUI")
  func stateChangesKeepTheViewTree() {
    let fontManager = FontManager()
    let cell = nativeFooter(.loading, size: Self.sizes[0], fontManager: fontManager)
    // Each state's views are created the first time it is shown.
    for state in [FeedPaginationFooterState.failed, .end] {
      cell.configure(state: state, fontManager: fontManager, onRetry: {})
      cell.layoutIfNeeded()
    }
    let subviews = cell.contentView.subviews
    #expect(subviews.count == 4)
    for state in [FeedPaginationFooterState.loading, .end, .failed, .loading, .end] {
      cell.configure(state: state, fontManager: fontManager, onRetry: {})
      cell.layoutIfNeeded()
      #expect(cell.contentView.subviews.elementsEqual(subviews, by: ===))
      #expect(visibleViews(cell).count == Self.contentNames(state).count)
      let elements = (cell.accessibilityElements as? [UIView]) ?? []
      #expect(Set(elements.map(ObjectIdentifier.init)) == Set(visibleViews(cell).map(ObjectIdentifier.init)))
    }
    #expect(cell.contentConfiguration == nil)
    let names = descendants(of: cell).map { NSStringFromClass(type(of: $0)) }
    #expect(!names.contains { $0.contains("Hosting") || $0.contains("SwiftUI") }, "\(names)")
  }

  // MARK: Font Settings

  @Test("A font-settings change reconfigures the feed's footer: a larger size scale makes it taller")
  func fontSettingsChangeReconfiguresFooter() async throws {
    let client = await ATProtoClient(baseURL: try #require(URL(string: "https://footer-fonts.invalid")))
    let appState = AppState(userDID: "did:plc:footerfonts", client: client, regulatoryChecker: NoAgePrompt())
    defer { appState.cleanup() }
    // Without a Dynamic Type limit the size scale always shows: at a system text size above the
    // default limit, both sizes would be capped at the limit's size.
    appState.fontManager.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    let host = try NativeFeedRowControllerHost(
      appState: appState, posts: [try FeedRowTestPosts.cachedPost(postKey: "footerfonts")])
    defer { host.tearDown() }
    await host.controller.performUpdate()
    let footerPath = IndexPath(item: 1, section: 0)
    let footer = try #require(try await waitForFooter(in: host, at: footerPath) { _ in true })
    #expect(footer.state == .end)
    let before = footer.bounds.height

    appState.fontManager.fontSize = "extraLarge"
    let taller = try await waitForFooter(in: host, at: footerPath) { $0.bounds.height > before }
    #expect(taller != nil, "The footer stayed \(before) pt tall after the font size grew")
    #expect(taller === footer)
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal { .none }
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private func waitForFooter(
    in host: NativeFeedRowControllerHost, at indexPath: IndexPath,
    where condition: (FeedPaginationFooterCell) -> Bool
  ) async throws -> FeedPaginationFooterCell? {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
      host.window.layoutIfNeeded()
      host.controller.collectionView.layoutIfNeeded()
      if let cell = host.controller.collectionView.cellForItem(at: indexPath) as? FeedPaginationFooterCell,
        condition(cell) {
        return cell
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }
}
#endif
