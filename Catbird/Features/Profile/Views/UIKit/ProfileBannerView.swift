import UIKit
import Nuke
import os

/// Pinned banner UIView — sits behind the scroll view, never scrolls.
/// Supports pull-down stretch via CATransform3DScale and progressive blur overlay.
@available(iOS 18.0, *)
final class ProfileBannerView: UIView {

  // MARK: - Constants
  private let baseBannerHeight: CGFloat = 160

  // MARK: - Layers / Views
  private var defaultGradientLayer: CAGradientLayer!
  private var bannerImageLayer: CALayer!
  private var readabilityGradientLayer: CAGradientLayer!
  private var blurEffectView: UIVisualEffectView!

  // MARK: - State
  private var imageLoadTask: Task<Void, Never>?
  private let bannerLogger = Logger(subsystem: "blue.catbird", category: "ProfileBannerView")

  // MARK: - Init
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupViews()
  }

  deinit {
    imageLoadTask?.cancel()
  }

  // MARK: - Setup
  private func setupViews() {
    clipsToBounds = false // allow layer to stretch beyond bottom during pull-down

    // Fallback gradient (shown when no banner image)
    defaultGradientLayer = CAGradientLayer()
    defaultGradientLayer.colors = [UIColor.systemBlue.cgColor, UIColor.systemIndigo.cgColor]
    defaultGradientLayer.startPoint = CGPoint(x: 0, y: 0)
    defaultGradientLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.addSublayer(defaultGradientLayer)

    // Banner image layer — anchorPoint at top-center for top-anchored stretching
    bannerImageLayer = CALayer()
    bannerImageLayer.contentsGravity = .resizeAspectFill
    bannerImageLayer.masksToBounds = true
    bannerImageLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
    layer.addSublayer(bannerImageLayer)

    // Readability gradient: transparent top → subtle dark bottom
    readabilityGradientLayer = CAGradientLayer()
    readabilityGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0).cgColor,
      UIColor.black.withAlphaComponent(0.25).cgColor
    ]
    readabilityGradientLayer.locations = [0.5, 1.0]
    layer.addSublayer(readabilityGradientLayer)

    // Blur overlay — alpha-driven, driven by scroll
    let blurEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
    blurEffectView = UIVisualEffectView(effect: blurEffect)
    blurEffectView.alpha = 0
    blurEffectView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blurEffectView)

    NSLayoutConstraint.activate([
      blurEffectView.topAnchor.constraint(equalTo: topAnchor),
      blurEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurEffectView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  // MARK: - Layout
  override func layoutSubviews() {
    super.layoutSubviews()
    let b = bounds
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defaultGradientLayer.frame = b
    // bannerImageLayer: anchorPoint (0.5, 0) so position = top-center
    bannerImageLayer.bounds = b
    bannerImageLayer.position = CGPoint(x: b.midX, y: 0)
    readabilityGradientLayer.frame = b
    CATransaction.commit()
  }

  // MARK: - Configuration
  func configure(bannerURL: URL?, accentColor: UIColor) {
    defaultGradientLayer.colors = [accentColor.cgColor, accentColor.withAlphaComponent(0.5).cgColor]

    imageLoadTask?.cancel()
    bannerImageLayer.contents = nil

    guard let url = bannerURL else { return }
    imageLoadTask = Task { [weak self] in
      await self?.loadBannerImage(from: url)
    }
  }

  // MARK: - Image Loading
  private func loadBannerImage(from url: URL) async {
    do {
      let request = ImageRequest(url: url)
      let image = try await ImagePipeline.shared.image(for: request)
      guard !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        self.bannerImageLayer.contents = image.cgImage
        CATransaction.commit()
      }
    } catch {
      guard !Task.isCancelled else { return }
      bannerLogger.error("Banner load failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Scroll-Driven Update
  /// Called every frame from the scroll delegate.
  func update(scrollOffset: CGFloat) {
    let overscroll = max(0, -scrollOffset)

    CATransaction.begin()
    CATransaction.setDisableActions(true)

    if overscroll > 0 {
      // Pull-down: stretch banner from top anchor
      let scale = 1.0 + (overscroll / baseBannerHeight)
      let scaleTransform = CATransform3DMakeScale(scale, scale, 1)
      bannerImageLayer.transform = scaleTransform
      defaultGradientLayer.transform = scaleTransform
      // Progressive blur: 0 → 0.6 over first 80pt of overscroll
      blurEffectView.alpha = min(overscroll / 80.0, 0.6)
    } else {
      bannerImageLayer.transform = CATransform3DIdentity
      defaultGradientLayer.transform = CATransform3DIdentity
      blurEffectView.alpha = 0
    }

    CATransaction.commit()
  }
}
