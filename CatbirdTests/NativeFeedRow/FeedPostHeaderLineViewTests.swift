#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

@MainActor
@Suite("Feed post header line view")
struct FeedPostHeaderLineViewTests {
  private struct Fixture {
    let typography: FeedRowTypography
    let layout: FeedRowLayout
    let displayName: String
    let handle: String
    let timeText: String
  }

  private func fixture(
    displayName: String = "Alice Rivera", handle: String = "@alice.test", timeText: String = "3m",
    verified: VerificationBadgeKind? = nil, width: CGFloat = 390, fontManager: FontManager = FontManager(),
    boldText: Bool = false
  ) throws -> Fixture {
    let typography = FeedRowTypography.resolved(fontManager: fontManager, boldText: boldText)
    let layout = FeedRowLayoutEngine.layout(
      FeedRowLayoutInput(
        postID: "p", width: width, typography: typography, displayName: displayName, handle: handle,
        timeText: timeText, verificationSymbol: verified?.symbolName,
        text: NSAttributedString(string: "body"), contentSignature: try FeedRowTestPosts.signature()))
    return Fixture(typography: typography, layout: layout, displayName: displayName, handle: handle, timeText: timeText)
  }

  private func configured(
    _ fixture: Fixture, verification: VerificationBadgeKind? = nil, hideVerificationBadges: Bool = false,
    originX: CGFloat = 0
  ) -> FeedPostHeaderLineView {
    let view = FeedPostHeaderLineView(frame: CGRect(x: originX, y: 0, width: fixture.layout.width, height: 60))
    view.configure(
      fixture.layout, displayName: fixture.displayName, handle: fixture.handle, timeText: fixture.timeText,
      timeAccessibilityLabel: "3 minutes ago", verification: verification, typography: fixture.typography,
      metadataColor: .secondaryLabel, originX: originX, hideVerificationBadges: hideVerificationBadges)
    return view
  }

  @Test("Labels and badge sit at the layout's frames")
  func framesFollowLayout() throws {
    let fixture = try fixture(verified: .regular)
    let view = configured(fixture, verification: .regular)
    #expect(view.nameLabelForTesting.frame == fixture.layout.nameFrame)
    #expect(view.handleLabelForTesting.frame == fixture.layout.handleFrame)
    #expect(view.timeLabelForTesting.frame == fixture.layout.timeFrame)
    #expect(view.badgeViewForTesting.frame == fixture.layout.badgeFrame)
    #expect(!view.nameLabelForTesting.isHidden)
    #expect(!view.handleLabelForTesting.isHidden)
    #expect(!view.timeLabelForTesting.isHidden)
    #expect(!view.badgeViewForTesting.isHidden)
  }

  @Test("Frames are converted into the header's coordinate space by originX")
  func originOffset() throws {
    let fixture = try fixture(verified: .trustedVerifier)
    let view = configured(fixture, verification: .trustedVerifier, originX: 60)
    #expect(view.nameLabelForTesting.frame == fixture.layout.nameFrame.offsetBy(dx: -60, dy: 0))
    #expect(view.handleLabelForTesting.frame == fixture.layout.handleFrame?.offsetBy(dx: -60, dy: 0))
    #expect(view.timeLabelForTesting.frame == fixture.layout.timeFrame.offsetBy(dx: -60, dy: 0))
    #expect(view.badgeViewForTesting.frame == fixture.layout.badgeFrame?.offsetBy(dx: -60, dy: 0))
  }

  @Test("The handle is hidden when the layout dropped it")
  func handleHiddenWithoutFrame() throws {
    let fixture = try fixture(displayName: String(repeating: "Very Long Name ", count: 6), width: 320)
    try #require(fixture.layout.handleFrame == nil)
    let view = configured(fixture)
    #expect(view.handleLabelForTesting.isHidden)
    #expect(!view.nameLabelForTesting.isHidden)
    #expect(!view.timeLabelForTesting.isHidden)
  }

  @Test("A handle hidden by one post is shown again when the view is configured for a roomy post")
  func handleReappearsOnReconfigure() throws {
    let tight = try fixture(displayName: String(repeating: "Very Long Name ", count: 6), width: 320)
    let roomy = try fixture()
    let view = configured(tight)
    #expect(view.handleLabelForTesting.isHidden)
    view.configure(
      roomy.layout, displayName: roomy.displayName, handle: roomy.handle, timeText: roomy.timeText,
      timeAccessibilityLabel: "3 minutes ago", verification: nil, typography: roomy.typography,
      metadataColor: .secondaryLabel, originX: 0, hideVerificationBadges: false)
    #expect(!view.handleLabelForTesting.isHidden)
    #expect(view.handleLabelForTesting.frame == roomy.layout.handleFrame)
  }

  @Test("The badge is hidden without a verification, without a frame, or when the preference hides it")
  func badgeVisibility() throws {
    let verifiedFixture = try fixture(verified: .regular)
    let unverifiedFixture = try fixture()
    try #require(verifiedFixture.layout.badgeFrame != nil)
    try #require(unverifiedFixture.layout.badgeFrame == nil)

    #expect(!configured(verifiedFixture, verification: .regular).badgeViewForTesting.isHidden)
    #expect(configured(verifiedFixture, verification: nil).badgeViewForTesting.isHidden)
    #expect(configured(unverifiedFixture, verification: .regular).badgeViewForTesting.isHidden)
    #expect(configured(verifiedFixture, verification: .regular, hideVerificationBadges: true).badgeViewForTesting.isHidden)
  }

  @Test("The badge shows the kind's symbol in blue and reads as the kind's label")
  func badgeContent() throws {
    let fixture = try fixture(verified: .trustedVerifier)
    let view = configured(fixture, verification: .trustedVerifier)
    let badge = view.badgeViewForTesting
    #expect(badge.image != nil)
    #expect(badge.tintColor == .systemBlue)
    #expect(badge.isAccessibilityElement)
    #expect(badge.accessibilityLabel == VerificationBadgeKind.trustedVerifier.accessibilityLabel)

    let regular = configured(try self.fixture(verified: .regular), verification: .regular)
    #expect(regular.badgeViewForTesting.accessibilityLabel == VerificationBadgeKind.regular.accessibilityLabel)
    #expect(badge.image?.isSymbolImage == true)
  }

  @Test("Labels draw with the attributes the layout engine measured with")
  func drawingAttributesMatchMeasurement() throws {
    let fontManager = FontManager()
    fontManager.letterSpacing = "loose"
    let fixture = try fixture(fontManager: fontManager)
    try #require(fixture.typography.kerning != 0)
    let view = configured(fixture)

    let name = try #require(view.nameLabelForTesting.attributedText)
    #expect(name.string == "Alice Rivera")
    #expect(name.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == fixture.typography.name)
    #expect(name.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == 0)

    let handle = try #require(view.handleLabelForTesting.attributedText)
    #expect(handle.string == "@alice.test")
    #expect(handle.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == fixture.typography.metadata)
    #expect(handle.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == fixture.typography.kerning)

    let time = try #require(view.timeLabelForTesting.attributedText)
    #expect(time.string == "·  3m")
    #expect(time.attribute(.font, at: 0, effectiveRange: nil) as? UIFont == fixture.typography.metadata)
    #expect(time.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat == 0)
  }

  @Test("Name and handle use the metadata color and primary label color")
  func colors() throws {
    let fixture = try fixture()
    let view = FeedPostHeaderLineView(frame: CGRect(x: 0, y: 0, width: 390, height: 60))
    view.configure(
      fixture.layout, displayName: "A", handle: "@a", timeText: "1h", timeAccessibilityLabel: "1 hour ago",
      verification: nil, typography: fixture.typography, metadataColor: .systemPink, originX: 0,
      hideVerificationBadges: false)
    func color(_ label: UILabel) -> UIColor? {
      label.attributedText?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }
    #expect(color(view.nameLabelForTesting) == .label)
    #expect(color(view.handleLabelForTesting) == .systemPink)
    #expect(color(view.timeLabelForTesting) == .systemPink)
  }

  @Test("Name and handle truncate by tail on one line; the time label never wraps")
  func truncationModes() throws {
    let view = configured(try fixture())
    #expect(view.nameLabelForTesting.lineBreakMode == .byTruncatingTail)
    #expect(view.nameLabelForTesting.numberOfLines == 1)
    #expect(view.handleLabelForTesting.lineBreakMode == .byTruncatingTail)
    #expect(view.handleLabelForTesting.numberOfLines == 1)
    #expect(view.timeLabelForTesting.numberOfLines == 1)
  }

  @Test("The time label reads as the accessibility time text")
  func timeAccessibility() throws {
    let view = configured(try fixture())
    #expect(view.timeLabelForTesting.accessibilityLabel == "3 minutes ago")
  }

  @Test("Name actions are offered on the name element and survive reconfiguration")
  func nameAccessibilityActions() throws {
    let fixture = try fixture()
    let view = configured(fixture)
    #expect(view.nameLabelForTesting.accessibilityCustomActions == nil)
    let openPost = UIAccessibilityCustomAction(name: "Open post") { _ in true }
    view.nameAccessibilityActions = [openPost]
    view.configure(
      fixture.layout, displayName: "Someone Else", handle: fixture.handle, timeText: fixture.timeText,
      timeAccessibilityLabel: "3 minutes ago", verification: nil, typography: fixture.typography,
      metadataColor: .secondaryLabel, originX: 0, hideVerificationBadges: false)
    #expect(view.nameLabelForTesting.accessibilityCustomActions?.map(\.name) == ["Open post"])
    view.nameAccessibilityActions = []
    #expect(view.nameLabelForTesting.accessibilityCustomActions == nil)
  }

  @Test("The header never takes touches meant for the row", arguments: [false, true])
  func nonInteractive(verified: Bool) throws {
    let view = configured(try fixture(verified: verified ? .regular : nil), verification: verified ? .regular : nil)
    #expect(!view.isUserInteractionEnabled)
  }

  /// A label narrower than its text truncates; when the engine decided everything fits, no
  /// label may need more width than it is given.
  @Test("Each label's natural width fits its layout frame", arguments: [
    (letterSpacing: "normal", boldText: false),
    (letterSpacing: "loose", boldText: false),
    (letterSpacing: "tight", boldText: true),
    (letterSpacing: "loose", boldText: true)
  ])
  func labelsFitTheirFrames(letterSpacing: String, boldText: Bool) throws {
    let fontManager = FontManager()
    fontManager.letterSpacing = letterSpacing
    let fixture = try fixture(
      displayName: "Alice Rivera 🦋", handle: "@alice-rivera.bsky.social", timeText: "12mo", verified: .regular,
      width: 560, fontManager: fontManager, boldText: boldText)
    try #require(fixture.layout.handleFrame != nil)
    let view = configured(fixture, verification: .regular)
    let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    for label in [view.nameLabelForTesting, view.handleLabelForTesting, view.timeLabelForTesting] {
      let natural = label.sizeThatFits(unbounded)
      #expect(
        natural.width <= label.frame.width + 0.5,
        "\(label.attributedText?.string ?? "") needs \(natural.width) in \(label.frame.width)")
      #expect(natural.height <= label.frame.height + 0.5)
    }
  }

  @Test("A handle the engine truncated is narrower than its text and truncates by tail")
  func truncatedHandle() throws {
    let fixture = try fixture(handle: "@a-very-long-handle-name.bsky.social", width: 390)
    let frame = try #require(fixture.layout.handleFrame)
    let view = configured(fixture)
    let natural = view.handleLabelForTesting.sizeThatFits(
      CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    try #require(natural.width > frame.width)
    #expect(view.handleLabelForTesting.lineBreakMode == .byTruncatingTail)
    #expect(frame.maxX <= fixture.layout.timeFrame.minX)
  }
}
#endif
