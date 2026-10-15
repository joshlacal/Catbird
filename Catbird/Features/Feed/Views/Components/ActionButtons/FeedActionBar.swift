//
//  FeedActionBar.swift
//  Catbird
//
//  The reply / repost / like / share row of a feed post, drawn in UIKit.
//
//  Every feed row builds this row when it scrolls in. As SwiftUI it was about
//  forty views, two `Menu`s and their `UIMenu`s; as one UIKit view SwiftUI treats
//  it as a single leaf, and the menus are built only when opened.
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - State

/// Everything the row draws. Equatable so SwiftUI updates the view only when it changes.
struct FeedActionBarState: Equatable {
  var postURI: String
  var replyCount: Int
  var isReplyDisabled: Bool
  var repostCount: Int
  var isReposted: Bool
  var isQuoteDisabled: Bool
  var likeCount: Int
  var isLiked: Bool
  var isShareEnabled: Bool
  var canSendViaChat: Bool
  var canCopyLink: Bool
  var reduceMotion: Bool
  var fonts: FeedActionBarFonts
}

/// The row's fonts, resolved from the app's font settings the same way `appFont` does.
struct FeedActionBarFonts: Equatable {
  let icon: UIFont
  let count: UIFont
  let countKerning: CGFloat

  /// Fonts for the current settings, cached because every visible row asks on every update.
  @MainActor static func resolved(fontManager: FontManager, boldText: Bool) -> FeedActionBarFonts {
    let key = CacheKey(
      sizeScale: fontManager.sizeScale, design: "\(fontManager.fontDesign)",
      dynamicType: fontManager.dynamicTypeEnabled,
      limit: fontManager.dynamicTypeLimit?.uiContentSizeCategory.rawValue,
      contentSize: UIApplication.shared.preferredContentSizeCategory.rawValue,
      kerning: fontManager.letterSpacingValue, boldText: boldText)
    if let cached = cache, cached.key == key { return cached.fonts }
    let fonts = FeedActionBarFonts(fontManager: fontManager, boldText: boldText)
    cache = (key, fonts)
    return fonts
  }

  private struct CacheKey: Equatable {
    let sizeScale: CGFloat
    let design: String
    let dynamicType: Bool
    let limit: String?
    let contentSize: String
    let kerning: CGFloat
    let boldText: Bool
  }

  @MainActor private static var cache: (key: CacheKey, fonts: FeedActionBarFonts)?

  private init(fontManager: FontManager, boldText: Bool) {
    icon = Self.font(
      fontManager, size: Typography.Size.callout, weight: boldText ? .bold : .semibold,
      textStyle: .callout, monospacedDigits: false)
    count = Self.font(
      fontManager, size: Typography.Size.caption, weight: boldText ? .heavy : .bold,
      textStyle: .caption1, monospacedDigits: true)
    countKerning = fontManager.letterSpacingValue
  }

  private static func font(
    _ fontManager: FontManager, size: CGFloat, weight: UIFont.Weight,
    textStyle: UIFont.TextStyle, monospacedDigits: Bool
  ) -> UIFont {
    let baseSize = size * fontManager.sizeScale
    var descriptor = UIFont.systemFont(ofSize: baseSize, weight: weight).fontDescriptor
    if let designed = descriptor.withDesign(systemDesign(fontManager.fontDesign)) {
      descriptor = designed
    }
    if monospacedDigits {
      descriptor = descriptor.addingAttributes([
        .featureSettings: [[
          UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
          UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]
      ])
    }
    let font = UIFont(descriptor: descriptor, size: baseSize)
    guard fontManager.dynamicTypeEnabled else { return font }
    let metrics = UIFontMetrics(forTextStyle: textStyle)
    guard let limit = fontManager.dynamicTypeLimit else { return metrics.scaledFont(for: font) }
    let maximum = UIFont.preferredFont(
      forTextStyle: textStyle,
      compatibleWith: UITraitCollection(preferredContentSizeCategory: limit.uiContentSizeCategory)
    ).pointSize
    return metrics.scaledFont(for: font, maximumPointSize: maximum)
  }

  private static func systemDesign(_ design: Font.Design) -> UIFontDescriptor.SystemDesign {
    switch design {
    case .serif: .serif
    case .rounded: .rounded
    case .monospaced: .monospaced
    default: .default
    }
  }
}

/// What the row's buttons and menu items do.
struct FeedActionBarActions {
  let reply: () -> Void
  let toggleRepost: () -> Void
  let quote: () -> Void
  let toggleLike: () -> Void
  let sendViaChat: () -> Void
  let copyLink: () -> Void
  let moreSharing: () -> Void
}

// MARK: - SwiftUI bridge

struct FeedActionBar: UIViewRepresentable {
  let state: FeedActionBarState
  let actions: FeedActionBarActions

  static let height: CGFloat = 45

  func makeUIView(context: Context) -> FeedActionBarView {
    FeedActionBarView.dequeueReusable()
  }

  static func dismantleUIView(_ uiView: FeedActionBarView, coordinator: ()) {
    FeedActionBarView.enqueueForReuse(uiView)
  }

  func updateUIView(_ view: FeedActionBarView, context: Context) {
    view.actions = actions
    view.apply(state)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: FeedActionBarView, context: Context) -> CGSize? {
    CGSize(width: proposal.width ?? uiView.bounds.width, height: Self.height)
  }
}

// MARK: - View

final class FeedActionBarView: UIView {
  var actions: FeedActionBarActions?

  private let replyButton = FeedActionBarButton(iconName: "bubble.left")
  private let repostButton = FeedActionBarButton(iconName: "arrow.2.squarepath")
  private let likeButton = FeedActionBarButton(iconName: "heart")
  private let shareButton = FeedActionBarButton(iconName: "square.and.arrow.up")
  private var state: FeedActionBarState?

  // Matches the SwiftUI row: 3pt leading and 12pt trailing padding, 8pt spacing.
  private static let leadingInset: CGFloat = 3
  private static let trailingInset: CGFloat = 12
  private static let spacing: CGFloat = 8

  override init(frame: CGRect) {
    super.init(frame: frame)
    for button in [replyButton, repostButton, likeButton, shareButton] {
      addSubview(button)
    }

    replyButton.accessibilityIdentifier = "replyButton"
    replyButton.addAction(UIAction { [weak self] _ in self?.actions?.reply() }, for: .primaryActionTriggered)

    repostButton.accessibilityIdentifier = "repostButton"
    repostButton.showsMenuAsPrimaryAction = true
    repostButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.repostMenuItems() ?? [])
      }
    ])

    likeButton.accessibilityIdentifier = "likeButton"
    likeButton.addAction(UIAction { [weak self] _ in self?.actions?.toggleLike() }, for: .primaryActionTriggered)

    shareButton.accessibilityIdentifier = "shareButton"
    shareButton.accessibilityLabel = "Share post"
    shareButton.contentAlignment = .trailing
    shareButton.showsMenuAsPrimaryAction = true
    shareButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        completion(self?.shareMenuItems() ?? [])
      }
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: Reuse

  /// Feed rows get a new SwiftUI identity per post, so every row that scrolls in would
  /// otherwise build (and every row that leaves would free) a bar of buttons, labels and
  /// menus. Bars from dismantled rows are kept here and handed to the next row instead.
  private static var reusePool: [FeedActionBarView] = []
  private static let reusePoolLimit = 24

  static func dequeueReusable() -> FeedActionBarView {
    reusePool.popLast() ?? FeedActionBarView()
  }

  static func enqueueForReuse(_ view: FeedActionBarView) {
    view.removeFromSuperview()
    // Forget the previous post so the next `apply` is a full, unanimated fill.
    view.actions = nil
    view.state = nil
    guard reusePool.count < reusePoolLimit else { return }
    reusePool.append(view)
  }

  func apply(_ new: FeedActionBarState) {
    let old = state
    guard new != old else { return }
    state = new
    // Animate only changes to the post already shown, never the first fill or a
    // reused view switching posts.
    let animates = old?.postURI == new.postURI && !new.reduceMotion

    replyButton.configure(
      iconName: "bubble.left", count: new.replyCount, color: .secondaryLabel,
      fonts: new.fonts, animated: false)
    replyButton.isEnabled = !new.isReplyDisabled
    replyButton.accessibilityLabel = Self.countedLabel(
      "Reply", count: new.replyCount, singular: "reply", plural: "replies")

    repostButton.configure(
      iconName: "arrow.2.squarepath", count: new.repostCount,
      color: new.isReposted ? .systemGreen : .secondaryLabel, fonts: new.fonts, animated: false)
    repostButton.accessibilityLabel = Self.countedLabel(
      new.isReposted ? "Remove Repost" : "Repost or Quote Post",
      count: new.repostCount, singular: "repost", plural: "reposts")

    likeButton.configure(
      iconName: new.isLiked ? "heart.fill" : "heart", count: new.likeCount,
      color: new.isLiked ? .systemRed : .secondaryLabel, fonts: new.fonts, animated: animates)
    likeButton.accessibilityLabel = Self.countedLabel(
      new.isLiked ? "Unlike" : "Like", count: new.likeCount, singular: "like", plural: "likes")
    if animates, old?.isLiked == false, new.isLiked {
      likeButton.bounceIcon()
    }
    likeButton.setActive(new.isLiked, animated: old?.postURI == new.postURI, reduceMotion: new.reduceMotion)

    shareButton.configure(
      iconName: "square.and.arrow.up", count: nil, color: .secondaryLabel,
      fonts: new.fonts, animated: false)
    shareButton.isEnabled = new.isShareEnabled

    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = bounds.height
    let shareWidth = shareButton.minimumWidth
    let shareX = bounds.width - Self.trailingInset - shareWidth
    shareButton.frame = CGRect(
      x: shareX, y: (height - shareButton.minimumHeight) / 2,
      width: shareWidth, height: shareButton.minimumHeight)

    // Reply, repost and like each take an equal leading-aligned slot of what is left.
    let slots = [replyButton, repostButton, likeButton]
    let available = shareX - Self.spacing - Self.leadingInset - Self.spacing * CGFloat(slots.count - 1)
    let slotWidth = max(0, available / CGFloat(slots.count))
    for (index, button) in slots.enumerated() {
      let x = Self.leadingInset + CGFloat(index) * (slotWidth + Self.spacing)
      let width = min(slotWidth, button.fittingWidth)
      button.frame = CGRect(
        x: x, y: (height - button.minimumHeight) / 2, width: width, height: button.minimumHeight)
    }
  }

  private func repostMenuItems() -> [UIMenuElement] {
    guard let state else { return [] }
    return [
      UIAction(
        title: state.isReposted ? "Remove Repost" : "Repost", systemImage: "arrow.2.squarepath"
      ) { [weak self] in
        self?.actions?.toggleRepost()
      },
      UIAction(title: "Quote Post", systemImage: "quote.bubble", isEnabled: !state.isQuoteDisabled) {
        [weak self] in
        self?.actions?.quote()
      },
    ]
  }

  private func shareMenuItems() -> [UIMenuElement] {
    guard let state else { return [] }
    return [
      UIAction(
        title: "Send via Chat", systemImage: "bubble.left.and.bubble.right",
        isEnabled: state.canSendViaChat, identifier: "shareToBlueskyChat"
      ) { [weak self] in
        self?.actions?.sendViaChat()
      },
      UIAction(
        title: "Copy Link", systemImage: "link", isEnabled: state.canCopyLink,
        identifier: "copyPostLink"
      ) { [weak self] in
        self?.actions?.copyLink()
      },
      UIAction(title: "More…", systemImage: "square.and.arrow.up", identifier: "morePostSharing") {
        [weak self] in
        self?.actions?.moreSharing()
      },
    ]
  }

  /// VoiceOver label such as "Like, 3 likes".
  private static func countedLabel(_ action: String, count: Int, singular: String, plural: String) -> String {
    "\(action), \(count) \(count == 1 ? singular : plural)"
  }
}

// MARK: - Button

/// An icon with an optional count, laid out by hand to keep the row cheap.
final class FeedActionBarButton: UIButton {
  enum ContentAlignment { case leading, trailing }

  var contentAlignment: ContentAlignment = .leading
  private let icon = UIImageView()
  private let countLabel = UILabel()
  private var iconName: String
  private var iconFont: UIFont?
  private var color: UIColor = .secondaryLabel
  private var hasCount = false

  // Matches the SwiftUI labels: 36pt wide without a count, 46pt with one, 32pt tall.
  var minimumWidth: CGFloat { hasCount ? 46 : 36 }
  let minimumHeight: CGFloat = 32
  private static let iconSpacing: CGFloat = 4

  init(iconName: String) {
    self.iconName = iconName
    super.init(frame: .zero)
    icon.contentMode = .center
    icon.isUserInteractionEnabled = false
    countLabel.isUserInteractionEnabled = false
    countLabel.numberOfLines = 1
    addSubview(icon)
    addSubview(countLabel)
    isAccessibilityElement = true
    accessibilityTraits = .button
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override var isHighlighted: Bool {
    didSet { alpha = isHighlighted ? 0.5 : 1 }
  }

  override var isEnabled: Bool {
    didSet { applyColor() }
  }

  /// The width the icon and count need, at least `minimumWidth`.
  var fittingWidth: CGFloat {
    let iconWidth = icon.intrinsicContentSize.width
    let countWidth = hasCount ? Self.iconSpacing + countLabel.intrinsicContentSize.width : 0
    return max(minimumWidth, iconWidth + countWidth)
  }

  func configure(iconName: String, count: Int?, color: UIColor, fonts: FeedActionBarFonts, animated: Bool) {
    if iconName != self.iconName || fonts.icon != iconFont || icon.image == nil,
       let image = Self.symbolImage(iconName, font: fonts.icon) {
      if animated, iconName != self.iconName {
        icon.setSymbolImage(image, contentTransition: .replace)
      } else {
        icon.image = image
      }
    }
    self.iconName = iconName
    iconFont = fonts.icon

    if let count, count > 0 {
      hasCount = true
      countLabel.isHidden = false
      countLabel.attributedText = NSAttributedString(
        string: count.formatted,
        attributes: [.font: fonts.count, .kern: fonts.countKerning])
    } else {
      hasCount = false
      countLabel.isHidden = true
      countLabel.attributedText = nil
    }
    self.color = color
    applyColor()
    setNeedsLayout()
  }

  private struct SymbolKey: Hashable {
    let name: String
    let font: UIFont
  }

  /// Every row shows the same handful of symbols at one font, so resolve each once.
  @MainActor private static var symbolImages: [SymbolKey: UIImage] = [:]

  private static func symbolImage(_ name: String, font: UIFont) -> UIImage? {
    let key = SymbolKey(name: name, font: font)
    if let cached = symbolImages[key] { return cached }
    let configuration = UIImage.SymbolConfiguration(font: font, scale: .medium)
    guard let image = UIImage(systemName: name, withConfiguration: configuration) else { return nil }
    if symbolImages.count > 64 { symbolImages.removeAll() }
    symbolImages[key] = image
    return image
  }

  func bounceIcon() {
    icon.addSymbolEffect(.bounce, options: .speed(1.5))
  }

  /// Scales the button up slightly while active, or dims it under Reduce Motion,
  /// as `accessibleScaleEffect` does for the SwiftUI buttons.
  func setActive(_ isActive: Bool, animated: Bool, reduceMotion: Bool) {
    let changes = {
      if reduceMotion {
        self.transform = .identity
        self.icon.alpha = isActive ? 0.8 : 1
      } else {
        self.transform = isActive ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
        self.icon.alpha = 1
      }
    }
    if animated && !reduceMotion {
      UIView.animate(springDuration: 0.2, bounce: 0.15, animations: changes)
    } else {
      changes()
    }
  }

  private func applyColor() {
    let resolved = isEnabled ? color : .tertiaryLabel
    icon.tintColor = resolved
    countLabel.textColor = resolved
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let iconSize = icon.intrinsicContentSize
    let countSize = hasCount ? countLabel.intrinsicContentSize : .zero
    let contentWidth = iconSize.width + (hasCount ? Self.iconSpacing + countSize.width : 0)
    var x = contentAlignment == .leading ? 0 : bounds.width - contentWidth
    icon.frame = CGRect(
      x: x, y: (bounds.height - iconSize.height) / 2, width: iconSize.width, height: iconSize.height)
    x += iconSize.width + Self.iconSpacing
    countLabel.frame = CGRect(
      x: x, y: (bounds.height - countSize.height) / 2, width: countSize.width, height: countSize.height)
  }
}

// MARK: - Menu items

extension UIAction {
  /// A menu action that is disabled when `isEnabled` is false.
  convenience init(
    title: String, systemImage: String, isEnabled: Bool = true,
    identifier: String? = nil, handler: @escaping () -> Void
  ) {
    self.init(
      title: title, image: UIImage(systemName: systemImage),
      attributes: isEnabled ? [] : .disabled
    ) { _ in handler() }
    if let identifier { accessibilityIdentifier = identifier }
  }
}
#endif
