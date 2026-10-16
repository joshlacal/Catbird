#if os(iOS)
import Petrel
import SwiftUI
import UIKit

// MARK: - Trending Interstitial Cell

/// The home feed's trending interstitial: topic cards and trending videos in a native cell, because
/// a hosted SwiftUI row costs more than a 120 Hz frame each time it scrolls in. Heights come from
/// `TrendingInterstitialLayoutEngine`; subviews are created once and reused, and carousel cards are
/// created only as they scroll into view.
@available(iOS 16.0, *)
final class TrendingInterstitialCell: UICollectionViewCell, UIScrollViewDelegate {
  /// The feed registers this cell by reuse identifier rather than with a `CellRegistration`: a
  /// registration bridges its item to Objective-C on every dequeue, and the first bridge of a
  /// `Void` item searches every protocol conformance in the process, about 5 ms in the frame where
  /// the interstitial first scrolls in.
  static let reuseIdentifier = "TrendingInterstitialCell"

  struct Configuration {
    let content: TrendingFeedContent
    let appState: AppState
    let sceneContext: SceneNavigationContext
  }

  // MARK: State

  private var configuration: Configuration?
  private var allowsImageLoading = true
  private var model = TrendingInterstitialModel.empty
  private var videoCards: [String: TrendingInterstitialModel.VideoCard] = [:]
  private var typography: TrendingInterstitialTypography?
  private var modelGeneration = 0
  private var appliedLayout: TrendingInterstitialLayout?
  private var appliedModelGeneration = -1
  private var appliedDirection: UIUserInterfaceLayoutDirection?
  private var appliedDarkThemeMode: ThemeManager.DarkThemeMode?
  private var previewTasks: [String: Task<Void, Never>] = [:]
  private var previewWorkScheduled = false
  private(set) var lastCarouselScrollAt: TimeInterval = 0
  /// Each instance is one zoom-transition section; its routes carry this ID.
  private let sectionID = UUID()
  private let zoomAnchors = TrendingVideoZoomAnchorHost()

  // MARK: Views

  private let headerLabel = UILabel()
  private let optionsButton = UIButton(type: .system)
  private let topicsScrollView = UIScrollView()
  private let videosHeaderLabel = UILabel()
  private let openVideosButton = TrendingDisclosureButton(frame: .zero)
  private let videosScrollView = UIScrollView()
  private let emptyVideosLabel = UILabel()
  private let divider = UIView()

  private static let maxCardPoolSize = 16
  private static var sharedTopicCardPool: [TrendingTopicCardView] = []
  private static var sharedVideoCardPool: [TrendingVideoCardView] = []
  private static var sharedTopicCardsByIndex: [Int: TrendingTopicCardView] = [:]
  private static var sharedVideoCardsByIndex: [Int: TrendingVideoCardView] = [:]
  private static var sharedVideoCardCache: [String: TrendingInterstitialModel.VideoCard] = [:]

  private var visibleTopicCards: [Int: TrendingTopicCardView] = [:]
  private var visibleVideoCards: [Int: TrendingVideoCardView] = [:]

  // MARK: Init

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundConfiguration = nil
    contentView.clipsToBounds = true

    headerLabel.numberOfLines = 0
    videosHeaderLabel.numberOfLines = 0

    optionsButton.showsMenuAsPrimaryAction = true
    optionsButton.accessibilityLabel = "Trending options"
    optionsButton.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        MainActor.assumeIsolated { completion(self?.optionsMenuItems() ?? []) }
      }
    ])

    openVideosButton.accessibilityLabel = TrendingInterstitialLayoutEngine.openVideosTitle
    openVideosButton.accessibilityHint = "Open the full-screen Bluesky video feed"
    openVideosButton.addTarget(self, action: #selector(openVideosTapped), for: .touchUpInside)

    for scrollView in [topicsScrollView, videosScrollView] {
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.showsVerticalScrollIndicator = false
      scrollView.alwaysBounceVertical = false
      scrollView.scrollsToTop = false
      scrollView.clipsToBounds = false
      scrollView.delegate = self
    }

    emptyVideosLabel.numberOfLines = 0
    divider.backgroundColor = .separator

    for view in [headerLabel, optionsButton, topicsScrollView, videosHeaderLabel, openVideosButton,
                 videosScrollView, emptyVideosLabel, divider] {
      contentView.addSubview(view)
    }
    NotificationCenter.default.addObserver(
      self, selector: #selector(acceptLabelersChanged(_:)),
      name: PreferencesManager.acceptLabelersHeaderDidChange, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(voiceOverStatusChanged),
      name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The options glyph draws in the tint at half opacity, as a `.secondary` menu label does.
  override func tintColorDidChange() {
    super.tintColorDidChange()
    optionsButton.tintColor = tintColor.withAlphaComponent(0.5)
  }

  // MARK: Configuration

  /// Scrolling the row back in reconfigures it with the same content: the model, layout and
  /// subviews are kept, so that costs almost nothing. The model is rebuilt only for new content
  /// or when an observed input changes (`inputsChanged`).
  func configure(_ configuration: Configuration) {
    // Array equality short-circuits on shared storage, so unchanged content compares in O(1).
    let contentChanged = self.configuration?.content != configuration.content
      || self.configuration?.appState !== configuration.appState
    self.configuration = configuration
    let darkThemeMode = configuration.appState.themeManager.darkThemeMode
    if darkThemeMode != appliedDarkThemeMode {
      appliedDarkThemeMode = darkThemeMode
      contentView.backgroundColor = TrendingInterstitialColors.background(darkThemeMode: darkThemeMode)
    }
    let resolved = TrendingInterstitialTypography.resolved(
      fontManager: configuration.appState.fontManager, traits: traitCollection)
    if resolved.generationKey != typography?.generationKey {
      typography = resolved
      setNeedsLayout()
    }
    if contentChanged {
      rebuildModel()
      zoomAnchors.remove()
      topicsScrollView.contentOffset = .zero
      videosScrollView.contentOffset = .zero
      appliedDirection = nil
      setNeedsLayout()
    }
    schedulePreviewWork()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Cards, images and the applied layout stay: the feed has one trending row, and this cell
    // returns for it. Only work tied to being on screen stops.
    cancelPreviewTasks()
  }

  /// Resolves what the first appearance would otherwise pay for (typography, the moderated
  /// model, text measurement and symbol images) while the feed is idle after trending content
  /// arrives, so the first scroll past the row stays within a frame.
  static func prepare(_ configuration: Configuration, width: CGFloat, traits: UITraitCollection) {
    let typography = TrendingInterstitialTypography.resolved(
      fontManager: configuration.appState.fontManager, traits: traits)
    let model = TrendingInterstitialModel.make(content: configuration.content, appState: configuration.appState)
    guard model.hasContent, width > 0 else { return }
    _ = TrendingInterstitialLayoutCache.layout(for: model.layoutInput(width: width, typography: typography))
    TrendingSymbolCache.prepare(typography: typography, categories: model.topics.map { ($0.symbol, $0.tint) })
  }

  /// Resolves UIKit construction, symbol rasterization and label backing stores as well as the
  /// model/layout caches. The caller gates this to idle time once per process. This cell is never
  /// attached to a window, so it cannot become a zoom source or start topic-preview prefetching.
  @discardableResult
  static func prepareFirstDisplay(_ configuration: Configuration, width: CGFloat, traits: UITraitCollection) -> Int {
    prepare(configuration, width: width, traits: traits)
    let cell = TrendingInterstitialCell(frame: CGRect(x: 0, y: 0, width: width, height: 1))
    cell.allowsImageLoading = false
    cell.traitOverrides.userInterfaceStyle = traits.userInterfaceStyle
    cell.traitOverrides.displayScale = traits.displayScale
    cell.traitOverrides.preferredContentSizeCategory = traits.preferredContentSizeCategory
    cell.traitOverrides.legibilityWeight = traits.legibilityWeight
    cell.traitOverrides.layoutDirection = traits.layoutDirection
    cell.configure(configuration)
    for index in 0..<cell.model.videos.count {
      _ = cell.videoCard(at: index)
    }
    let height = cell.systemLayoutSizeFitting(
      CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel).height
    cell.frame.size.height = height
    cell.layoutIfNeeded()
    func display(_ layer: CALayer) {
      layer.displayIfNeeded()
      layer.sublayers?.forEach(display)
    }
    display(cell.layer)

    // Pre-warm cards into shared indexed pools so live dequeue reuses exactly matching cards with zero allocation and zero re-render
    if let typography = cell.typography, let layout = cell.appliedLayout {
      let images = TrendingTopicImages(appState: configuration.appState, displayScale: traits.displayScale, allowsImageLoading: false)
      let reduceMotion = UIAccessibility.isReduceMotionEnabled
      let topicSize = layout.topicCardSize
      let totalTopics = min(cell.model.topics.count, layout.topicCards.count)
      for index in 0..<totalTopics {
        let card: TrendingTopicCardView
        if let visible = cell.visibleTopicCards[index] {
          card = visible
          card.removeFromSuperview()
        } else {
          card = cell.makeTopicCard()
          let x = layout.topicCardX[index]
          card.frame = CGRect(x: x, y: 0, width: topicSize.width, height: topicSize.height)
          card.apply(
            cell.model.topics[index], layout: layout.topicCards[index], size: topicSize, typography: typography,
            isRightToLeft: false, reduceMotion: reduceMotion, images: images)
          display(card.layer)
        }
        card.isHidden = true
        Self.sharedTopicCardsByIndex[index] = card
      }
      cell.visibleTopicCards.removeAll()

      let videoSize = layout.videoCardSize
      let totalVideos = min(cell.model.videos.count, layout.videoCardX.count)
      for index in 0..<totalVideos {
        let card: TrendingVideoCardView
        if let visible = cell.visibleVideoCards[index] {
          card = visible
          card.removeFromSuperview()
        } else {
          card = cell.makeVideoCard()
          let x = layout.videoCardX[index]
          card.frame = CGRect(x: x, y: 0, width: videoSize.width, height: videoSize.height)
          card.apply(
            cell.videoCard(at: index), layout: layout.videoCard, size: videoSize, typography: typography,
            isRightToLeft: false, policy: cell.model.policy, displayScale: traits.displayScale,
            allowsImageLoading: false)
          display(card.layer)
        }
        card.isHidden = true
        Self.sharedVideoCardsByIndex[index] = card
      }
      cell.visibleVideoCards.removeAll()
    }

    return cell.startedImageRequestCountForTesting
  }

  var startedImageRequestCountForTesting: Int {
    visibleTopicCards.values.reduce(0) { $0 + $1.startedImageRequestCountForTesting }
      + visibleVideoCards.values.reduce(0) { $0 + $1.startedImageRequestCountForTesting }
  }

  /// Builds the model while tracking every observable input it reads, so a change to trending
  /// settings, the moderation policy or a topic's preview refreshes the cell.
  private func rebuildModel() {
    modelGeneration += 1
    let generation = modelGeneration
    videoCards.removeAll()
    guard let configuration else {
      model = .empty
      return
    }
    model = withObservationTracking {
      TrendingInterstitialModel.make(content: configuration.content, appState: configuration.appState)
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.inputsChanged(generation: generation) }
    }
  }

  private func inputsChanged(generation: Int) {
    guard generation == modelGeneration, let configuration else { return }
    let previous = model
    let width = contentView.bounds.width
    let previousHeight = layout(width: width).height
    rebuildModel()
    if previous.showTopics && !model.showTopics {
      configuration.appState.cancelTopicPreviewPrefetch(owner: .timeline)
    }
    let newLayout = layout(width: width)
    if newLayout.height != previousHeight {
      // Self-sizing invalidation: the collection view asks for the new height.
      setNeedsLayout()
      invalidateIntrinsicContentSize()
    } else if newLayout != appliedLayout {
      setNeedsLayout()
    }
    schedulePreviewWork()
  }

  private func layout(width: CGFloat) -> TrendingInterstitialLayout {
    guard let typography, width > 0, model.hasContent else { return .empty }
    return TrendingInterstitialLayoutCache.layout(for: model.layoutInput(width: width, typography: typography))
  }

  // MARK: Sizing

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

  // MARK: Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = contentView.bounds.width
    guard let typography, let configuration else { return }
    let layout = layout(width: width)
    let direction = effectiveUserInterfaceLayoutDirection
    guard layout != appliedLayout || appliedModelGeneration != modelGeneration || appliedDirection != direction else {
      return
    }
    let directionChanged = appliedDirection != nil && appliedDirection != direction
    appliedLayout = layout
    appliedModelGeneration = modelGeneration
    appliedDirection = direction
    apply(layout, typography: typography, appState: configuration.appState, directionChanged: directionChanged)
  }

  private var isRightToLeft: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

  private func mirrored(_ frame: CGRect, in width: CGFloat) -> CGRect {
    isRightToLeft ? CGRect(x: width - frame.maxX, y: frame.minY, width: frame.width, height: frame.height) : frame
  }

  private func apply(
    _ layout: TrendingInterstitialLayout, typography t: TrendingInterstitialTypography, appState: AppState,
    directionChanged: Bool
  ) {
    let width = layout.width
    let hasContent = layout.height > 0
    contentView.isHidden = !hasContent
    guard hasContent else {
      recycleAllCards()
      return
    }
    let alignment: NSTextAlignment = isRightToLeft ? .right : .left

    // Header
    headerLabel.attributedText = TrendingInterstitialLayoutEngine.headingText(
      TrendingInterstitialLayoutEngine.topicsHeading, typography: t)
    headerLabel.textAlignment = alignment
    headerLabel.frame = mirrored(layout.header.titleFrame, in: width)
    optionsButton.frame = mirrored(layout.header.actionFrame, in: width)
    optionsButton.setImage(TrendingSymbolCache.symbol("ellipsis", font: t.optionsGlyph), for: .normal)
    optionsButton.tintColor = tintColor.withAlphaComponent(0.5)

    // Topics
    if let frame = layout.topicsFrame {
      topicsScrollView.isHidden = false
      topicsScrollView.frame = frame
      let previousContentWidth = topicsScrollView.contentSize.width
      topicsScrollView.contentSize = CGSize(width: layout.topicsContentWidth, height: frame.height)
      alignCarouselStart(topicsScrollView, previousContentWidth: previousContentWidth, force: directionChanged)
    } else {
      topicsScrollView.isHidden = true
    }
    updateVisibleTopicCards()

    // Videos
    if let header = layout.videosHeader {
      videosHeaderLabel.isHidden = false
      openVideosButton.isHidden = false
      videosHeaderLabel.attributedText = TrendingInterstitialLayoutEngine.headingText(
        TrendingInterstitialLayoutEngine.videosHeading, typography: t)
      videosHeaderLabel.textAlignment = alignment
      videosHeaderLabel.frame = mirrored(header.titleFrame, in: width)
      openVideosButton.frame = mirrored(header.actionFrame, in: width)
      openVideosButton.apply(
        title: TrendingInterstitialLayoutEngine.openVideosText(typography: t), glyph: t.disclosureGlyph,
        isRightToLeft: isRightToLeft)
    } else {
      videosHeaderLabel.isHidden = true
      openVideosButton.isHidden = true
    }
    if let frame = layout.videosFrame {
      videosScrollView.isHidden = false
      videosScrollView.frame = frame
      let previousContentWidth = videosScrollView.contentSize.width
      videosScrollView.contentSize = CGSize(width: layout.videosContentWidth, height: frame.height)
      alignCarouselStart(videosScrollView, previousContentWidth: previousContentWidth, force: directionChanged)
    } else {
      videosScrollView.isHidden = true
    }
    updateVisibleVideoCards()

    if let frame = layout.emptyVideosFrame {
      emptyVideosLabel.isHidden = false
      emptyVideosLabel.attributedText = TrendingInterstitialText.attributed(
        TrendingInterstitialModel.emptyVideosMessage, font: t.subheadline, color: .secondaryLabel,
        lineSpacing: t.roleLineSpacing, kerning: t.kerning, alignment: alignment)
      emptyVideosLabel.frame = mirrored(frame, in: width)
    } else {
      emptyVideosLabel.isHidden = true
    }

    let hairline = 1 / max(1, traitCollection.displayScale)
    divider.frame = CGRect(x: 0, y: layout.height - hairline, width: width, height: hairline)
  }

  /// A carousel starts at its leading edge: offset zero, or the far end in right-to-left layouts.
  private func alignCarouselStart(_ scrollView: UIScrollView, previousContentWidth: CGFloat, force: Bool) {
    let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
    if isRightToLeft {
      if force || previousContentWidth != scrollView.contentSize.width || scrollView.contentOffset.x > maxOffset {
        scrollView.contentOffset.x = maxOffset
      }
    } else if force || scrollView.contentOffset.x > maxOffset {
      scrollView.contentOffset.x = 0
    }
  }

  // MARK: Carousels

  /// Cards whose frames meet the carousel's visible region; the rest are created as a horizontal
  /// scroll reaches them, which keeps the row's first frame small. With VoiceOver every card
  /// exists, so swiping reaches the cards beyond the screen.
  private func visibleIndices(count: Int, positions: [CGFloat], cardWidth: CGFloat, in scrollView: UIScrollView) -> [Int] {
    guard count > 0 else { return [] }
    if UIAccessibility.isVoiceOverRunning { return Array(0..<count) }
    let contentWidth = scrollView.contentSize.width
    let visible = CGRect(x: scrollView.contentOffset.x, y: 0, width: scrollView.bounds.width, height: 1)
    return (0..<count).filter { index in
      let x = isRightToLeft ? contentWidth - positions[index] - cardWidth : positions[index]
      return CGRect(x: x, y: 0, width: cardWidth, height: 1).intersects(visible)
    }
  }

  private func updateVisibleTopicCards() {
    guard let layout = appliedLayout, let typography, let configuration, layout.topicsFrame != nil else { return }
    let size = layout.topicCardSize
    let wanted = Set(visibleIndices(
      count: min(model.topics.count, layout.topicCards.count), positions: layout.topicCardX,
      cardWidth: size.width, in: topicsScrollView))
    for (index, card) in visibleTopicCards where !wanted.contains(index) {
      recycle(card)
      visibleTopicCards[index] = nil
    }
    let images = TrendingTopicImages(appState: configuration.appState, displayScale: traitCollection.displayScale,
      allowsImageLoading: allowsImageLoading)
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    for index in wanted.sorted() {
      let card: TrendingTopicCardView
      if let existing = visibleTopicCards[index] {
        card = existing
      } else {
        card = Self.sharedTopicCardsByIndex.removeValue(forKey: index)
          ?? Self.sharedTopicCardPool.popLast()
          ?? makeTopicCard()
        card.removeTarget(nil, action: nil, for: .allEvents)
        card.addTarget(self, action: #selector(topicCardTapped(_:)), for: .touchUpInside)
        if card.superview !== topicsScrollView { topicsScrollView.addSubview(card) }
        visibleTopicCards[index] = card
      }
      let x = isRightToLeft ? layout.topicsContentWidth - layout.topicCardX[index] - size.width : layout.topicCardX[index]
      card.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
      card.apply(
        model.topics[index], layout: layout.topicCards[index], size: size, typography: typography,
        isRightToLeft: isRightToLeft, reduceMotion: reduceMotion, images: images)
      card.isHidden = false
    }
  }

  private func updateVisibleVideoCards() {
    guard let layout = appliedLayout, let typography, layout.videosFrame != nil else { return }
    let size = layout.videoCardSize
    let wanted = Set(visibleIndices(
      count: min(model.videos.count, layout.videoCardX.count), positions: layout.videoCardX,
      cardWidth: size.width, in: videosScrollView))
    for (index, card) in visibleVideoCards where !wanted.contains(index) {
      recycle(card)
      visibleVideoCards[index] = nil
    }
    for index in wanted.sorted() {
      let card: TrendingVideoCardView
      if let existing = visibleVideoCards[index] {
        card = existing
      } else {
        card = Self.sharedVideoCardsByIndex.removeValue(forKey: index)
          ?? Self.sharedVideoCardPool.popLast()
          ?? makeVideoCard()
        card.removeTarget(nil, action: nil, for: .allEvents)
        card.addTarget(self, action: #selector(videoCardTapped(_:)), for: .touchUpInside)
        if card.superview !== videosScrollView { videosScrollView.addSubview(card) }
        visibleVideoCards[index] = card
      }
      let x = isRightToLeft ? layout.videosContentWidth - layout.videoCardX[index] - size.width : layout.videoCardX[index]
      card.frame = CGRect(x: x, y: 0, width: size.width, height: size.height)
      card.apply(
        videoCard(at: index), layout: layout.videoCard, size: size, typography: typography,
        isRightToLeft: isRightToLeft, policy: model.policy, displayScale: traitCollection.displayScale,
        allowsImageLoading: allowsImageLoading)
      card.isHidden = false
    }
  }

  /// Moderation for a video card is evaluated when it first scrolls into view, once per model.
  private func videoCard(at index: Int) -> TrendingInterstitialModel.VideoCard {
    let post = model.videos[index].post
    let uri = post.uri.uriString()
    if let card = Self.sharedVideoCardCache[uri] { return card }
    if let card = videoCards[uri] { return card }
    let card = TrendingInterstitialModel.videoCard(for: post, policy: model.policy)
    videoCards[uri] = card
    Self.sharedVideoCardCache[uri] = card
    return card
  }

  private func makeTopicCard() -> TrendingTopicCardView {
    let card = TrendingTopicCardView(frame: .zero)
    card.addTarget(self, action: #selector(topicCardTapped(_:)), for: .touchUpInside)
    return card
  }

  private func makeVideoCard() -> TrendingVideoCardView {
    let card = TrendingVideoCardView(frame: .zero)
    card.addTarget(self, action: #selector(videoCardTapped(_:)), for: .touchUpInside)
    return card
  }

  private func recycle(_ card: TrendingTopicCardView) {
    card.prepareForRecycle()
    card.isHidden = true
    card.removeFromSuperview()
    card.removeTarget(nil, action: nil, for: .allEvents)
    if Self.sharedTopicCardPool.count < Self.maxCardPoolSize {
      Self.sharedTopicCardPool.append(card)
    }
  }

  private func recycle(_ card: TrendingVideoCardView) {
    zoomAnchors.remove(ifIn: card)
    card.prepareForRecycle()
    card.isHidden = true
    card.removeFromSuperview()
    card.removeTarget(nil, action: nil, for: .allEvents)
    if Self.sharedVideoCardPool.count < Self.maxCardPoolSize {
      Self.sharedVideoCardPool.append(card)
    }
  }

  static func clearSharedCardPoolsForTesting() {
    sharedTopicCardsByIndex.removeAll()
    sharedVideoCardsByIndex.removeAll()
    sharedTopicCardPool.removeAll()
    sharedVideoCardPool.removeAll()
    sharedVideoCardCache.removeAll()
  }

  deinit {
    for (_, card) in visibleTopicCards {
      card.removeFromSuperview()
      card.removeTarget(nil, action: nil, for: .allEvents)
    }
    for (_, card) in visibleVideoCards {
      card.removeFromSuperview()
      card.removeTarget(nil, action: nil, for: .allEvents)
    }
  }

  private func recycleAllCards() {
    for (_, card) in visibleTopicCards { recycle(card) }
    for (_, card) in visibleVideoCards { recycle(card) }
    visibleTopicCards.removeAll()
    visibleVideoCards.removeAll()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === topicsScrollView || scrollView === videosScrollView else { return }
    lastCarouselScrollAt = ProcessInfo.processInfo.systemUptime
    if scrollView === topicsScrollView {
      updateVisibleTopicCards()
    } else if scrollView === videosScrollView {
      updateVisibleVideoCards()
    }
  }

  @objc private func voiceOverStatusChanged() {
    updateVisibleTopicCards()
    updateVisibleVideoCards()
  }

  // MARK: Actions

  @objc private func topicCardTapped(_ card: TrendingTopicCardView) {
    guard let link = card.trendLink, let configuration,
          let url = URL(string: link, relativeTo: URL(string: "https://bsky.app")) else { return }
    _ = configuration.sceneContext.urlHandler.handle(url.absoluteURL)
  }

  @objc private func videoCardTapped(_ card: TrendingVideoCardView) {
    guard let uri = card.postURI,
          let post = model.videos.first(where: { $0.post.uri.uriString() == uri })?.post else { return }
    let thumbnail = card.thumbnailContainer
    openVideoFeed(
      startingAt: post, source: thumbnail, cornerRadius: TrendingInterstitialMetrics.videoCornerRadius,
      conceal: { thumbnail.isHidden = $0 })
  }

  @objc private func openVideosTapped() {
    // The label is the zoom source, clipped with a 12pt radius as in `TrendingVideosSection`.
    let button = openVideosButton
    openVideoFeed(startingAt: nil, source: button, cornerRadius: 12, conceal: { button.setContentHidden($0) })
  }

  /// `TrendingVideosSection.openVideoFeed`: a zoom from the tapped source on iOS 18 unless Reduce
  /// Motion is on, otherwise the plain route. `conceal` hides the source's own drawing while the
  /// anchor shows it.
  private func openVideoFeed(
    startingAt post: AppBskyFeedDefs.PostView?, source: UIView, cornerRadius: CGFloat,
    conceal: @escaping (Bool) -> Void
  ) {
    guard let configuration else { return }
    let navigationManager = configuration.sceneContext.navigationManager
    if #available(iOS 18.0, *), !UIAccessibility.isReduceMotionEnabled {
      let sectionID = sectionID
      let postURI = post?.uri.uriString()
      guard let parent = owningViewController else { return }
      zoomAnchors.mount(over: source, in: parent, postURI: postURI, cornerRadius: cornerRadius, conceal: conceal) { namespace in
        let zoomSource = VideoFeedZoomSource(sectionID: sectionID, postURI: postURI, namespace: namespace)
        navigationManager.navigate(to: .videoFeedZoom(initialPost: post, source: zoomSource))
      }
      return
    }
    if let post {
      navigationManager.navigate(to: .videoFeedStartingAt(post))
    } else {
      navigationManager.navigate(to: .videoFeed)
    }
  }

  private enum HideTarget {
    case topics, videos

    var name: String { self == .topics ? "trending topics" : "trending videos" }
  }

  private func optionsMenuItems() -> [UIMenuElement] {
    var items: [UIMenuElement] = []
    if model.showTopics {
      items.append(UIAction(title: "Hide trending topics…", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
        self?.confirmHide(.topics)
      })
    }
    if model.showVideos {
      items.append(UIAction(title: "Hide trending videos…", image: UIImage(systemName: "eye.slash")) { [weak self] _ in
        self?.confirmHide(.videos)
      })
    }
    return items
  }

  /// A titled action sheet with a destructive choice.
  private func confirmHide(_ target: HideTarget) {
    guard let presenter = presentingViewController else { return }
    let alert = UIAlertController(
      title: "Hide \(target.name)?",
      message: "This hides \(target.name) for this account in Feeds and Search. You can turn them back on in Settings › Feeds & Discovery › Discovery.",
      preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "Hide in Feeds and Search", style: .destructive) { [weak self] _ in
      MainActor.assumeIsolated { self?.hide(target) }
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.sourceView = optionsButton
      popover.sourceRect = optionsButton.bounds
    }
    presenter.present(alert, animated: true)
  }

  private func hide(_ target: HideTarget) {
    guard let appState = configuration?.appState else { return }
    switch target {
    case .topics: appState.appSettings.showTrendingTopics = false
    case .videos: appState.appSettings.showTrendingVideos = false
    }
  }

  /// The view controller whose view contains the feed.
  private var owningViewController: UIViewController? {
    var responder: UIResponder? = next
    while let current = responder {
      if let controller = current as? UIViewController { return controller }
      responder = current.next
    }
    return nil
  }

  private var presentingViewController: UIViewController? {
    guard var top = owningViewController else { return nil }
    while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
    return top
  }

  // MARK: Topic Previews

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      cancelPreviewTasks()
    } else {
      schedulePreviewWork()
    }
  }

  /// Warms every trend's preview (images included) and loads the shown topics' previews each time
  /// the row appears, after the current frame so scrolling does not wait for it.
  private func schedulePreviewWork() {
    guard window != nil, !previewWorkScheduled else { return }
    guard !ProcessInfo.processInfo.arguments.contains("--feed-perf-autoscroll") else { return }
    previewWorkScheduled = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.previewWorkScheduled = false
      self.startPreviewWork()
    }
  }

  private func startPreviewWork() {
    guard window != nil, let configuration else { return }
    let appState = configuration.appState
    guard model.showTopics, !model.topics.isEmpty else {
      cancelPreviewTasks()
      return
    }
    appState.prefetchTopicPreviews(
      trends: configuration.content.trends, displayScale: traitCollection.displayScale, owner: .timeline)
    let scope = appState.topicPreviewLabelers + "|" + appState.topicPreviewAppliedLabelers
      + "|\(appState.trendingTopicMediaStore.revision)|"
    var identities = Set<String>()
    for topic in model.topics {
      let link = topic.trend.link
      let identity = scope + link
      identities.insert(identity)
      guard previewTasks[identity] == nil else { continue }
      previewTasks[identity] = Task { @MainActor [weak self] in
        await appState.loadTopicPreview(for: link)
        self?.previewTasks[identity] = nil
      }
    }
    for (identity, task) in previewTasks where !identities.contains(identity) {
      task.cancel()
      previewTasks[identity] = nil
    }
  }

  private func cancelPreviewTasks() {
    previewTasks.values.forEach { $0.cancel() }
    previewTasks.removeAll()
  }

  @objc private func acceptLabelersChanged(_ notification: Notification) {
    guard window != nil, model.showTopics, !model.topics.isEmpty, let appState = configuration?.appState,
          ProfileLabelRefresh.matches(
            notification, preferencesManager: appState.preferencesManager, viewerDID: appState.userDID,
            isActiveViewer: !appState.isAccountSwitchSuspended) else { return }
    appState.trendingTopicMediaStore.invalidate(labelers: appState.topicPreviewLabelers)
  }

  // MARK: Traits

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard let previousTraitCollection, let configuration else { return }
    if previousTraitCollection.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
      || previousTraitCollection.legibilityWeight != traitCollection.legibilityWeight
      || previousTraitCollection.displayScale != traitCollection.displayScale {
      typography = TrendingInterstitialTypography.resolved(
        fontManager: configuration.appState.fontManager, traits: traitCollection)
      appliedLayout = nil
      setNeedsLayout()
      invalidateIntrinsicContentSize()
    }
  }
}
#endif
