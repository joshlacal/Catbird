//
//  PostListPinnedHeaderView.swift
//  Catbird
//
//  The view holding a post list's pinned header (the profile tab picker), and what goes
//  behind it while it is pinned, when rows scroll underneath it.
//

#if os(iOS)
import UIKit

/// Holds a post list's pinned header. While the header is pinned, rows scroll behind it:
/// - On iOS 26 and later the scroll view's soft top edge effect goes behind it, carried down by
///   a `UIScrollEdgeElementContainerInteraction`. The interaction is attached only while pinned:
///   it carries the effect down to the header wherever the header is, so at rest it would blur
///   everything above it. The soft effect fades out across the header, so translucent controls
///   in it need their own backing (the profile backs its picker's track).
/// - Earlier systems have no edge effect, and the profile hides its navigation bar background,
///   so the header draws a bar material from the top of the screen to its own bottom, with a
///   hairline: a navigation bar with the header as its extension.
final class PostListPinnedHeaderView: UICollectionViewListCell {
  private var isPinned = false
  private var barHeight: CGFloat = 0
  private var backdrop: UIVisualEffectView?
  private var hairline: UIView?

  /// - Parameters:
  ///   - barHeight: how far below the top of the scroll view the header pins.
  func update(isPinned: Bool, barHeight: CGFloat, scrollView: UIScrollView) {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      updateEdgeElementContainer(isPinned: isPinned, scrollView: scrollView)
      return
    }
    #endif
    updateBackdrop(isPinned: isPinned, barHeight: barHeight)
  }

  #if compiler(>=6.2)
  @available(iOS 26.0, *)
  private func updateEdgeElementContainer(isPinned: Bool, scrollView: UIScrollView) {
    let existing = interactions.filter { $0 is UIScrollEdgeElementContainerInteraction }
    if isPinned, existing.isEmpty {
      let interaction = UIScrollEdgeElementContainerInteraction()
      interaction.scrollView = scrollView
      interaction.edge = .top
      addInteraction(interaction)
    } else if !isPinned {
      existing.forEach(removeInteraction)
    }
  }
  #endif

  private func updateBackdrop(isPinned: Bool, barHeight: CGFloat) {
    if barHeight != self.barHeight {
      self.barHeight = barHeight
      setNeedsLayout()
    }
    guard isPinned != self.isPinned || backdrop == nil else { return }
    self.isPinned = isPinned
    let backdrop = self.backdrop ?? makeBackdrop()
    UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      backdrop.alpha = isPinned ? 1 : 0
    }
  }

  private func makeBackdrop() -> UIVisualEffectView {
    // The material navigation bars use, which turns opaque with Reduce Transparency.
    let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
    backdrop.isUserInteractionEnabled = false
    backdrop.alpha = 0
    let hairline = UIView()
    hairline.backgroundColor = .separator
    backdrop.contentView.addSubview(hairline)
    insertSubview(backdrop, at: 0)
    self.backdrop = backdrop
    self.hairline = hairline
    setNeedsLayout()
    return backdrop
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let backdrop, let hairline else { return }
    // Up to the top of the screen, over the bars, which draw no background of their own here.
    backdrop.frame = CGRect(x: 0, y: -barHeight, width: bounds.width, height: bounds.height + barHeight)
    let thickness = 1 / max(1, traitCollection.displayScale)
    hairline.frame = CGRect(x: 0, y: backdrop.bounds.height - thickness, width: bounds.width, height: thickness)
    sendSubviewToBack(backdrop)
  }
}
#endif
