#if os(iOS)
import UIKit

// MARK: - Feed Pagination Footer Cell

/// The last row of a non-empty feed (`FeedPaginationFooterState`): a spinner while more pages may
/// load, a retry after a failed page, or a quiet end-of-feed line.
///
/// It is drawn in UIKit because the hosted SwiftUI footer cost about 19 ms of main-thread time the
/// first time it scrolled in, which a timeline reaches at every pagination boundary. The spinner
/// and the labels are created the first time the cell shows their state, the retry button with the
/// cell, and all are kept: a later state change only shows and hides them. Frames are set by hand
/// from measured sizes, without Auto Layout, and the self-sizing height is the computed layout's.
///
/// The text follows the app's font settings through `AppUIFont`, as `appFont` styled the hosted
/// footer's text. The button and the spinner follow the content size category the way the hosted
/// `Button` and `ProgressView` did.
final class FeedPaginationFooterCell: UICollectionViewCell {
  /// The feed registers this cell by reuse identifier rather than with a `CellRegistration`: a
  /// registration bridges its item to Objective-C on every dequeue, and the first bridge of a
  /// `Void` item searches every protocol conformance in the process, which cost about 5 ms in the
  /// frame where the footer first scrolled in.
  static let reuseIdentifier = "FeedPaginationFooterCell"

  // MARK: - Content

  /// The padding above and below the content.
  static let verticalPadding: CGFloat = 24
  /// The space between the failure message and the retry button.
  static let failureSpacing: CGFloat = 8
  static let loadingAccessibilityLabel = "Loading more posts"
  static let failureMessage = "Couldn’t load more posts."
  static let retryTitle = "Try Again"
  static let endMessage = "You’re all caught up"

  // MARK: - Views

  private var spinner: UIActivityIndicatorView?
  /// The medium spinner's own size, which `ProgressView` scales with the body text style.
  private var mediumSpinnerSide: CGFloat = 0
  private var failureLabel: UILabel?
  /// Created with the cell, so it has the cell's traits when it measures itself: a button added
  /// while the cell was being configured still measured itself at the previous content size
  /// category.
  private let retryButton: UIButton
  private var endLabel: UILabel?

  // MARK: - State

  private(set) var state: FeedPaginationFooterState?
  private var fontManager: FontManager?
  private var onRetry: (@MainActor () -> Void)?
  /// The text inputs each label was last styled for (`textKey`).
  private var failureTextKey: Int?
  private var endTextKey: Int?
  private var cachedLayout: Layout?

  var spinnerForTesting: UIActivityIndicatorView? { spinner }
  var failureLabelForTesting: UILabel? { failureLabel }
  var retryButtonForTesting: UIButton { retryButton }
  var endLabelForTesting: UILabel? { endLabel }

  // MARK: - Init

  override init(frame: CGRect) {
    var configuration = UIButton.Configuration.bordered()
    configuration.title = Self.retryTitle
    retryButton = UIButton(configuration: configuration)
    super.init(frame: frame)
    // A container: VoiceOver reads only the current state's elements (`accessibilityElements`).
    isAccessibilityElement = false
    accessibilityElements = []
    retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
    retryButton.isHidden = true
    contentView.addSubview(retryButton)
    registerForTraitChanges(
      [UITraitPreferredContentSizeCategory.self, UITraitLegibilityWeight.self, UITraitDisplayScale.self]
    ) { (cell: FeedPaginationFooterCell, _: UITraitCollection) in
      cell.traitsDidChange()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: - Configuration

  /// Shows `state` with text styled by `fontManager`'s settings; `onRetry` runs when "Try Again"
  /// is tapped. Configuring the state and settings the cell already shows changes nothing.
  func configure(
    state: FeedPaginationFooterState, fontManager: FontManager, onRetry: @escaping @MainActor () -> Void
  ) {
    self.onRetry = onRetry
    self.fontManager = fontManager
    let stateChanged = state != self.state
    if stateChanged {
      self.state = state
      showViews(for: state)
    }
    let textChanged = updateText()
    // No `invalidateIntrinsicContentSize()` here: the collection view sizes a configured or
    // reconfigured cell again on its own.
    if stateChanged || textChanged { invalidateLayout() }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onRetry = nil
  }

  /// Shows `state`'s views, creating them the first time, and hides the other states' views.
  private func showViews(for state: FeedPaginationFooterState) {
    let visible: [UIView]
    switch state {
    case .loading:
      let spinner = spinner ?? makeSpinner()
      spinner.startAnimating()
      visible = [spinner]
    case .failed:
      spinner?.stopAnimating()
      visible = [failureLabel ?? makeFailureLabel(), retryButton]
    case .end:
      spinner?.stopAnimating()
      visible = [endLabel ?? makeEndLabel()]
    }
    for view in contentView.subviews {
      view.isHidden = !visible.contains { $0 === view }
    }
    accessibilityElements = visible
  }

  /// A trait change outside a reconfigure: the text and the button change size, so the cell asks
  /// the collection view to size it again.
  private func traitsDidChange() {
    guard state != nil else { return }
    updateText()
    invalidateLayout()
    invalidateIntrinsicContentSize()
  }

  private func invalidateLayout() {
    cachedLayout = nil
    setNeedsLayout()
  }

  // MARK: - Views

  private func makeSpinner() -> UIActivityIndicatorView {
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.hidesWhenStopped = false
    spinner.isAccessibilityElement = true
    spinner.accessibilityLabel = Self.loadingAccessibilityLabel
    spinner.accessibilityTraits = .updatesFrequently
    mediumSpinnerSide = spinner.intrinsicContentSize.width
    contentView.addSubview(spinner)
    self.spinner = spinner
    return spinner
  }

  private func makeFailureLabel() -> UILabel {
    let label = makeLabel()
    failureLabel = label
    return label
  }

  private func makeEndLabel() -> UILabel {
    let label = makeLabel()
    endLabel = label
    return label
  }

  private func makeLabel() -> UILabel {
    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .secondaryLabel
    label.isAccessibilityElement = true
    contentView.addSubview(label)
    return label
  }

  // MARK: - Text

  /// Restyles the current state's text when a font setting, the content size category or bold
  /// text changed since it was last styled, and returns whether it did.
  @discardableResult
  private func updateText() -> Bool {
    guard let fontManager, let state, state != .loading else { return false }
    let boldLegibility: Bool = traitCollection.legibilityWeight == UILegibilityWeight.bold
    let boldText: Bool = boldLegibility || fontManager.effectiveBoldText
    let key: Int = Self.textKey(fontManager: fontManager, boldText: boldText, traits: traitCollection)
    // `AppFontModifier`: one weight heavier with bold text, the body size's line spacing scaled by
    // the multiplier (which `Text`, like `UILabel`, ignores when negative), and the app's tracking.
    let spacing: CGFloat = fontManager.getLineSpacing(for: Typography.Size.body) * fontManager.lineSpacingMultiplier
    let lineSpacing: CGFloat = max(0, spacing)
    let kerning: CGFloat = fontManager.letterSpacingValue
    if state == .failed, let failureLabel, failureTextKey != key {
      failureTextKey = key
      let weight: UIFont.Weight = boldText ? .semibold : .medium
      let font = AppUIFont.font(fontManager, size: Typography.Size.subheadline, weight: weight, textStyle: .subheadline)
      failureLabel.attributedText = Self.styled(
        Self.failureMessage, font: font, kerning: kerning, lineSpacing: lineSpacing, alignment: .center)
      return true
    }
    if state == .end, let endLabel, endTextKey != key {
      endTextKey = key
      let weight: UIFont.Weight = boldText ? .semibold : .regular
      let font = AppUIFont.font(fontManager, size: Typography.Size.footnote, weight: weight, textStyle: .footnote)
      endLabel.attributedText = Self.styled(
        Self.endMessage, font: font, kerning: kerning, lineSpacing: lineSpacing, alignment: .natural)
      return true
    }
    return false
  }

  private static func styled(
    _ string: String, font: UIFont, kerning: CGFloat, lineSpacing: CGFloat, alignment: NSTextAlignment
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineSpacing = lineSpacing
    return NSAttributedString(string: string, attributes: [
      .font: font, .kern: kerning, .paragraphStyle: paragraph, .foregroundColor: UIColor.secondaryLabel,
    ])
  }

  /// Every input the text's fonts and metrics depend on. The settings themselves are hashed, not
  /// only the manager's identity and generation: a manager allocated where a released one lived
  /// starts at the same generation. The design is hashed as its UIKit value; describing the SwiftUI
  /// `Font.Design` as a string goes through runtime reflection, which cost about 7 ms the first
  /// time the footer appeared.
  private static func textKey(fontManager: FontManager, boldText: Bool, traits: UITraitCollection) -> Int {
    var hasher = Hasher()
    hasher.combine(ObjectIdentifier(fontManager))
    hasher.combine(fontManager.generation)
    hasher.combine(fontManager.sizeScale)
    hasher.combine(AppUIFont.systemDesign(fontManager.fontDesign).rawValue)
    hasher.combine(fontManager.dynamicTypeEnabled)
    hasher.combine(fontManager.dynamicTypeLimit?.uiContentSizeCategory.rawValue)
    hasher.combine(fontManager.lineSpacingMultiplier)
    hasher.combine(fontManager.letterSpacingValue)
    hasher.combine(boldText)
    hasher.combine(traits.preferredContentSizeCategory.rawValue)
    return hasher.finalize()
  }

  // MARK: - Layout

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    let attributes = (layoutAttributes.copy() as? UICollectionViewLayoutAttributes) ?? layoutAttributes
    attributes.size.height = layout(width: layoutAttributes.size.width).height
    return attributes
  }

  override func systemLayoutSizeFitting(
    _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
    verticalFittingPriority: UILayoutPriority
  ) -> CGSize {
    CGSize(width: targetSize.width, height: layout(width: targetSize.width).height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let layout = layout(width: contentView.bounds.width)
    switch state {
    case .loading:
      placeSpinner(in: layout.spinnerFrame)
    case .failed:
      failureLabel?.frame = layout.failureFrame
      retryButton.frame = layout.retryFrame
    case .end:
      endLabel?.frame = layout.endFrame
    case nil:
      break
    }
  }

  /// `UIActivityIndicatorView` draws at its style's fixed size, so a larger or smaller spinner is
  /// the closest style scaled to `frame`: the medium style up to its own size, the large style
  /// (scaled down, or up by less) above it.
  private func placeSpinner(in frame: CGRect) {
    guard let spinner, !frame.isEmpty else { return }
    let style: UIActivityIndicatorView.Style = frame.width > mediumSpinnerSide ? .large : .medium
    if spinner.style != style { spinner.style = style }
    let side = spinner.intrinsicContentSize.width
    let factor = side > 0 ? frame.width / side : 1
    spinner.transform = .identity
    spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
    spinner.center = CGPoint(x: frame.midX, y: frame.midY)
    spinner.transform = factor == 1 ? .identity : CGAffineTransform(scaleX: factor, y: factor)
  }

  private struct Layout {
    let width: CGFloat
    var height: CGFloat = 0
    var spinnerFrame: CGRect = .zero
    var failureFrame: CGRect = .zero
    var retryFrame: CGRect = .zero
    var endFrame: CGRect = .zero
  }

  /// The current state's frames at `width`: centered across the width, as the hosted footer's
  /// `.frame(maxWidth: .infinity)` centered its content, between the vertical padding.
  private func layout(width: CGFloat) -> Layout {
    if let cachedLayout, cachedLayout.width == width { return cachedLayout }
    let scale = max(1, traitCollection.displayScale)
    let top = Self.verticalPadding
    func centered(_ size: CGSize, y: CGFloat) -> CGRect {
      CGRect(origin: CGPoint(x: Self.pixelRound((width - size.width) / 2, scale: scale), y: y), size: size)
    }
    var layout = Layout(width: width)
    switch state {
    case nil:
      break
    case .loading:
      // `ProgressView`'s size: the medium spinner's, scaled with the body style.
      let side = Self.pixelRound(
        UIFontMetrics(forTextStyle: .body).scaledValue(for: mediumSpinnerSide, compatibleWith: traitCollection),
        scale: scale)
      layout.spinnerFrame = centered(CGSize(width: side, height: side), y: top)
      layout.height = top + side + Self.verticalPadding
    case .failed:
      let text = textSize(failureLabel, width: width, scale: scale)
      let fitted = retryButton.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      let button = CGSize(
        width: min(width, Self.pixelCeil(fitted.width, scale: scale)), height: Self.pixelCeil(fitted.height, scale: scale))
      let buttonY = top + text.height + Self.failureSpacing
      layout.failureFrame = centered(text, y: top)
      layout.retryFrame = centered(button, y: buttonY)
      layout.height = buttonY + button.height + Self.verticalPadding
    case .end:
      let text = textSize(endLabel, width: width, scale: scale)
      layout.endFrame = centered(text, y: top)
      layout.height = top + text.height + Self.verticalPadding
    }
    cachedLayout = layout
    return layout
  }

  /// The size `label`'s text needs at `width`, rounded up to whole pixels.
  private func textSize(_ label: UILabel?, width: CGFloat, scale: CGFloat) -> CGSize {
    guard let text = label?.attributedText, text.length > 0, width > 0 else { return .zero }
    let rect = text.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    return CGSize(
      width: min(width, Self.pixelCeil(rect.width, scale: scale)), height: Self.pixelCeil(rect.height, scale: scale))
  }

  /// `value` rounded up to a whole pixel; the tolerance keeps a value already on a pixel boundary.
  private static func pixelCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    ceil(value * scale - 0.0001) / scale
  }

  private static func pixelRound(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale).rounded() / scale
  }
}
#endif
