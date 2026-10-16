#if os(iOS)
import OSLog
import Petrel
import Synchronization
import UIKit

private let nativeRowLogger = Logger(subsystem: "blue.catbird", category: "NativeFeedRow")

// MARK: - Native Feed Post Cell

/// A feed post drawn in UIKit. Every subview sits at a frame from the row's precomputed
/// `FeedRowLayout`; the cell never measures its content, and its self-sizing height is the
/// layout's height.
///
/// Taps: the avatar opens the profile, a link run opens the link, the action bar and the options
/// button handle their own taps, and a tap anywhere else opens the post. For VoiceOver the content
/// view keeps the hosted row's `post.<uri>` identifier, and the content view, the post text and
/// the author's name offer an "Open post" action. The post text is identified
/// `textAccessibilityIdentifier`, which tells UI tests a native row from a hosted one.
///
/// When the cell is sized to a width its layout was not computed for, it logs a fault and asks
/// the controller for a new layout through `NativeFeedRowActions.layoutWidthChanged`; until then it
/// keeps drawing the old layout.
final class NativeFeedPostCell: UICollectionViewListCell, UIGestureRecognizerDelegate {
  private let avatarView = FeedPostAvatarView()
  private let headerView = FeedPostHeaderLineView()
  private let textView = FeedPostTextView()
  private let actionBar = FeedActionBarView.dequeueReusable()
  private let optionsButton = PostOptionsMenuButtonView.dequeueReusable()
  private let optionsGlyph = UIImageView(image: UIImage(systemName: "ellipsis"))
  private let divider = UIView()
  private lazy var rowTap = UITapGestureRecognizer(target: self, action: #selector(openPost))
  private let shadowObservation = ShadowObservation()
  private var layout: FeedRowLayout?
  private var post: AppBskyFeedDefs.PostView?
  private var actions: NativeFeedRowActions?
  private var barState: FeedActionBarState?
  /// The post's counts measured ahead of display, kept for live count updates that leave a count
  /// unchanged.
  private var barCounts: FeedActionBarCounts?
  /// The options button's own height (`UIButton`'s intrinsic height); it does not change.
  private lazy var optionsButtonIntrinsicHeight = optionsButton.intrinsicContentSize.height
  /// The last width reported through `layoutWidthChanged` for the current configuration.
  private var reportedMismatchWidth: CGFloat?

  /// The post text's accessibility identifier; only native rows have it.
  static let textAccessibilityIdentifier = "feedRow.native.text"

  var postURI: String? { post?.uri.uriString() }
  var textViewForTesting: FeedPostTextView { textView }
  var avatarViewForTesting: FeedPostAvatarView { avatarView }
  var headerViewForTesting: FeedPostHeaderLineView { headerView }
  var actionBarForTesting: FeedActionBarView { actionBar }
  var optionsButtonForTesting: PostOptionsMenuButtonView { optionsButton }
  var dividerForTesting: UIView { divider }
  var hasOptionsMenuForTesting: Bool { optionsButton.makeItems != nil }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundConfiguration = .clear()
    for view in [avatarView, headerView, textView, actionBar, optionsGlyph, optionsButton, divider] as [UIView] {
      contentView.addSubview(view)
    }
    optionsGlyph.contentMode = .center
    textView.accessibilityIdentifier = Self.textAccessibilityIdentifier
    // The hosted row draws the glyph in the environment's font, the system body style.
    optionsGlyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
    optionsGlyph.tintColor = .secondaryLabel
    optionsGlyph.isAccessibilityElement = false
    optionsButton.accessibilityLabel = "Post Options"
    // The header spans the content view and positions its labels by the layout's frames;
    // it must not take touches meant for the avatar, text links or the row.
    headerView.isUserInteractionEnabled = false
    divider.backgroundColor = .separator
    rowTap.delegate = self
    contentView.addGestureRecognizer(rowTap)
    // Offered on the elements VoiceOver focuses (the text and the author's name) as well as on
    // the content view, which is a container and not itself an element.
    let openPostAction = UIAccessibilityCustomAction(name: "Open post") { [weak self] _ in
      self?.performOpenPost() ?? false
    }
    contentView.accessibilityCustomActions = [openPostAction]
    textView.rowAccessibilityActions = [openPostAction]
    headerView.nameAccessibilityActions = [openPostAction]
    // VoiceOver reads the row in the hosted row's order: the avatar, the header line, the options
    // button that ends it, the text, then the action bar.
    contentView.accessibilityElements = [avatarView, headerView, optionsButton, textView, actionBar]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  // MARK: - Configuration

  func configure(
    _ content: NativeFeedRowContent, typography: FeedRowTypography, actions: NativeFeedRowActions,
    shadowUpdates: @escaping @Sendable (String) async -> AsyncStream<AppBskyFeedDefs.PostView>
  ) {
    layout = content.layout
    post = content.post
    self.actions = actions
    reportedMismatchWidth = nil
    contentView.accessibilityIdentifier = "post.\(content.post.uri.uriString())"

    // Native rows only show posts whose avatar moderation does not conceal
    // (`NativeFeedRowSupport.classify`), so the author's avatar may be requested.
    avatarView.configure(
      url: content.avatarURL, pointSize: FeedRowMetrics.avatarSize,
      scale: traitCollection.displayScale, accessibilityName: Self.avatarAccessibilityName(for: content.post.author))
    let did = content.post.author.did.didString()
    avatarView.onTap = { actions.openProfile(did) }
    // `content.verification` already reflects the "hide verification badges" preference.
    headerView.configure(
      content.layout, displayName: content.displayName, handle: content.handle, timeText: content.timeText,
      timeAccessibilityLabel: content.timeAccessibilityLabel, verification: content.verification,
      typography: typography, metadataColor: content.metadataColor, originX: 0, hideVerificationBadges: false)
    optionsGlyph.tintColor = content.metadataColor
    textView.attributedText = content.text
    textView.linePlacement = typography.bodyLine
    textView.onOpenLink = actions.openLink
    actionBar.actions = actions.actionBar(content.post)
    barState = content.actionBarState
    barCounts = content.actionBarCounts
    actionBar.apply(content.actionBarState, counts: content.actionBarCounts)
    let menuPost = content.post
    optionsButton.makeItems = { actions.optionsMenu(menuPost) }

    // Live like/repost counts, as ActionButtonsView's shadow loop does; never relayouts the row.
    let uri = content.post.uri.uriString()
    shadowObservation.replace(with: Task { [weak self] in
      for await merged in await shadowUpdates(uri) {
        guard !Task.isCancelled, let self, self.postURI == uri, var state = self.barState else { return }
        state.likeCount = merged.likeCount ?? 0
        state.isLiked = merged.viewer?.like != nil
        state.repostCount = merged.repostCount ?? 0
        state.isReposted = merged.viewer?.repost != nil
        state.replyCount = merged.replyCount ?? 0
        self.barState = state
        self.actionBar.apply(state, counts: self.barCounts)
      }
    })
    setNeedsLayout()
  }

  /// The next `configure` replaces everything the previous post showed; the text in particular
  /// is not cleared here, since `configure` always sets it. A cell that is not configured after
  /// reuse is cleared with `clearContent()`.
  override func prepareForReuse() {
    super.prepareForReuse()
    shadowObservation.replace(with: nil)
    avatarView.prepareForReuse()
    textView.onOpenLink = nil
    actionBar.actions = nil
    optionsButton.makeItems = nil
    contentView.accessibilityIdentifier = nil
    post = nil
    layout = nil
    actions = nil
    barState = nil
    barCounts = nil
    reportedMismatchWidth = nil
  }

  /// Removes the previous post's text from a reused cell that cannot be configured, so it never
  /// shows a post it no longer belongs to.
  func clearContent() {
    textView.attributedText = nil
  }

  /// The name VoiceOver reads for the avatar, as `AuthorAvatarColumn` builds it: the display
  /// name, or "@handle" when there is none.
  private static func avatarAccessibilityName(for author: AppBskyActorDefs.ProfileViewBasic) -> String {
    if let displayName = author.displayName, !displayName.isEmpty { return displayName }
    return "@\(author.handle.description)"
  }

  // MARK: - Layout

  override func preferredLayoutAttributesFitting(
    _ layoutAttributes: UICollectionViewLayoutAttributes
  ) -> UICollectionViewLayoutAttributes {
    guard let layout else { return super.preferredLayoutAttributesFitting(layoutAttributes) }
    // A width the layout was not computed for is reported; the height stays the layout's until
    // the controller reconfigures the item with a layout for the new width.
    checkLayoutWidth(layoutAttributes.size.width)
    let attributes = layoutAttributes
    attributes.size.height = layout.height
    return attributes
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let layout else { return }
    avatarView.frame = layout.avatarFrame
    headerView.frame = contentView.bounds
    textView.frame = layout.textFrame
    actionBar.frame = layout.actionBarFrame
    optionsGlyph.frame = layout.optionsButtonFrame
    // The hosted row overlays the padded glyph with this button, which SwiftUI sizes to the glyph's
    // width and the button's intrinsic height: the touch area reaches a few points above and below.
    let glyph = layout.optionsButtonFrame
    let buttonHeight = max(glyph.height, optionsButtonIntrinsicHeight)
    optionsButton.frame = glyph.insetBy(dx: 0, dy: (glyph.height - buttonHeight) / 2)
    divider.frame = layout.dividerFrame
    checkLayoutWidth(contentView.bounds.width)
  }

  /// Reports, once per width and configuration, that the cell is sized to a width its layout was
  /// not computed for: its frames would run past a narrower cell or leave a wider one partly
  /// empty. Zero widths (a cell not sized yet) are ignored.
  private func checkLayoutWidth(_ width: CGFloat) {
    guard let layout, let post, let actions, width > 0 else { return }
    let tolerance = 1 / max(traitCollection.displayScale, 1)
    guard abs(width - layout.width) > tolerance, reportedMismatchWidth != width else { return }
    reportedMismatchWidth = width
    nativeRowLogger.fault(
      "Native feed row sized to \(Double(width), privacy: .public) pt with a layout for \(Double(layout.width), privacy: .public) pt")
    actions.layoutWidthChanged(post, width)
  }

  // MARK: - Opening the Post

  /// Whether a tap at `point` (content view coordinates) opens the post. Taps on the avatar,
  /// on any control (action bar buttons, the options button) and on a link belong to them.
  func tapOpensPost(at point: CGPoint) -> Bool {
    guard let hit = contentView.hitTest(point, with: nil) else { return false }
    if hit.isDescendant(of: avatarView) { return false }
    var view: UIView? = hit
    while let current = view, current !== contentView {
      if current is UIControl { return false }
      view = current.superview
    }
    if hit.isDescendant(of: textView) {
      return textView.link(at: contentView.convert(point, to: textView)) == nil
    }
    return true
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === rowTap else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
    return tapOpensPost(at: gestureRecognizer.location(in: contentView))
  }

  @objc private func openPost() {
    _ = performOpenPost()
  }

  private func performOpenPost() -> Bool {
    guard let post, let actions else { return false }
    actions.openPost(post)
    return true
  }
}

// MARK: - Shadow Observation

/// Owns the task that applies a post's live counts. A separate `Sendable` object so the task is
/// also cancelled when the cell is deallocated: the cell's own `deinit` is not isolated to the
/// main actor and cannot read the cell's state.
private final class ShadowObservation: Sendable {
  private let task = Mutex<Task<Void, Never>?>(nil)

  /// Cancels the current task and keeps `new` in its place.
  func replace(with new: Task<Void, Never>?) {
    task.withLock { current in
      current?.cancel()
      current = new
    }
  }

  deinit {
    task.withLock { $0?.cancel() }
  }
}
#endif
