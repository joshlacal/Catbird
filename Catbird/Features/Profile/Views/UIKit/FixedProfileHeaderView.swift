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
  private var gradientLayer: CAGradientLayer!
  private var currentProfile: AppBskyActorDefs.ProfileViewDetailed?
  
  // Store original dimensions
  private let originalHeight: CGFloat = 200
  
  // Constraints we'll modify
  private var bannerTopConstraint: NSLayoutConstraint!
  
  // Image loading tasks
  private var bannerLoadTask: Task<Void, Never>?
  
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
    headerLogger.debug("FixedProfileHeaderView deallocated")
  }
  
  private func setupViews() {
    clipsToBounds = false // Allow elements to extend beyond bounds
    backgroundColor = .clear
    
    // Banner image view with safe defaults
    bannerImageView = UIImageView()
    bannerImageView.contentMode = .scaleAspectFill
    bannerImageView.clipsToBounds = true
    bannerImageView.backgroundColor = .systemGray6
    bannerImageView.translatesAutoresizingMaskIntoConstraints = false
    bannerImageView.layer.masksToBounds = true // Ensure proper clipping
    addSubview(bannerImageView)
    
    // Add subtle gradient overlay for visual depth
    gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.1).cgColor
    ]
    gradientLayer.locations = [0.7, 1.0]
    gradientLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1) // Safe initial frame
    bannerImageView.layer.addSublayer(gradientLayer)
    
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
      bannerImageView.heightAnchor.constraint(equalToConstant: originalHeight)
    ])
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Update gradient frame with bounds checking
    let bannerBounds = bannerImageView.bounds
    if bannerBounds.width > 0 && bannerBounds.height > 0 && 
       bannerBounds.width.isFinite && bannerBounds.height.isFinite {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gradientLayer.frame = bannerBounds
      CATransaction.commit()
    }
  }
  
  @MainActor
  func updateForStretch(stretchAmount: CGFloat) {
    // Only stretch when pulling down (positive stretch)
    guard stretchAmount > 0 && stretchAmount.isFinite && !stretchAmount.isNaN else {
      resetStretch()
      return
    }
    
    // Clamp stretch amount to prevent excessive scaling
    let maxStretch = originalHeight * 1.5 // Maximum 1.5x stretch
    let clampedStretch = min(stretchAmount, maxStretch)
    
    // Keep banner top pinned since layout handles frame positioning
    bannerTopConstraint.constant = 0
    
    // Safe scale calculation with bounds checking
    let scaleRatio = clampedStretch / originalHeight
    let scale = max(1.0, min(2.0, 1 + scaleRatio * 0.3)) // Clamp scale between 1.0 and 2.0
    
    // Validate scale before applying
    if scale.isFinite && !scale.isNaN && scale > 0 {
      bannerImageView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
    
    if stretchAmount > 10 {
      headerLogger.debug("Stretch: amount=\(clampedStretch, privacy: .public), scale=\(scale, privacy: .public)")
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
    
    // Avatar is now handled in ProfileInfoCell
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
