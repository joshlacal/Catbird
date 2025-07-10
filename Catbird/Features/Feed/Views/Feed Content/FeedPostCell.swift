//
//  FeedPostCell.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/4/25.
//

import SwiftUI
import UIKit
import Petrel

// MARK: - Collection View Cells

@available(iOS 18.0, *)
final class FeedPostCell: UICollectionViewCell {
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupCell()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupCell() {
    // Configure cell appearance
    backgroundColor = .clear

    // Configure for better performance
    layer.shouldRasterize = false
    isOpaque = false
  }

  func configure(cachedPost: CachedFeedViewPost, appState: AppState, path: Binding<NavigationPath>)
  {
    // Set themed background color
    let currentScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
    let effectiveScheme = appState.themeManager.effectiveColorScheme(for: currentScheme)
    contentView.backgroundColor = UIColor(
      Color.dynamicBackground(appState.themeManager, currentScheme: effectiveScheme))

    // Always use enhanced feed post view for consistent rendering in feeds with divider
    let content = AnyView(
      VStack(spacing: 0) {
        EnhancedFeedPost(
          cachedPost: cachedPost,
          path: path
        )
        .environment(appState)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)

        // Add full-width divider at bottom of each post
        Divider()
          .padding(.top, 3)
      }
    )

    // Only reconfigure if needed (using post id as identity check)
    let postIdentifier = cachedPost.id
    if contentConfiguration == nil
      || postIdentifier != (contentView.tag != 0 ? String(contentView.tag) : nil)
    {

      // Store post ID in tag for comparison on reuse
      contentView.tag = postIdentifier.hashValue

      // Configure with SwiftUI content
      contentConfiguration = UIHostingConfiguration {
        content
      }
      .margins(.all, .zero)
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Clean up resources when cell is reused
    contentConfiguration = nil
    contentView.tag = 0
  }
}


@available(iOS 18.0, *)
final class LoadMoreIndicatorCell: UICollectionViewCell {
  private let activityIndicator = UIActivityIndicatorView(style: .medium)
  private let label = UILabel()
  private var isCurrentlyLoading = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupViews() {
    backgroundColor = .clear

    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "Load more posts"
    label.font = UIFont.preferredFont(forTextStyle: .subheadline)
    label.textColor = UIColor.white
    label.textAlignment = .center

    let stackView = UIStackView(arrangedSubviews: [activityIndicator, label])
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.spacing = 8
    stackView.alignment = .center
    stackView.layoutMargins = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
    stackView.isLayoutMarginsRelativeArrangement = true
    
    // Create blue rounded background
    let backgroundView = UIView()
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.backgroundColor = UIColor.systemBlue
    backgroundView.layer.cornerRadius = 24
    backgroundView.layer.shadowColor = UIColor.black.cgColor
    backgroundView.layer.shadowOpacity = 0.1
    backgroundView.layer.shadowOffset = CGSize(width: 0, height: 2)
    backgroundView.layer.shadowRadius = 4

    contentView.addSubview(backgroundView)
    backgroundView.addSubview(stackView)

    NSLayoutConstraint.activate([
      backgroundView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      backgroundView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      backgroundView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
      backgroundView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
      backgroundView.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),
      backgroundView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
      
      stackView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
      stackView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
      stackView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
    ])

    // Make it tappable
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
    addGestureRecognizer(tapGesture)
  }

  @objc private func cellTapped() {
    // Trigger load more action through delegate pattern
    // This will be handled by the collection view's didSelectItem
  }

  func configure(isLoading: Bool) {
    // Only update if the state is changing to avoid unnecessary UI updates
    guard isLoading != isCurrentlyLoading else { return }

    isCurrentlyLoading = isLoading

    if isLoading {
      activityIndicator.startAnimating()
      label.text = "Loading more..."
      label.textColor = UIColor.white.withAlphaComponent(0.8)
    } else {
      activityIndicator.stopAnimating()
      label.text = "Load more posts"
      label.textColor = UIColor.white
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    activityIndicator.stopAnimating()
    isCurrentlyLoading = false
  }
}

@available(iOS 18.0, *)
final class FeedGapCell: UICollectionViewCell {
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let loadButton = UIButton(type: .system)
  private var gapId: String?
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  private func setupViews() {
    backgroundColor = .clear
    
    // Configure icon
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = UIImage(systemName: "clock.arrow.circlepath")
    iconView.tintColor = UIColor.systemBlue
    iconView.contentMode = .scaleAspectFit
    
    // Configure title
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "Some posts may be missing"
    titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    titleLabel.textColor = UIColor.label
    titleLabel.textAlignment = .left
    
    // Configure subtitle
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.text = "Tap to load missing content"
    subtitleLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
    subtitleLabel.textColor = UIColor.secondaryLabel
    subtitleLabel.textAlignment = .left
    
    // Configure load button
    loadButton.translatesAutoresizingMaskIntoConstraints = false
    loadButton.setTitle("Load", for: .normal)
    loadButton.setTitleColor(.white, for: .normal)
    loadButton.backgroundColor = UIColor.systemBlue
    loadButton.layer.cornerRadius = 16
    loadButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .subheadline)
    loadButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
    
    // Create text stack
    let textStack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.alignment = .leading
    
    // Create main horizontal stack
    let mainStack = UIStackView(arrangedSubviews: [iconView, textStack, loadButton])
    mainStack.translatesAutoresizingMaskIntoConstraints = false
    mainStack.axis = .horizontal
    mainStack.spacing = 12
    mainStack.alignment = .center
    
    // Add dividers
    let topDivider = UIView()
    topDivider.translatesAutoresizingMaskIntoConstraints = false
    topDivider.backgroundColor = UIColor.separator
    
    let bottomDivider = UIView()
    bottomDivider.translatesAutoresizingMaskIntoConstraints = false
    bottomDivider.backgroundColor = UIColor.separator
    
    contentView.addSubview(topDivider)
    contentView.addSubview(mainStack)
    contentView.addSubview(bottomDivider)
    
    NSLayoutConstraint.activate([
      // Top divider
      topDivider.topAnchor.constraint(equalTo: contentView.topAnchor),
      topDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      topDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      topDivider.heightAnchor.constraint(equalToConstant: 0.5),
      
      // Main stack
      mainStack.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 16),
      mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
      mainStack.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -16),
      
      // Bottom divider
      bottomDivider.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      bottomDivider.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      bottomDivider.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),
      
      // Icon size
      iconView.widthAnchor.constraint(equalToConstant: 20),
      iconView.heightAnchor.constraint(equalToConstant: 20),
      
      // Button minimum width
      loadButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
      loadButton.heightAnchor.constraint(equalToConstant: 32)
    ])
    
    // Make the entire cell tappable
    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(cellTapped))
    addGestureRecognizer(tapGesture)
  }
  
  @objc private func cellTapped() {
    // This will be handled by the collection view's didSelectItem
  }
  
  func configure(gapId: String) {
    self.gapId = gapId
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    gapId = nil
  }
}

