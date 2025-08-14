import UIKit
import SwiftUI
import Petrel
import Nuke
import os

@available(iOS 18.0, *)
final class EnhancedProfileHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "EnhancedProfileHeaderView"
  
  private let headerLogger = Logger(subsystem: "blue.catbird", category: "EnhancedProfileHeaderView")
  
  // UI Components
  private var containerView: UIView!
  private var bannerImageView: UIImageView!
  private var gradientOverlay: CAGradientLayer!
  private var avatarContainerView: UIView!
  private var avatarImageView: UIImageView!
  private var avatarBorderView: UIView!
  
  // State
  private var currentProfile: AppBskyActorDefs.ProfileViewDetailed?
  private var bannerLoadTask: Task<Void, Never>?
  private var avatarLoadTask: Task<Void, Never>?
  private var appState: AppState?
  private var viewModel: ProfileViewModel?
  
  // Layout Properties
  private var bannerAspectRatio: CGFloat = 3.0 // 3:1 aspect ratio
  private var avatarSize: CGFloat = 88
  private var avatarBorderWidth: CGFloat = 4
  private var avatarOverlapRatio: CGFloat = 0.5 // Avatar overlaps banner by 50%
  
  // Dynamic sizing based on device
  private var computedBannerHeight: CGFloat {
    let screenWidth = UIScreen.main.bounds.width
    let baseHeight = screenWidth / bannerAspectRatio
    
    if UIDevice.current.userInterfaceIdiom == .pad {
      return min(baseHeight, 280) // Slightly smaller for better proportions
    } else {
      return min(baseHeight, 160) // Compact height for modern social profile design
    }
  }
  
  // Total header height includes space for avatar overlap
  var totalHeaderHeight: CGFloat {
    // Banner height + portion of avatar that extends below
    return computedBannerHeight + (avatarSize * avatarOverlapRatio) + avatarBorderWidth
  }
  
  private var responsivePadding: CGFloat {
    let screenWidth = UIScreen.main.bounds.width
    if UIDevice.current.userInterfaceIdiom == .pad {
      return max(32, (screenWidth - 768) / 2)
    } else {
      return 16
    }
  }
  
  // Constraints for animation
  private var bannerHeightConstraint: NSLayoutConstraint!
  private var avatarLeadingConstraint: NSLayoutConstraint!
  private var avatarBottomConstraint: NSLayoutConstraint!
  
  // Performance and State Management
  private var lastConfigurationDID: String?
  private var lastStretchAmount: CGFloat = 0
  private var isCurrentlyStretching: Bool = false
  private var stretchUpdateCounter: Int = 0
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
  }
  
  required init?(coder: NSCoder) {
    headerLogger.error("EnhancedProfileHeaderView: Coder initialization not supported")
    return nil
  }
  
  deinit {
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    headerLogger.debug("EnhancedProfileHeaderView deallocated")
  }
  
  private func setupViews() {
    clipsToBounds = false
    backgroundColor = .clear
    
    // Container for all header content
    containerView = UIView()
    containerView.clipsToBounds = false
    containerView.translatesAutoresizingMaskIntoConstraints = false
    containerView.backgroundColor = .clear
    addSubview(containerView)
    
    // Banner image view with proper setup
    bannerImageView = UIImageView()
    bannerImageView.contentMode = .scaleAspectFill
    bannerImageView.clipsToBounds = true
    bannerImageView.backgroundColor = .systemGray6
    bannerImageView.translatesAutoresizingMaskIntoConstraints = false
    containerView.addSubview(bannerImageView)
    
    // Gradient overlay for better text readability
    gradientOverlay = CAGradientLayer()
    gradientOverlay.colors = [
      UIColor.black.withAlphaComponent(0).cgColor,
      UIColor.black.withAlphaComponent(0.15).cgColor
    ]
    gradientOverlay.locations = [0.5, 1.0]
    bannerImageView.layer.addSublayer(gradientOverlay)
    
    // Avatar container for proper positioning - add AFTER banner for proper z-ordering
    avatarContainerView = UIView()
    avatarContainerView.translatesAutoresizingMaskIntoConstraints = false
    avatarContainerView.clipsToBounds = false
    avatarContainerView.backgroundColor = .clear // Transparent background
    avatarContainerView.layer.zPosition = 100 // Ensure avatar is always on top
    containerView.addSubview(avatarContainerView) // Added after banner to appear on top
    
    // Bring avatar to front to ensure visibility
    containerView.bringSubviewToFront(avatarContainerView)
    
    // Avatar border (background ring)
    avatarBorderView = UIView()
    avatarBorderView.backgroundColor = .systemBackground
    avatarBorderView.layer.cornerRadius = (avatarSize + avatarBorderWidth * 2) / 2
    avatarBorderView.translatesAutoresizingMaskIntoConstraints = false
    avatarBorderView.layer.masksToBounds = true
    avatarContainerView.addSubview(avatarBorderView)
    
    // Avatar image
    avatarImageView = UIImageView()
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true
    avatarImageView.backgroundColor = .systemGray5
    avatarImageView.layer.cornerRadius = avatarSize / 2
    avatarImageView.layer.masksToBounds = true
    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    avatarImageView.isUserInteractionEnabled = true
    
    // Add shadow for depth and visual separation
    avatarImageView.layer.shadowColor = UIColor.black.cgColor
    avatarImageView.layer.shadowOpacity = 0.15
    avatarImageView.layer.shadowOffset = CGSize(width: 0, height: 2)
    avatarImageView.layer.shadowRadius = 4
    avatarImageView.layer.masksToBounds = false
    
    avatarContainerView.addSubview(avatarImageView)
    
    // Ensure avatar is above border
    avatarContainerView.bringSubviewToFront(avatarImageView)
    
    setupConstraints()
    updateForCurrentDevice()
    
    // Debug initial setup
    headerLogger.debug("✅ Initial setup complete")
    headerLogger.debug("  - Avatar size: \(self.avatarSize)")
    headerLogger.debug("  - Border width: \(self.avatarBorderWidth)")
    headerLogger.debug("  - Responsive padding: \(self.responsivePadding)")
    headerLogger.debug("  - Banner height: \(self.computedBannerHeight)")
  }
  
  private func setupConstraints() {
    // Container fills the entire header
    NSLayoutConstraint.activate([
      containerView.topAnchor.constraint(equalTo: topAnchor),
      containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
      containerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
    
    // Banner - edge to edge with dynamic height
    bannerHeightConstraint = bannerImageView.heightAnchor.constraint(equalToConstant: computedBannerHeight)
    NSLayoutConstraint.activate([
      bannerImageView.topAnchor.constraint(equalTo: containerView.topAnchor),
      bannerImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
      bannerImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
      bannerHeightConstraint
    ])
    
    // Avatar container positioning - improved stability
    avatarLeadingConstraint = avatarContainerView.leadingAnchor.constraint(
      equalTo: containerView.leadingAnchor,
      constant: responsivePadding
    )
    
    // IMPROVED: Position avatar with proper overlap at banner edge
    // Avatar bottom edge should be at banner bottom + 50% of avatar height
    avatarBottomConstraint = avatarContainerView.bottomAnchor.constraint(
      equalTo: bannerImageView.bottomAnchor,
      constant: (avatarSize + avatarBorderWidth * 2) * avatarOverlapRatio
    )
    
    NSLayoutConstraint.activate([
      avatarLeadingConstraint,
      avatarBottomConstraint,
      avatarContainerView.widthAnchor.constraint(equalToConstant: avatarSize + avatarBorderWidth * 2),
      avatarContainerView.heightAnchor.constraint(equalToConstant: avatarSize + avatarBorderWidth * 2)
    ])
    
    // Avatar border fills container
    NSLayoutConstraint.activate([
      avatarBorderView.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
      avatarBorderView.leadingAnchor.constraint(equalTo: avatarContainerView.leadingAnchor),
      avatarBorderView.trailingAnchor.constraint(equalTo: avatarContainerView.trailingAnchor),
      avatarBorderView.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor)
    ])
    
    // Avatar image centered in container with padding for border
    NSLayoutConstraint.activate([
      avatarImageView.centerXAnchor.constraint(equalTo: avatarContainerView.centerXAnchor),
      avatarImageView.centerYAnchor.constraint(equalTo: avatarContainerView.centerYAnchor),
      avatarImageView.widthAnchor.constraint(equalToConstant: avatarSize),
      avatarImageView.heightAnchor.constraint(equalToConstant: avatarSize)
    ])
  }
  
  // Device Adaptation
  private func updateForCurrentDevice() {
    let isIPad = UIDevice.current.userInterfaceIdiom == .pad
    let isLandscape = UIScreen.main.bounds.width > UIScreen.main.bounds.height
    
    headerLogger.debug("📱 Updating for device:")
    headerLogger.debug("  - Is iPad: \(isIPad)")
    headerLogger.debug("  - Is Landscape: \(isLandscape)")
    headerLogger.debug("  - Screen size: \(NSCoder.string(for: UIScreen.main.bounds.size))")
    
    // Update avatar size based on device
    if isIPad {
      avatarSize = 100
      avatarBorderWidth = 5
    } else if isLandscape {
      avatarSize = 80
      avatarBorderWidth = 4
    } else {
      avatarSize = 88
      avatarBorderWidth = 4
    }
    
    headerLogger.debug("  - Set avatar size: \(self.avatarSize)")
    headerLogger.debug("  - Set border width: \(self.avatarBorderWidth)")
    
    // Update constraints for new sizes
    if let widthConstraint = avatarContainerView.constraints.first(where: { $0.firstAttribute == .width }) {
      widthConstraint.constant = avatarSize + avatarBorderWidth * 2
    }
    if let heightConstraint = avatarContainerView.constraints.first(where: { $0.firstAttribute == .height }) {
      heightConstraint.constant = avatarSize + avatarBorderWidth * 2
    }
    if let avatarWidthConstraint = avatarImageView.constraints.first(where: { $0.firstAttribute == .width }) {
      avatarWidthConstraint.constant = avatarSize
    }
    if let avatarHeightConstraint = avatarImageView.constraints.first(where: { $0.firstAttribute == .height }) {
      avatarHeightConstraint.constant = avatarSize
    }
    
    // Update banner height
    bannerHeightConstraint.constant = computedBannerHeight
    
    // Update padding
    avatarLeadingConstraint.constant = responsivePadding
    
    // Update avatar positioning - maintain stable overlap
    avatarBottomConstraint.constant = (avatarSize + avatarBorderWidth * 2) * avatarOverlapRatio
    
    // Update avatar corner radius
    avatarImageView.layer.cornerRadius = avatarSize / 2
    avatarBorderView.layer.cornerRadius = (avatarSize + avatarBorderWidth * 2) / 2
    
    headerLogger.debug("  - Avatar corner radius: \(self.avatarSize / 2)")
    let borderRadius = (self.avatarSize + self.avatarBorderWidth * 2) / 2
    headerLogger.debug("  - Border corner radius: \(borderRadius)")
    headerLogger.debug("  - Final avatar constraint constant: \(self.avatarBottomConstraint.constant)")
  }
  
  private var isAnimating = false
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Skip layout updates during animations to prevent recursive loops
    guard !isAnimating else { return }
    
    // Update gradient frame
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientOverlay.frame = bannerImageView.bounds
    CATransaction.commit()
    
    // Comprehensive avatar debug logging
    headerLogger.debug("🔍 AVATAR DEBUG - layoutSubviews")
    headerLogger.debug("  📐 Header bounds: \(self.bounds.debugDescription)")
    headerLogger.debug("  📐 Container frame: \(self.containerView.frame.debugDescription)")
    headerLogger.debug("  📐 Banner frame: \(self.bannerImageView.frame.debugDescription)")
    headerLogger.debug("  🎯 Avatar container:")
    headerLogger.debug("    - Frame: \(self.avatarContainerView.frame.debugDescription)")
    headerLogger.debug("    - Hidden: \(self.avatarContainerView.isHidden)")
    headerLogger.debug("    - Alpha: \(self.avatarContainerView.alpha)")
    headerLogger.debug("    - Superview: \(self.avatarContainerView.superview != nil)")
    headerLogger.debug("  🖼️ Avatar image:")
    headerLogger.debug("    - Frame: \(self.avatarImageView.frame.debugDescription)")
    headerLogger.debug("    - Hidden: \(self.avatarImageView.isHidden)")
    headerLogger.debug("    - Alpha: \(self.avatarImageView.alpha)")
    headerLogger.debug("    - Has image: \(self.avatarImageView.image != nil)")
    headerLogger.debug("    - Content mode: \(self.avatarImageView.contentMode.rawValue)")
    headerLogger.debug("  🔲 Avatar border:")
    headerLogger.debug("    - Frame: \(self.avatarBorderView.frame.debugDescription)")
    headerLogger.debug("    - Background: \(String(describing: self.avatarBorderView.backgroundColor))")
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    
    // Update for size class changes
    if previousTraitCollection?.horizontalSizeClass != traitCollection.horizontalSizeClass ||
       previousTraitCollection?.verticalSizeClass != traitCollection.verticalSizeClass {
      updateForCurrentDevice()
    }
    
    // Update theme colors
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      updateThemeColors()
    }
  }
  
  private func updateThemeColors() {
    avatarBorderView.backgroundColor = .systemBackground
  }
  
  func configure(profile: AppBskyActorDefs.ProfileViewDetailed, appState: AppState, viewModel: ProfileViewModel) {
    self.appState = appState
    self.viewModel = viewModel
    let profileDID = profile.did.didString()
    
    // Skip duplicate configurations
    guard lastConfigurationDID != profileDID else {
      headerLogger.debug("Skipping duplicate configuration for DID: \(profileDID, privacy: .public)")
      return
    }
    
    lastConfigurationDID = profileDID
    currentProfile = profile
    
    headerLogger.debug("🔧 Configuring enhanced header")
    headerLogger.debug("  - Profile: @\(profile.handle, privacy: .public)")
    headerLogger.debug("  - DID: \(profileDID, privacy: .public)")
    headerLogger.debug("  - Current frame: \(self.frame.debugDescription)")
    headerLogger.debug("  - Current bounds: \(self.bounds.debugDescription)")
    headerLogger.debug("  - Has avatar URL: \(profile.avatar != nil)")
    headerLogger.debug("  - Has banner URL: \(profile.banner != nil)")
    
    // Cancel previous load tasks
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    
    // Load banner image
    if let bannerURL = profile.banner?.uriString(),
       let url = URL(string: bannerURL) {
      bannerLoadTask = Task {
        await loadBannerImage(from: url)
      }
    } else {
      applyDefaultBanner()
    }
    
    // Load avatar image
    if let avatarURL = profile.avatar?.uriString(),
       let url = URL(string: avatarURL) {
      headerLogger.debug("🌐 Starting avatar load from URL: \(avatarURL, privacy: .public)")
      avatarLoadTask = Task {
        await loadAvatarImage(from: url)
      }
    } else {
      headerLogger.debug("⚠️ No avatar URL found, applying default avatar")
      applyDefaultAvatar()
    }
  }
  
  // Image Loading
  private func loadBannerImage(from url: URL) async {
    do {
      var request = ImageRequest(url: url)
      request.processors = [
        ImageProcessors.Resize(size: CGSize(
          width: UIScreen.main.bounds.width * UIScreen.main.scale,
          height: computedBannerHeight * UIScreen.main.scale
        ), contentMode: .aspectFill)
      ]
      
      let image = try await ImagePipeline.shared.image(for: request)
      
      guard !Task.isCancelled else { return }
      
      await MainActor.run {
        UIView.transition(with: bannerImageView, duration: 0.3, options: .transitionCrossDissolve) {
          self.bannerImageView.image = image
          self.bannerImageView.backgroundColor = .clear
        }
        headerLogger.debug("✅ Successfully loaded banner image")
        headerLogger.debug("  - Image size: \(NSCoder.string(for: image.size))")
      }
    } catch {
      guard !Task.isCancelled else { return }
      headerLogger.error("❌ Failed to load banner: \(error.localizedDescription, privacy: .public)")
      headerLogger.error("  - URL: \(url, privacy: .public)")
      await MainActor.run {
        applyDefaultBanner()
      }
    }
  }
  
  private func loadAvatarImage(from url: URL) async {
    do {
      let size = avatarSize * UIScreen.main.scale
      var request = ImageRequest(url: url)
      request.processors = [
        ImageProcessors.Resize(size: CGSize(width: size, height: size), contentMode: .aspectFill),
        ImageProcessors.Circle()
      ]
      
      let image = try await ImagePipeline.shared.image(for: request)
      
      guard !Task.isCancelled else { return }
      
      await MainActor.run {
        UIView.transition(with: avatarImageView, duration: 0.3, options: .transitionCrossDissolve) {
          self.avatarImageView.image = image
          self.avatarImageView.backgroundColor = .clear
        }
        headerLogger.debug("✅ Successfully loaded avatar image")
        headerLogger.debug("  - Image size: \(NSCoder.string(for: image.size))")
        headerLogger.debug("  - Avatar frame: \(self.avatarImageView.frame.debugDescription)")
        // Ensure avatar is visible
        self.avatarImageView.alpha = 1.0
        self.avatarContainerView.alpha = 1.0
        self.avatarBorderView.alpha = 1.0
        headerLogger.debug("  - Set all alpha values to 1.0")
      }
    } catch {
      guard !Task.isCancelled else { return }
      headerLogger.error("❌ Failed to load avatar: \(error.localizedDescription, privacy: .public)")
      headerLogger.error("  - URL: \(url, privacy: .public)")
      await MainActor.run {
        applyDefaultAvatar()
      }
    }
  }
  
  private func applyDefaultBanner() {
    // Create gradient background
    let gradient = CAGradientLayer()
    gradient.colors = [
      UIColor.systemBlue.cgColor,
      UIColor.systemPurple.cgColor
    ]
    gradient.startPoint = CGPoint(x: 0, y: 0)
    gradient.endPoint = CGPoint(x: 1, y: 1)
    gradient.frame = bannerImageView.bounds
    
    bannerImageView.image = nil
    bannerImageView.backgroundColor = .systemGray6
    bannerImageView.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
    bannerImageView.layer.insertSublayer(gradient, at: 0)
    bannerImageView.layer.addSublayer(gradientOverlay) // Re-add gradient overlay
  }
  
  private func applyDefaultAvatar() {
    avatarImageView.image = UIImage(systemName: "person.crop.circle.fill")
    avatarImageView.backgroundColor = .systemGray4
    avatarImageView.tintColor = .systemGray2
    avatarImageView.contentMode = .scaleAspectFit
    
    // Make sure avatar is visible
    avatarImageView.alpha = 1.0
    avatarContainerView.alpha = 1.0
    avatarBorderView.alpha = 1.0
    
    headerLogger.debug("🎭 Applied default avatar")
    headerLogger.debug("  - Avatar container frame: \(self.avatarContainerView.frame.debugDescription)")
    headerLogger.debug("  - Avatar image frame: \(self.avatarImageView.frame.debugDescription)")
    headerLogger.debug("  - All alpha values set to 1.0")
  }
  
  // Stretch Effect - Elastic banner stretch on overscroll
  @MainActor
  func updateForStretch(stretchAmount: CGFloat) {
    guard stretchAmount > 0 else {
      resetStretch()
      return
    }
    
    // Throttle updates to prevent excessive processing
    stretchUpdateCounter += 1
    guard stretchUpdateCounter % 2 == 0 || stretchAmount > lastStretchAmount + 5 else {
      return
    }
    
    lastStretchAmount = stretchAmount
    isCurrentlyStretching = true
    
    // REMOVED: Scale transform since FixedStretchyLayout already handles banner stretching via frame changes
    // This eliminates double transformation that was causing jankiness
    
    // REMOVED: Avatar transform to prevent avatar movement during pull-to-refresh
    // Keep avatar fixed in position relative to the banner
    
    // Ensure avatar stays visible and properly positioned
    avatarContainerView.layer.zPosition = 100
    avatarContainerView.alpha = 1.0
    avatarImageView.alpha = 1.0
    avatarBorderView.alpha = 1.0
    
    if stretchAmount > 20 {
      headerLogger.debug("🔄 Stretch update - amount: \(stretchAmount), no transforms applied")
    }
  }
  
  private func setAnchorPoint(_ anchorPoint: CGPoint, for view: UIView) {
    let oldAnchor = view.layer.anchorPoint
    let newAnchor = anchorPoint
    
    let oldPosition = view.layer.position
    let bounds = view.bounds
    
    let newPositionX = oldPosition.x + bounds.width * (newAnchor.x - oldAnchor.x)
    let newPositionY = oldPosition.y + bounds.height * (newAnchor.y - oldAnchor.y)
    
    view.layer.anchorPoint = newAnchor
    view.layer.position = CGPoint(x: newPositionX, y: newPositionY)
  }
  
  @MainActor
  func resetStretch() {
    guard lastStretchAmount > 0 || isCurrentlyStretching else { return }
    
    lastStretchAmount = 0
    isCurrentlyStretching = false
    stretchUpdateCounter = 0
    
    // Since we removed transforms, no animation is needed
    // Just ensure avatar remains visible and properly positioned
    avatarContainerView.alpha = 1.0
    avatarImageView.alpha = 1.0
    avatarBorderView.alpha = 1.0
    avatarContainerView.layer.zPosition = 100
    
    headerLogger.debug("🔄 Stretch reset complete - no transforms to reset")
  }
  
  // Cleanup
  override func prepareForReuse() {
    super.prepareForReuse()
    
    // Cancel tasks
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    
    // Reset images
    bannerImageView.image = nil
    avatarImageView.image = nil
    
    // Reset transforms and state
    resetStretch()
    
    // Clear all state variables
    lastConfigurationDID = nil
    currentProfile = nil
    lastStretchAmount = 0
    isCurrentlyStretching = false
    stretchUpdateCounter = 0
    
    // Ensure avatar visibility
    avatarContainerView.alpha = 1.0
    avatarImageView.alpha = 1.0
    avatarBorderView.alpha = 1.0
    
    headerLogger.debug("Enhanced header prepared for reuse")
  }
}
