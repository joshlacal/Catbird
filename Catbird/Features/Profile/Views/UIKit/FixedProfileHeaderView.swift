import UIKit
import SwiftUI
import Petrel
import Nuke
import os

// MARK: - Fixed Profile Header View
@available(iOS 18.0, *)
final class FixedProfileHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "FixedProfileHeaderView"
  
  private let headerLogger = Logger(subsystem: "blue.catbird", category: "FixedProfileHeaderView")
  
  private var bannerImageView: UIImageView!
  private var avatarImageView: UIImageView!
  private var followButtonContainer: UIView!
  private var gradientLayer: CAGradientLayer!
  private var currentProfile: AppBskyActorDefs.ProfileViewDetailed?
  
  // Store original dimensions
  private let originalHeight: CGFloat = 200
  
  // Constraints we'll modify
  private var bannerTopConstraint: NSLayoutConstraint!
  
  // Image loading tasks
  private var bannerLoadTask: Task<Void, Never>?
  private var avatarLoadTask: Task<Void, Never>?
  
  // UI State
  private var appState: AppState?
  private var viewModel: ProfileViewModel?
  
  // Performance tracking
  private var lastConfigurationDID: String?
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }
  
  required init?(coder: NSCoder) {
    headerLogger.error("FixedProfileHeaderView: Coder initialization not supported")
    return nil
  }
  
  deinit {
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    headerLogger.debug("FixedProfileHeaderView deallocated")
  }
  
  private func setupViews() {
    clipsToBounds = false // Allow elements to extend beyond bounds
    backgroundColor = .clear
    
    // Banner image view
    bannerImageView = UIImageView()
    bannerImageView.contentMode = .scaleAspectFill
    bannerImageView.clipsToBounds = true
    bannerImageView.backgroundColor = .systemGray6
    bannerImageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bannerImageView)
    
    // Add subtle gradient overlay for visual depth
    gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.1).cgColor
    ]
    gradientLayer.locations = [0.7, 1.0]
    bannerImageView.layer.addSublayer(gradientLayer)
    
    // Avatar image view - leading aligned
    avatarImageView = UIImageView()
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true
    avatarImageView.backgroundColor = .systemGray6
    avatarImageView.layer.cornerRadius = 40 // 80x80 = 40 radius
    avatarImageView.layer.borderWidth = 4
    avatarImageView.layer.borderColor = UIColor.systemBackground.cgColor
    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatarImageView)
    
    // Follow button container - trailing aligned
    followButtonContainer = UIView()
    followButtonContainer.translatesAutoresizingMaskIntoConstraints = false
    addSubview(followButtonContainer)
    
    setupConstraints()
  }
  
  private func setupConstraints() {
    // Banner - pin to top (will move for stretch effect)
    bannerTopConstraint = bannerImageView.topAnchor.constraint(equalTo: topAnchor)
    
    NSLayoutConstraint.activate([
      // Banner fills width and has fixed height from top
      bannerTopConstraint,
      bannerImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      bannerImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bannerImageView.heightAnchor.constraint(equalToConstant: originalHeight),
      
      // Avatar - leading aligned, overlapping banner
      avatarImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      avatarImageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40), // Half overlapping
      avatarImageView.widthAnchor.constraint(equalToConstant: 80),
      avatarImageView.heightAnchor.constraint(equalToConstant: 80),
      
      // Follow button container - trailing aligned to same level as avatar
      followButtonContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      followButtonContainer.centerYAnchor.constraint(equalTo: avatarImageView.centerYAnchor),
      followButtonContainer.heightAnchor.constraint(equalToConstant: 36), // Standard button height
      followButtonContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 80)
    ])
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Update gradient frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientLayer.frame = bannerImageView.bounds
    CATransaction.commit()
  }
  
  @MainActor
  func updateForStretch(stretchAmount: CGFloat) {
    // Only stretch when pulling down (positive stretch)
    guard stretchAmount > 0 else {
      resetStretch()
      return
    }
    
    // Don't clamp - let it stretch naturally
    // The layout is already handling frame positioning, we just need to scale the image
    
    // Keep banner top pinned since layout handles frame positioning
    bannerTopConstraint.constant = 0
    
    // More natural scale effect - less aggressive but more responsive
    let scale = 1 + (stretchAmount / originalHeight) * 0.3
    bannerImageView.transform = CGAffineTransform(scaleX: scale, y: scale)
    
    if stretchAmount > 10 {
      headerLogger.debug("Stretch: amount=\(stretchAmount, privacy: .public), scale=\(scale, privacy: .public)")
    }
  }
  
  @MainActor
  func resetStretch() {
    bannerTopConstraint.constant = 0
    bannerImageView.transform = .identity
  }
  
  func configure(profile: AppBskyActorDefs.ProfileViewDetailed, appState: AppState, viewModel: ProfileViewModel) {
    self.appState = appState
    self.viewModel = viewModel
    let profileDID = profile.did.didString()
    
    // Prevent duplicate configuration - major performance fix
    guard lastConfigurationDID != profileDID else { 
      headerLogger.debug("Skipping duplicate configuration for DID: \(profileDID, privacy: .public)")
      return 
    }
    
    self.lastConfigurationDID = profileDID
    self.currentProfile = profile
    
    headerLogger.debug("Configuring header for profile: \(profile.handle, privacy: .public)")
    
    // Cancel previous load tasks
    bannerLoadTask?.cancel()
    
    // Load banner
    if let bannerURL = profile.banner?.uriString(), 
       let url = URL(string: bannerURL) {
      bannerLoadTask = Task {
        await loadImage(from: url, into: bannerImageView, type: "banner")
      }
    } else {
      // Default gradient background
      bannerImageView.image = nil
      setDefaultBannerGradient()
    }
    
    // Load avatar
    if let avatarURL = profile.avatar?.uriString(),
       let url = URL(string: avatarURL) {
      avatarLoadTask = Task {
        await loadImage(from: url, into: avatarImageView, type: "avatar")
      }
    } else {
      // Default avatar
      avatarImageView.image = nil
      avatarImageView.backgroundColor = .systemGray6
    }
    
    // Setup follow button
    setupFollowButton(for: profile)
  }
  
  private func setDefaultBannerGradient() {
    let gradientView = UIView()
    gradientView.translatesAutoresizingMaskIntoConstraints = false
    
    let gradient = CAGradientLayer()
    gradient.colors = [
      UIColor.systemBlue.cgColor,
      UIColor.systemPurple.cgColor
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    
    bannerImageView.backgroundColor = .clear
    
    // Remove any existing gradient views
    bannerImageView.subviews.forEach { $0.removeFromSuperview() }
    
    bannerImageView.addSubview(gradientView)
    NSLayoutConstraint.activate([
      gradientView.topAnchor.constraint(equalTo: bannerImageView.topAnchor),
      gradientView.leadingAnchor.constraint(equalTo: bannerImageView.leadingAnchor),
      gradientView.trailingAnchor.constraint(equalTo: bannerImageView.trailingAnchor),
      gradientView.bottomAnchor.constraint(equalTo: bannerImageView.bottomAnchor)
    ])
    
    gradientView.layer.insertSublayer(gradient, at: 0)
    
    // Update gradient frame after layout
    DispatchQueue.main.async {
      gradient.frame = gradientView.bounds
    }
  }
  
  private func loadImage(from url: URL, into imageView: UIImageView, type: String) async {
    do {
      let request = ImageRequest(url: url)
      let image = try await ImagePipeline.shared.image(for: request)
      
      guard !Task.isCancelled else { return }
      
      await MainActor.run {
        UIView.transition(with: imageView, duration: 0.3, options: .transitionCrossDissolve) {
          imageView.image = image
          imageView.backgroundColor = .clear
        }
        
        self.headerLogger.debug("Successfully loaded \(type, privacy: .public) image")
      }
    } catch {
      guard !Task.isCancelled else { return }
      headerLogger.error("Failed to load \(type, privacy: .public) image from \(url, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
  }
  
  // MARK: - Follow Button Setup
  private func setupFollowButton(for profile: AppBskyActorDefs.ProfileViewDetailed) {
    // Clear existing button
    followButtonContainer.subviews.forEach { $0.removeFromSuperview() }
    
    guard let appState = appState, let viewModel = viewModel else { return }
    
    // Create SwiftUI follow button using UIHostingController
    let followButtonView = FollowButtonView(
      profile: profile,
      viewModel: viewModel,
      appState: appState
    )
    
    let hostingController = UIHostingController(rootView: followButtonView)
    hostingController.view.backgroundColor = .clear
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    
    followButtonContainer.addSubview(hostingController.view)
    
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: followButtonContainer.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: followButtonContainer.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: followButtonContainer.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: followButtonContainer.bottomAnchor)
    ])
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    
    // Cancel loading tasks
    bannerLoadTask?.cancel()
    
    // Reset state
    bannerImageView.image = nil
    bannerImageView.subviews.forEach { $0.removeFromSuperview() }
    
    // Reset stretch
    resetStretch()
    
    // Clear configuration cache
    lastConfigurationDID = nil
    currentProfile = nil
    
    headerLogger.debug("Header view prepared for reuse")
  }
}
