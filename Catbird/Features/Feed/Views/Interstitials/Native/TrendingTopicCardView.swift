#if os(iOS)
import Nuke
import UIKit

// MARK: - Topic Images

/// Resolves topic preview images the way `TrendingTopicImage` does: only the current moderated
/// request, memory-retained stills first, and loaded stills retained for the account.
@MainActor
struct TrendingTopicImages {
  let appState: AppState
  let displayScale: CGFloat

  var isSuspended: Bool { appState.isAccountSwitchSuspended }

  func mediaRequest(_ url: URL) -> ImageRequest {
    TrendingTopicImageRequests.request(
      url, size: TrendingTopicImageRequests.cardSize, displayScale: displayScale, priority: .normal)
  }

  func avatarRequest(_ url: URL) -> ImageRequest {
    TrendingTopicImageRequests.avatarRequest(
      url, size: TrendingTopicImageRequests.avatarSize, displayScale: displayScale, priority: .normal)
  }

  func load(_ request: ImageRequest, into slot: TrendingImageSlot) {
    guard !isSuspended else {
      slot.setRequest(nil)
      return
    }
    let store = appState.trendingTopicMediaStore
    let revision = store.revision
    let viewerDID = appState.userDID
    let appState = appState
    slot.setRequest(request, memoryImage: store.image(for: request), onLoaded: { image in
      guard !appState.isAccountSwitchSuspended, appState.userDID == viewerDID,
            appState.appSettings.showTrendingTopics, appState.topicPreviewLabelerScopeIsCurrent else { return }
      store.retainImage(image, for: request, revision: revision)
    })
  }
}

// MARK: - Card Control

/// A plain button surface: dims while pressed, like SwiftUI's `.plain` button style.
class TrendingCardControl: UIControl {
  override var isHighlighted: Bool {
    didSet {
      guard isHighlighted != oldValue else { return }
      alpha = isHighlighted ? 0.7 : 1
    }
  }
}

// MARK: - Topic Card

/// One topic card: category mark and title, the media fan beside (or, at accessibility sizes,
/// above) the description, and participants with the post count. The whole card is one
/// accessibility element whose label joins its visible text.
final class TrendingTopicCardView: TrendingCardControl {
  private let markView = UIView()
  private let markImageView = UIImageView()
  private let categoryLabel = TrendingTopicCardView.makeLabel()
  private let titleLabel = TrendingTopicCardView.makeLabel()
  private let descriptionLabel = TrendingTopicCardView.makeLabel()
  private let postCountLabel = TrendingTopicCardView.makeLabel(lines: 1)
  private let fanView = UIView()
  private let fanCards = (0..<3).map { _ in TrendingFanCardView() }
  private let participantsView = UIView()
  private let participantViews = (0..<3).map { _ in TrendingCircleImageView(frame: .zero) }
  private lazy var fanSlots = fanCards.map { TrendingImageSlot(imageView: $0.imageView) }
  private lazy var participantSlots = participantViews.map { TrendingImageSlot(imageView: $0) }

  private(set) var trendLink: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = TrendingInterstitialMetrics.topicCardCornerRadius
    layer.cornerCurve = .continuous
    backgroundColor = TrendingInterstitialColors.cardFill
    markView.layer.cornerCurve = .circular
    markImageView.contentMode = .center
    markView.addSubview(markImageView)
    fanView.clipsToBounds = false
    fanCards.forEach(fanView.addSubview)
    participantViews.forEach(participantsView.addSubview)
    for view in [markView, categoryLabel, titleLabel, fanView, descriptionLabel, participantsView, postCountLabel] {
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    isAccessibilityElement = true
    accessibilityTraits = .button
    accessibilityHint = "Open posts about this topic"
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func makeLabel(lines: Int = 0) -> UILabel {
    let label = UILabel()
    label.numberOfLines = lines
    label.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
    return label
  }

  func apply(
    _ topic: TrendingInterstitialModel.Topic,
    layout: TrendingTopicCardLayout,
    size: CGSize,
    typography t: TrendingInterstitialTypography,
    isRightToLeft rtl: Bool,
    reduceMotion: Bool,
    images: TrendingTopicImages
  ) {
    trendLink = topic.trend.link
    accessibilityLabel = topic.accessibilityLabel
    func place(_ view: UIView, _ frame: CGRect) {
      view.frame = rtl ? CGRect(x: size.width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
    }

    // Category mark
    let tint = topic.tint.uiColor
    place(markView, layout.markFrame)
    markView.layer.cornerRadius = layout.markFrame.width / 2
    markView.backgroundColor = tint.withAlphaComponent(0.12)
    markImageView.frame = markView.bounds
    markImageView.image = TrendingSymbolCache.categoryMark(topic.symbol, pointSize: t.markIconPointSize, tint: topic.tint)

    // Texts
    let texts = TrendingInterstitialLayoutEngine.topicTexts(topic.layout, typography: t)
    let alignment: NSTextAlignment = rtl ? .right : .left
    categoryLabel.isHidden = texts.category == nil
    if let category = texts.category, let frame = layout.categoryFrame {
      categoryLabel.attributedText = category.withColor(tint)
      categoryLabel.textAlignment = alignment
      place(categoryLabel, frame)
    }
    titleLabel.attributedText = texts.title
    titleLabel.textAlignment = alignment
    place(titleLabel, layout.titleFrame)
    descriptionLabel.isHidden = texts.description == nil
    if let description = texts.description, let frame = layout.descriptionFrame {
      descriptionLabel.attributedText = description
      descriptionLabel.textAlignment = alignment
      place(descriptionLabel, frame)
    }
    postCountLabel.isHidden = texts.postCount == nil
    if let postCount = texts.postCount, let frame = layout.postCountFrame {
      postCountLabel.attributedText = postCount
      place(postCountLabel, frame)
    }

    // Media fan: up to three rotated stills, centered in the fixed 108×86 frame.
    place(fanView, layout.mediaFanFrame)
    let fan = TrendingInterstitialMetrics.mediaFanSize
    let card = TrendingInterstitialMetrics.mediaCardSize
    let direction: CGFloat = rtl ? -1 : 1
    let center = CGFloat(topic.media.count - 1) / 2
    for (index, view) in fanCards.enumerated() {
      guard index < topic.media.count else {
        view.isHidden = true
        fanSlots[index].cancel()
        view.imageView.image = nil
        continue
      }
      view.isHidden = false
      view.transform = .identity
      view.bounds = CGRect(origin: .zero, size: card)
      view.center = CGPoint(
        x: fan.width / 2 + (CGFloat(index) - center) * 18 * direction,
        y: fan.height / 2 + (index == 1 ? -2 : 2))
      let angle = reduceMotion ? 0 : [-9.0, 4.0, 11.0][index % 3] * Double(direction)
      view.transform = CGAffineTransform(rotationAngle: CGFloat(angle * .pi / 180))
      view.updateShadow(for: traitCollection)
      images.load(images.mediaRequest(topic.media[index].url), into: fanSlots[index])
    }

    // Participants: overlapping circles, later ones on top.
    participantsView.isHidden = layout.participantsFrame == nil
    if let frame = layout.participantsFrame {
      place(participantsView, frame)
      let side = TrendingInterstitialMetrics.participantSide
      let step = side - TrendingInterstitialMetrics.participantOverlap
      for (index, view) in participantViews.enumerated() {
        guard index < topic.participants.count else {
          view.isHidden = true
          participantSlots[index].cancel()
          view.image = nil
          continue
        }
        view.isHidden = false
        let x = CGFloat(index) * step
        view.frame = CGRect(x: rtl ? frame.width - x - side : x, y: 0, width: side, height: side)
        images.load(images.avatarRequest(topic.participants[index].avatar), into: participantSlots[index])
      }
    } else {
      participantSlots.forEach { $0.cancel() }
    }
  }

  /// Stops image work for a card leaving the carousel or the cell.
  func prepareForRecycle() {
    fanSlots.forEach { $0.cancel() }
    participantSlots.forEach { $0.cancel() }
    trendLink = nil
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      fanCards.forEach { $0.updateShadow(for: traitCollection) }
      participantViews.forEach { $0.updateBorder(for: traitCollection) }
    }
  }
}

// MARK: - Fan Card

/// One still of the media fan: rounded, with a 2pt background-colored border and a soft shadow.
final class TrendingFanCardView: UIView {
  let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    let radius = TrendingInterstitialMetrics.mediaCardCornerRadius
    let size = TrendingInterstitialMetrics.mediaCardSize
    imageView.frame = CGRect(origin: .zero, size: size)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = radius
    imageView.layer.cornerCurve = .continuous
    imageView.layer.borderWidth = 2
    addSubview(imageView)
    layer.shadowOffset = CGSize(width: 0, height: 2)
    layer.shadowRadius = 3
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius).cgPath
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func updateShadow(for traits: UITraitCollection) {
    layer.shadowOpacity = traits.userInterfaceStyle == .dark ? 0.3 : 0.15
    imageView.layer.borderColor = UIColor.systemBackground.resolvedColor(with: traits).cgColor
  }
}

// MARK: - Circle Image

/// A participant avatar: a circle with a 2pt background-colored inner border.
final class TrendingCircleImageView: UIImageView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    contentMode = .scaleAspectFill
    clipsToBounds = true
    layer.borderWidth = 2
    updateBorder(for: traitCollection)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width / 2
  }

  func updateBorder(for traits: UITraitCollection) {
    layer.borderColor = UIColor.systemBackground.resolvedColor(with: traits).cgColor
  }
}

// MARK: - Attributed Helpers

extension NSAttributedString {
  func withColor(_ color: UIColor) -> NSAttributedString {
    let copy = NSMutableAttributedString(attributedString: self)
    copy.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: copy.length))
    return copy
  }
}
#endif
