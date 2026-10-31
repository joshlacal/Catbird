#if os(iOS)
import Nuke
import UIKit

// MARK: - Feed Post Avatar View

/// The circular author avatar of a native feed row. Callers pass `url: nil` for authors whose
/// avatar moderation conceals, so a concealed avatar is never requested.
///
/// A resized avatar already in Nuke's memory cache is painted by `configure` itself, so the
/// first frame is the final image. Otherwise the request completes later, and the request token
/// drops any result that no longer belongs to the post this view shows.
final class FeedPostAvatarView: UIView {
  private let imageView = UIImageView()
  private let placeholderGlyph = UIImageView(image: UIImage(systemName: "person.crop.circle"))
  private var task: ImageTask?
  private(set) var currentRequestToken = 0
  var onTap: (() -> Void)?

  /// The loaded avatar; `nil` while loading, after a failed load, and for authors without one.
  var displayedImage: UIImage? { imageView.image }
  var isShowingPlaceholderGlyph: Bool { !placeholderGlyph.isHidden }

  private static let loadingBackground = UIColor.systemGray.withAlphaComponent(0.2)

  override init(frame: CGRect) {
    super.init(frame: frame)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.backgroundColor = Self.loadingBackground
    placeholderGlyph.contentMode = .scaleAspectFit
    placeholderGlyph.tintColor = .systemGray
    placeholderGlyph.isHidden = true
    addSubview(imageView)
    addSubview(placeholderGlyph)
    isAccessibilityElement = true
    accessibilityTraits = .button
    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    imageView.layer.cornerRadius = bounds.width / 2
    placeholderGlyph.frame = bounds
  }

  // MARK: - Loading

  func configure(url: URL?, pointSize: CGFloat, scale: CGFloat, accessibilityName: String) {
    accessibilityLabel = "\(accessibilityName), view profile"
    resetImage()
    let token = currentRequestToken
    guard let request = ImageRequestFactory.avatar(url, pointSize: pointSize, scale: scale) else {
      imageView.backgroundColor = .clear
      placeholderGlyph.isHidden = false
      return
    }
    let pipeline = ImageLoadingManager.shared.pipeline
    if let cached = pipeline.cache[request]?.image {
      imageView.image = cached
      return
    }
    task = pipeline.loadImage(with: request) { [weak self] result in
      guard case .success(let response) = result else { return }
      self?.deliver(response.image, forToken: token)
    }
  }

  /// Applies an image only if it belongs to the post this view currently shows.
  func deliver(_ image: UIImage, forToken token: Int) {
    guard token == currentRequestToken else { return }
    imageView.image = image
  }

  func prepareForReuse() {
    resetImage()
    onTap = nil
  }

  /// Cancels the in-flight request, invalidates its token and returns to the loading state.
  private func resetImage() {
    task?.cancel()
    task = nil
    currentRequestToken &+= 1
    imageView.image = nil
    imageView.backgroundColor = Self.loadingBackground
    placeholderGlyph.isHidden = true
  }

  // MARK: - Interaction

  @objc private func tapped() { onTap?() }

  override func accessibilityActivate() -> Bool {
    guard let onTap else { return false }
    onTap()
    return true
  }
}
#endif
