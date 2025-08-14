import UIKit
import SwiftUI
import Petrel
import Nuke
import os

@available(iOS 18.0, *)
final class UltraSmoothProfileHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "UltraSmoothProfileHeaderView"
  
  private let headerLogger = Logger(subsystem: "blue.catbird", category: "UltraSmoothProfileHeaderView")
  
  // MARK: - Animation State
  enum HeaderState {
    case normal       // Standard position
    case stretching   // Pulling down
    case compressed   // Scrolling up
  }
  
  private var currentState: HeaderState = .normal
  
  // MARK: - Layout Constants
  private struct LayoutConstants {
    static let baseBannerHeight: CGFloat = 160
    static let maxBannerHeight: CGFloat = 240
    static let baseAvatarSize: CGFloat = 88
    static let minAvatarSize: CGFloat = 64
    static let avatarBorderWidth: CGFloat = 4
    static let avatarOverlapFromBottom: CGFloat = 44
    static let responsivePadding: CGFloat = 16
    
    // Animation curves
    static let stretchResistance: CGFloat = 0.6  // How much resistance when stretching
    static let parallaxSpeed: CGFloat = 0.5      // Banner parallax speed when scrolling up
  }
  
  // MARK: - UI Components (Layer-based for performance)
  private var containerView: UIView!
  private var bannerContainerView: UIView!
  private var bannerImageLayer: CALayer!
  private var gradientLayer: CAGradientLayer!
  private var avatarContainerView: UIView!
  private var avatarImageLayer: CALayer!
  private var avatarBorderLayer: CALayer!
  
  // MARK: - State Management
  private var currentProfile: AppBskyActorDefs.ProfileViewDetailed?
  private var appState: AppState?
  private var viewModel: ProfileViewModel?
  
  // MARK: - Image Loading
  private var bannerLoadTask: Task<Void, Never>?
  private var avatarLoadTask: Task<Void, Never>?
  
  // MARK: - Cached Layout Values (computed once, reused)
  private var baseFrames: (
    banner: CGRect,
    avatar: CGRect,
    container: CGRect
  ) = (.zero, .zero, .zero)
  
  private var lastConfigurationDID: String?
  
  // MARK: - Initialization
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViews()
    calculateBaseFrames()
  }
  
  required init?(coder: NSCoder) {
    headerLogger.error("UltraSmoothProfileHeaderView: Coder initialization not supported")
    return nil
  }
  
  deinit {
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    headerLogger.debug("UltraSmoothProfileHeaderView deallocated")
  }
  
  // MARK: - Setup
  private func setupViews() {
    clipsToBounds = false
    backgroundColor = .clear
    
    // Container view fills the header
    containerView = UIView()
    containerView.clipsToBounds = false
    containerView.backgroundColor = .clear
    addSubview(containerView)
    
    // Banner container - clips banner content cleanly
    bannerContainerView = UIView()
    bannerContainerView.clipsToBounds = true
    bannerContainerView.backgroundColor = .systemGray6
    containerView.addSubview(bannerContainerView)
    
    // Banner image layer (CALayer for better performance than UIImageView)
    bannerImageLayer = CALayer()
    bannerImageLayer.contentsGravity = .resizeAspectFill
    bannerImageLayer.masksToBounds = true
    bannerContainerView.layer.addSublayer(bannerImageLayer)
    
    // Gradient overlay for text readability
    gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.black.withAlphaComponent(0).cgColor,
      UIColor.black.withAlphaComponent(0.15).cgColor
    ]
    gradientLayer.locations = [0.5, 1.0]
    bannerContainerView.layer.addSublayer(gradientLayer)
    
    // Avatar container - positioned absolutely for performance
    avatarContainerView = UIView()
    avatarContainerView.clipsToBounds = false
    avatarContainerView.backgroundColor = .clear
    containerView.addSubview(avatarContainerView)
    
    // Avatar border layer
    avatarBorderLayer = CALayer()
    avatarBorderLayer.backgroundColor = UIColor.systemBackground.cgColor
    avatarBorderLayer.masksToBounds = true
    avatarContainerView.layer.addSublayer(avatarBorderLayer)
    
    // Avatar image layer
    avatarImageLayer = CALayer()
    avatarImageLayer.contentsGravity = .resizeAspectFill
    avatarImageLayer.masksToBounds = true
    avatarImageLayer.backgroundColor = UIColor.systemGray5.cgColor
    
    // Shadow for avatar depth
    avatarImageLayer.shadowColor = UIColor.black.cgColor
    avatarImageLayer.shadowOpacity = 0.15
    avatarImageLayer.shadowOffset = CGSize(width: 0, height: 2)
    avatarImageLayer.shadowRadius = 4
    
    avatarContainerView.layer.addSublayer(avatarImageLayer)
    
    headerLogger.debug("✅ UltraSmoothProfileHeaderView setup complete")
  }
  
  // MARK: - Layout Calculation
  private func calculateBaseFrames() {
    let bounds = self.bounds
    let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
    
    // Container fills entire header
    baseFrames.container = CGRect(x: 0, y: 0, width: width, height: LayoutConstants.baseBannerHeight + LayoutConstants.avatarOverlapFromBottom)
    
    // Banner fills width, standard height
    baseFrames.banner = CGRect(x: 0, y: 0, width: width, height: LayoutConstants.baseBannerHeight)
    
    // Avatar positioned at bottom-left of banner with overlap
    let avatarTotalSize = LayoutConstants.baseAvatarSize + (LayoutConstants.avatarBorderWidth * 2)
    let avatarX = LayoutConstants.responsivePadding
    let avatarY = LayoutConstants.baseBannerHeight - (avatarTotalSize * 0.5) // 50% overlap
    baseFrames.avatar = CGRect(x: avatarX, y: avatarY, width: avatarTotalSize, height: avatarTotalSize)
    
    headerLogger.debug("📐 Base frames calculated:")
      headerLogger.debug("  - Container: \(NSCoder.string(for: self.baseFrames.container.size))")
      headerLogger.debug("  - Banner: \(NSCoder.string(for: self.baseFrames.banner.size))")
      headerLogger.debug("  - Avatar: \(NSCoder.string(for: self.baseFrames.avatar.size))")
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    
    // Recalculate base frames if bounds changed
    if baseFrames.container.width != bounds.width {
      calculateBaseFrames()
    }
    
    // Apply base layout (will be modified by scroll animations)
    applyBaseLayout()
  }
  
  private func applyBaseLayout() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Container
    containerView.frame = baseFrames.container
    
    // Banner
    bannerContainerView.frame = baseFrames.banner
    bannerImageLayer.frame = bannerContainerView.bounds
    gradientLayer.frame = bannerContainerView.bounds
    
    // Avatar
    avatarContainerView.frame = baseFrames.avatar
    
    let borderSize = baseFrames.avatar.size
    avatarBorderLayer.frame = CGRect(origin: .zero, size: borderSize)
    avatarBorderLayer.cornerRadius = borderSize.width / 2
    
    let avatarSize = CGSize(width: LayoutConstants.baseAvatarSize, height: LayoutConstants.baseAvatarSize)
    let avatarFrame = CGRect(
      x: LayoutConstants.avatarBorderWidth,
      y: LayoutConstants.avatarBorderWidth,
      width: avatarSize.width,
      height: avatarSize.height
    )
    avatarImageLayer.frame = avatarFrame
    avatarImageLayer.cornerRadius = avatarSize.width / 2
    
    CATransaction.commit()
  }
  
  // MARK: - Configuration
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
    
    headerLogger.debug("🔧 Configuring UltraSmoothProfileHeaderView")
    headerLogger.debug("  - Profile: @\(profile.handle, privacy: .public)")
    
    // Cancel previous loads
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    
    // Load banner
    if let bannerURL = profile.banner?.uriString(), let url = URL(string: bannerURL) {
      bannerLoadTask = Task {
        await loadBannerImage(from: url)
      }
    } else {
      applyDefaultBanner()
    }
    
    // Load avatar
    if let avatarURL = profile.avatar?.uriString(), let url = URL(string: avatarURL) {
      avatarLoadTask = Task {
        await loadAvatarImage(from: url)
      }
    } else {
      applyDefaultAvatar()
    }
  }
  
  // MARK: - Image Loading
  private func loadBannerImage(from url: URL) async {
    do {
      var request = ImageRequest(url: url)
      request.processors = [
        ImageProcessors.Resize(
          size: CGSize(width: UIScreen.main.bounds.width * UIScreen.main.scale, 
                      height: LayoutConstants.maxBannerHeight * UIScreen.main.scale),
          contentMode: .aspectFill
        )
      ]
      
      let image = try await ImagePipeline.shared.image(for: request)
      
      guard !Task.isCancelled else { return }
      
      await MainActor.run {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        bannerImageLayer.contents = image.cgImage
        CATransaction.commit()
        
        headerLogger.debug("✅ Banner image loaded successfully")
      }
    } catch {
      guard !Task.isCancelled else { return }
      headerLogger.error("❌ Failed to load banner: \(error.localizedDescription, privacy: .public)")
      await MainActor.run {
        applyDefaultBanner()
      }
    }
  }
  
  private func loadAvatarImage(from url: URL) async {
    do {
      let size = LayoutConstants.baseAvatarSize * UIScreen.main.scale
      var request = ImageRequest(url: url)
      request.processors = [
        ImageProcessors.Resize(size: CGSize(width: size, height: size), contentMode: .aspectFill),
        ImageProcessors.Circle()
      ]
      
      let image = try await ImagePipeline.shared.image(for: request)
      
      guard !Task.isCancelled else { return }
      
      await MainActor.run {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        avatarImageLayer.contents = image.cgImage
        CATransaction.commit()
        
        headerLogger.debug("✅ Avatar image loaded successfully")
      }
    } catch {
      guard !Task.isCancelled else { return }
      headerLogger.error("❌ Failed to load avatar: \(error.localizedDescription, privacy: .public)")
      await MainActor.run {
        applyDefaultAvatar()
      }
    }
  }
  
  private func applyDefaultBanner() {
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.systemBlue.cgColor,
      UIColor.systemPurple.cgColor
    ]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    gradientLayer.frame = bannerContainerView.bounds
    
    bannerImageLayer.contents = nil
    bannerImageLayer.addSublayer(gradientLayer)
  }
  
  private func applyDefaultAvatar() {
    // Create default avatar using SF Symbol
    let configuration = UIImage.SymbolConfiguration(pointSize: LayoutConstants.baseAvatarSize * 0.6, weight: .light)
    let defaultImage = UIImage(systemName: "person.crop.circle.fill", withConfiguration: configuration)
    avatarImageLayer.contents = defaultImage?.cgImage
    avatarImageLayer.backgroundColor = UIColor.systemGray4.cgColor
  }
  
  // MARK: - Animation API (called from scroll delegate)
  func updateForScrollOffset(_ scrollOffset: CGFloat) {
    // This is where all the magic happens
    // Called directly from UIKitProfileViewController.scrollViewDidScroll
    
    let adjustedOffset = scrollOffset + (bounds.height * 0.5) // Adjust for header position
    
    if adjustedOffset < 0 {
      // Pulling down - stretch effect
      updateForStretching(stretchAmount: abs(adjustedOffset))
      currentState = .stretching
    } else if adjustedOffset > 20 {
      // Scrolling up - compress effect
      updateForCompression(compressionOffset: adjustedOffset)
      currentState = .compressed
    } else {
      // Normal state
      resetToNormal()
      currentState = .normal
    }
  }
  
  private func updateForStretching(stretchAmount: CGFloat) {
    // Rubber band physics - resistance increases with stretch
    let resistance = LayoutConstants.stretchResistance
    let effectiveStretch = stretchAmount * resistance
    let maxStretch = LayoutConstants.maxBannerHeight - LayoutConstants.baseBannerHeight
    let clampedStretch = min(effectiveStretch, maxStretch)
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Stretch banner
    let newBannerHeight = LayoutConstants.baseBannerHeight + clampedStretch
    bannerContainerView.frame = CGRect(
      x: 0, y: 0,
      width: baseFrames.banner.width,
      height: newBannerHeight
    )
    
    // Scale banner image to maintain aspect
    let scale = newBannerHeight / LayoutConstants.baseBannerHeight
    bannerImageLayer.frame = CGRect(
      x: 0, y: 0,
      width: baseFrames.banner.width,
      height: newBannerHeight
    )
    
    // Update gradient
    gradientLayer.frame = bannerImageLayer.frame
    
    // Avatar stays fixed during stretch (key improvement)
    // Just ensure it's at the right z-level
    avatarContainerView.layer.zPosition = 100
    
    CATransaction.commit()
  }
  
  private func updateForCompression(compressionOffset: CGFloat) {
    let maxCompression: CGFloat = 100
    let progress = min(compressionOffset / maxCompression, 1.0)
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Banner parallax - moves up slower than scroll
    let parallaxOffset = compressionOffset * LayoutConstants.parallaxSpeed
    bannerContainerView.frame = CGRect(
      x: 0, y: -parallaxOffset,
      width: baseFrames.banner.width,
      height: baseFrames.banner.height
    )
    
    // Avatar scaling and movement (Twitter-style)
    let avatarScale = 1.0 - (progress * 0.27) // Scale from 88pt to 64pt
    let scaledSize = LayoutConstants.baseAvatarSize * avatarScale
    let borderSize = scaledSize + (LayoutConstants.avatarBorderWidth * 2)
    
    // Move avatar up and slightly left
    let avatarMovement: CGFloat = progress * 20
    avatarContainerView.frame = CGRect(
      x: baseFrames.avatar.minX - (avatarMovement * 0.3),
      y: baseFrames.avatar.minY - avatarMovement,
      width: borderSize,
      height: borderSize
    )
    
    // Update avatar layers
    avatarBorderLayer.frame = CGRect(origin: .zero, size: CGSize(width: borderSize, height: borderSize))
    avatarBorderLayer.cornerRadius = borderSize / 2
    
    avatarImageLayer.frame = CGRect(
      x: LayoutConstants.avatarBorderWidth,
      y: LayoutConstants.avatarBorderWidth,
      width: scaledSize,
      height: scaledSize
    )
    avatarImageLayer.cornerRadius = scaledSize / 2
    
    CATransaction.commit()
  }
  
  private func resetToNormal() {
    guard currentState != .normal else { return }
    
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    
    // Reset to base frames
    bannerContainerView.frame = baseFrames.banner
    bannerImageLayer.frame = bannerContainerView.bounds
    gradientLayer.frame = bannerContainerView.bounds
    
    avatarContainerView.frame = baseFrames.avatar
    
    let borderSize = baseFrames.avatar.size
    avatarBorderLayer.frame = CGRect(origin: .zero, size: borderSize)
    avatarBorderLayer.cornerRadius = borderSize.width / 2
    
    let avatarSize = CGSize(width: LayoutConstants.baseAvatarSize, height: LayoutConstants.baseAvatarSize)
    avatarImageLayer.frame = CGRect(
      x: LayoutConstants.avatarBorderWidth,
      y: LayoutConstants.avatarBorderWidth,
      width: avatarSize.width,
      height: avatarSize.height
    )
    avatarImageLayer.cornerRadius = avatarSize.width / 2
    
    CATransaction.commit()
  }
  
  // MARK: - Cleanup
  override func prepareForReuse() {
    super.prepareForReuse()
    
    bannerLoadTask?.cancel()
    avatarLoadTask?.cancel()
    
    bannerImageLayer.contents = nil
    avatarImageLayer.contents = nil
    
    resetToNormal()
    currentState = .normal
    lastConfigurationDID = nil
    currentProfile = nil
    
    headerLogger.debug("UltraSmoothProfileHeaderView prepared for reuse")
  }
}
