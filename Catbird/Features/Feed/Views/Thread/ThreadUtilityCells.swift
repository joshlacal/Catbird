#if os(iOS)
import UIKit

// MARK: - Utility Cell Types
@available(iOS 18.0, *)
final class LoadMoreCell: UICollectionViewCell {
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private var isCurrentlyLoading = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    // Background color will be set when we have access to appState
    
    // Make the entire cell invisible to VoiceOver
    isAccessibilityElement = false
    contentView.isAccessibilityElement = false
    contentView.accessibilityElementsHidden = true
    
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.isAccessibilityElement = false
    
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Loading more parents..."
      label.font = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.subheadline)
    label.textColor = UIColor.systemGray
    label.isAccessibilityElement = false
    
    let stackView = UIStackView(arrangedSubviews: [activityIndicator, label])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    stackView.isAccessibilityElement = false
    
    contentView.addSubview(stackView)
    
    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
    ])
  }

  func configure(isLoading: Bool) {
    // Only update if the state is changing to avoid unnecessary UI updates
    guard isLoading != isCurrentlyLoading else { return }

    isCurrentlyLoading = isLoading

    if isLoading {
      activityIndicator.startAnimating()
      label.isHidden = false
      label.text = "Loading more parents..."
      label.alpha = 1.0
    } else {
      activityIndicator.stopAnimating()
      label.isHidden = true
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityIndicator.stopAnimating()
  }
}

// MARK: - Show More Replies Cell
@available(iOS 18.0, *)
final class ShowMoreRepliesCell: UICollectionViewCell {
  private let button = UIButton(type: .system)
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private var tapAction: (() -> Void)?
  private var isCurrentlyLoading = false
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    
    // Disable implicit layer animations
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupViews() {
    // Configure button
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setTitle("Show More Replies", for: .normal)
    // Apply medium weight to the preferred subheadline font without using non-existent withWeight API
      let baseFont = UIFont.preferredFont(forTextStyle: UIFont.TextStyle.subheadline)
    let descriptor = baseFont.fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]])
    button.titleLabel?.font = UIFont(descriptor: descriptor, size: 0)
    button.setTitleColor(.systemBlue, for: .normal)
    button.addTarget(self, action: #selector(buttonTapped), for: .touchUpInside)
    
    // Configure activity indicator
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    activityIndicator.hidesWhenStopped = true
    
    // Container stack
    let stackView = UIStackView(arrangedSubviews: [button, activityIndicator])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    
    contentView.addSubview(stackView)
    
    NSLayoutConstraint.activate([
      stackView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
    ])
    
    // Accessibility
    isAccessibilityElement = true
    accessibilityLabel = "Show more replies"
    accessibilityTraits = .button
  }
  
  func configure(isLoading: Bool, onTap: @escaping () -> Void) {
    tapAction = onTap
    
    guard isLoading != isCurrentlyLoading else { return }
    isCurrentlyLoading = isLoading
    
    if isLoading {
      button.isEnabled = false
      button.setTitle("Loading...", for: .normal)
      activityIndicator.startAnimating()
    } else {
      button.isEnabled = true
      button.setTitle("Show More Replies", for: .normal)
      activityIndicator.stopAnimating()
    }
  }
  
  @objc private func buttonTapped() {
    tapAction?()
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    tapAction = nil
    isCurrentlyLoading = false
    button.isEnabled = true
    button.setTitle("Show More Replies", for: .normal)
    activityIndicator.stopAnimating()
  }
}

@available(iOS 18.0, *)
final class SpacerCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    // This cell doesn't need special background handling
    // Disable implicit layer animations on this cell
    let noAnim: [String: CAAction] = [
      "bounds": NSNull(),
      "position": NSNull(),
      "frame": NSNull(),
      "contents": NSNull(),
      "onOrderIn": NSNull(),
      "onOrderOut": NSNull()
    ]
    layer.actions = noAnim
    contentView.layer.actions = noAnim
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
#endif
