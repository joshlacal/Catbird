#if os(iOS)
import Nuke
import Petrel
import UIKit

// MARK: - Video Card

/// One `TrendingVideosSection` card: the thumbnail (or the moderation cover that replaces it)
/// with a play badge, then the author's avatar and two-line name. One accessibility element.
final class TrendingVideoCardView: TrendingCardControl {
  /// The thumbnail area; the zoom transition starts from this rectangle.
  let thumbnailContainer = UIView()
  private let thumbnailView = UIImageView()
  private let fallbackIconView = UIImageView()
  private let coverView = UIView()
  private let coverIconView = UIImageView()
  private let coverLabel = UILabel()
  private let playBadge = UIView()
  private let playIconView = UIImageView()
  private let avatarView = TrendingAvatarView()
  private let authorLabel = UILabel()
  private lazy var thumbnailSlot = TrendingImageSlot(imageView: thumbnailView)

  var startedImageRequestCountForTesting: Int {
    thumbnailSlot.startedRequestCountForTesting + avatarView.startedImageRequestCountForTesting
  }
  private(set) var postURI: String?
  private(set) var appliedAllowsImageLoading: Bool?

  override init(frame: CGRect) {
    super.init(frame: frame)
    thumbnailContainer.clipsToBounds = true
    thumbnailContainer.layer.cornerRadius = TrendingInterstitialMetrics.videoCornerRadius
    thumbnailContainer.layer.cornerCurve = .continuous
    thumbnailContainer.backgroundColor = TrendingInterstitialColors.placeholderFill
    thumbnailView.contentMode = .scaleAspectFill
    thumbnailView.clipsToBounds = true
    fallbackIconView.contentMode = .center
    fallbackIconView.tintColor = .secondaryLabel
    fallbackIconView.image = TrendingSymbolCache.symbol("play.rectangle", textStyle: .title2)
    coverIconView.contentMode = .center
    coverIconView.tintColor = .secondaryLabel
    coverIconView.image = TrendingSymbolCache.symbol("eye.slash.fill", textStyle: .title2)
    coverLabel.numberOfLines = 2
    coverLabel.textAlignment = .center
    coverView.accessibilityIdentifier = "moderation.trendingVideoCover"
    coverView.addSubview(coverIconView)
    coverView.addSubview(coverLabel)
    playBadge.backgroundColor = UIColor.black.withAlphaComponent(0.65)
    playBadge.layer.cornerRadius = TrendingInterstitialMetrics.playBadgeSide / 2
    playIconView.contentMode = .center
    playIconView.tintColor = .white
    playIconView.image = TrendingSymbolCache.symbol("play.fill", textStyle: .caption1, weight: .semibold)
    playBadge.addSubview(playIconView)
    for view in [thumbnailView, fallbackIconView, coverView, playBadge] {
      thumbnailContainer.addSubview(view)
    }
    authorLabel.numberOfLines = 2
    authorLabel.lineBreakMode = .byTruncatingTail
    for view in [thumbnailContainer, avatarView, authorLabel] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityHint = "Play this video in The Vids"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(
    _ card: TrendingInterstitialModel.VideoCard,
    layout: TrendingVideoCardLayout,
    size: CGSize,
    typography t: TrendingInterstitialTypography,
    isRightToLeft rtl: Bool,
    policy: ModerationPolicy,
    displayScale: CGFloat,
    allowsImageLoading: Bool = true
  ) {
    if let applied = postURI, applied == card.uri, bounds.size == size {
      updateImageLoading(card, layout: layout, policy: policy, displayScale: displayScale, allowsImageLoading: allowsImageLoading)
      return
    }
    postURI = card.uri
    appliedAllowsImageLoading = allowsImageLoading
    accessibilityLabel = card.accessibilityLabel
    func place(_ view: UIView, _ frame: CGRect, in width: CGFloat) {
      let frame = rtl ? CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
      // Labels draw lines with a constant line height ("Tight") lower, where SwiftUI's `Text` does.
      view.frame = (view as? UILabel).map { TrendingInterstitialText.labelFrame(frame, for: $0.attributedText) } ?? frame
    }

    // Thumbnail
    let thumb = layout.thumbnailFrame
    place(thumbnailContainer, thumb, in: size.width)
    let bounds = CGRect(origin: .zero, size: thumb.size)
    thumbnailView.frame = bounds
    fallbackIconView.frame = bounds
    coverView.frame = bounds
    switch card.thumbnail {
    case .covered(let title):
      thumbnailSlot.setRequest(nil)
      thumbnailView.isHidden = true
      fallbackIconView.isHidden = true
      coverView.isHidden = false
      playBadge.isHidden = true
      layoutCover(title: title, in: bounds, typography: t)
    case .image(let url):
      coverView.isHidden = true
      playBadge.isHidden = false
      thumbnailView.isHidden = false
      let request = TrendingTopicImageRequests.request(url, size: thumb.size, displayScale: displayScale, priority: .normal)
      thumbnailSlot.setRequest(request, allowsImageLoading: allowsImageLoading) { [weak self] phase in
        self?.fallbackIconView.isHidden = phase != .failed
      }
    case .none:
      thumbnailSlot.setRequest(nil)
      thumbnailView.isHidden = true
      coverView.isHidden = true
      fallbackIconView.isHidden = false
      playBadge.isHidden = false
    }
    let badge = TrendingInterstitialMetrics.playBadgeSide
    let inset = TrendingInterstitialMetrics.playBadgeInset
    place(playBadge, CGRect(x: inset, y: thumb.height - inset - badge, width: badge, height: badge), in: thumb.width)
    playIconView.frame = playBadge.bounds

    // Author
    place(avatarView, layout.avatarFrame, in: size.width)
    avatarView.apply(
      source: AsyncProfileImage.source(
        url: card.post.author.finalAvatarURL(), sizeInPoints: layout.avatarFrame.width, displayScale: displayScale,
        did: card.post.author.did.didString(), labels: card.post.author.labels, policy: policy),
      allowsImageLoading: allowsImageLoading)
    let name = TrendingInterstitialText.attributed(
      card.authorName, font: t.videoAuthor, lineSpacing: t.videoAuthorLineSpacing,
      lineHeightFactor: t.lineHeightFactor, kerning: t.kerning, alignment: rtl ? .right : .left)
    authorLabel.attributedText = name
    let nameHeight = TrendingInterstitialText.height(
      name, width: layout.authorFrame.width, maximumLines: 2, scale: t.displayScale)
    place(authorLabel, CGRect(origin: layout.authorFrame.origin,
      size: CGSize(width: layout.authorFrame.width, height: min(nameHeight, layout.authorFrame.height))), in: size.width)
  }

  private func layoutCover(title: String, in bounds: CGRect, typography t: TrendingInterstitialTypography) {
    let text = TrendingInterstitialText.attributed(
      title, font: t.caption, color: .secondaryLabel, lineSpacing: t.roleLineSpacing,
      lineHeightFactor: t.lineHeightFactor, kerning: t.kerning, alignment: .center)
    coverLabel.attributedText = text
    let width = max(0, bounds.width - 2 * DesignTokens.Spacing.sm)
    let textHeight = TrendingInterstitialText.height(text, width: width, maximumLines: 2, scale: t.displayScale)
    let iconSize = coverIconView.image?.size ?? .zero
    let total = iconSize.height + DesignTokens.Spacing.xs + textHeight
    let top = (bounds.height - total) / 2
    coverIconView.frame = CGRect(x: 0, y: top, width: bounds.width, height: iconSize.height)
    coverLabel.frame = TrendingInterstitialText.labelFrame(
      CGRect(x: (bounds.width - width) / 2, y: top + iconSize.height + DesignTokens.Spacing.xs,
        width: width, height: textHeight),
      for: text)
  }

  func updateImageLoading(
    _ card: TrendingInterstitialModel.VideoCard,
    layout: TrendingVideoCardLayout,
    policy: ModerationPolicy,
    displayScale: CGFloat,
    allowsImageLoading: Bool
  ) {
    guard appliedAllowsImageLoading != allowsImageLoading else { return }
    appliedAllowsImageLoading = allowsImageLoading
    let thumb = layout.thumbnailFrame
    switch card.thumbnail {
    case .covered:
      thumbnailSlot.setRequest(nil)
    case .image(let url):
      let request = TrendingTopicImageRequests.request(url, size: thumb.size, displayScale: displayScale, priority: .normal)
      thumbnailSlot.setRequest(request, allowsImageLoading: allowsImageLoading) { [weak self] phase in
        self?.fallbackIconView.isHidden = phase != .failed
      }
    case .none:
      thumbnailSlot.setRequest(nil)
    }
    avatarView.apply(
      source: AsyncProfileImage.source(
        url: card.post.author.finalAvatarURL(), sizeInPoints: layout.avatarFrame.width, displayScale: displayScale,
        did: card.post.author.did.didString(), labels: card.post.author.labels, policy: policy),
      allowsImageLoading: allowsImageLoading)
  }

  func prepareForRecycle() {
    thumbnailSlot.cancel()
    avatarView.prepareForRecycle()
    appliedAllowsImageLoading = nil
  }
}

// MARK: - Avatar

/// `AsyncProfileImage` for a UIKit cell: concealed avatars are never requested, cache hits paint
/// directly, and loads fade in over the person placeholder.
final class TrendingAvatarView: UIView {
  private let imageView = UIImageView()
  private let placeholderView = UIImageView()
  private let concealedView = UIImageView()
  private lazy var slot = TrendingImageSlot(imageView: imageView)

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    backgroundColor = UIColor.systemGray.withAlphaComponent(0.2)
    imageView.contentMode = .scaleAspectFill
    placeholderView.contentMode = .scaleAspectFill
    placeholderView.image = TrendingSymbolCache.symbol("person.crop.circle.fill")
    concealedView.contentMode = .scaleAspectFit
    concealedView.image = TrendingSymbolCache.symbol("eye.slash.fill")
    concealedView.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
    [placeholderView, concealedView, imageView].forEach(addSubview)
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    placeholderView.tintColor = tintColor.withAlphaComponent(0.5)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
    imageView.frame = bounds
    placeholderView.frame = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.width * 0.08)
    concealedView.frame = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.width * 0.25)
  }

  var startedImageRequestCountForTesting: Int { slot.startedRequestCountForTesting }

  func apply(source: AsyncProfileImage.Source, allowsImageLoading: Bool = true) {
    placeholderView.tintColor = tintColor.withAlphaComponent(0.5)
    switch source {
    case .concealed:
      slot.setRequest(nil)
      imageView.isHidden = true
      placeholderView.isHidden = true
      concealedView.isHidden = false
    case .placeholder:
      slot.setRequest(nil)
      imageView.isHidden = true
      placeholderView.isHidden = false
      concealedView.isHidden = true
    case .image(let request):
      concealedView.isHidden = true
      imageView.isHidden = false
      slot.setRequest(request, allowsImageLoading: allowsImageLoading, fadeIn: true) { [weak self] phase in
        self?.placeholderView.isHidden = phase == .loaded
      }
    }
  }

  func prepareForRecycle() {
    slot.cancel()
  }
}
#endif
