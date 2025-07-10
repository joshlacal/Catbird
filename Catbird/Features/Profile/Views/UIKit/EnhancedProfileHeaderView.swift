import UIKit
import SwiftUI
import Petrel
import Nuke
import os

@available(iOS 18.0, *)
final class EnhancedProfileHeaderView: UICollectionReusableView {
  static let reuseIdentifier = "EnhancedProfileHeaderView"
    
  private var bannerImageView: UIImageView!
  private var bannerOverlayView: UIView!
  private var avatarContainerView: UIView!
  private var avatarImageView: UIImageView!
  private var currentProfile: AppBskyActorDefs.ProfileViewDetailed?
  
  private let originalHeight: CGFloat = 200
  private let avatarSize: CGFloat = 80
  private let avatarBorderWidth: CGFloat = 4
  
  private var bannerHeightConstraint: NSLayoutConstraint!
  private var bannerTopConstraint: NSLayoutConstraint!
  private var avatarBottomConstraint: NSLayoutConstraint!
  
  private var lastStretchAmount: CGFloat = 0
  
  override init(frame: CGRect) {
    super.init(frame: frame)
    setupViewHierarchy()
    setupConstraints()
    setupStyling()
  }
  
  required init?(coder: NSCoder) {
//    logger.error("EnhancedProfileHeaderView: Coder initialization not supported")
    return nil
  }
  
  private func setupViewHierarchy() {
    clipsToBounds = true
    
    bannerImageView = UIImageView()
    bannerImageView.contentMode = .scaleAspectFill
    bannerImageView.clipsToBounds = true
    bannerImageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(bannerImageView)
    
    bannerOverlayView = UIView()
    bannerOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.1)
    bannerOverlayView.translatesAutoresizingMaskIntoConstraints = false
    bannerOverlayView.alpha = 0
    addSubview(bannerOverlayView)
    
    avatarContainerView = UIView()
    avatarContainerView.backgroundColor = .clear
    avatarContainerView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(avatarContainerView)
    
    avatarImageView = UIImageView()
    avatarImageView.contentMode = .scaleAspectFill
    avatarImageView.clipsToBounds = true
    avatarImageView.translatesAutoresizingMaskIntoConstraints = false
    avatarContainerView.addSubview(avatarImageView)
  }
  
  private func setupConstraints() {
    bannerHeightConstraint = bannerImageView.heightAnchor.constraint(equalToConstant: originalHeight)
    bannerTopConstraint = bannerImageView.topAnchor.constraint(equalTo: topAnchor)
    
    NSLayoutConstraint.activate([
      bannerImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      bannerImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bannerTopConstraint,
      bannerHeightConstraint
    ])
    
    NSLayoutConstraint.activate([
      bannerOverlayView.leadingAnchor.constraint(equalTo: bannerImageView.leadingAnchor),
      bannerOverlayView.trailingAnchor.constraint(equalTo: bannerImageView.trailingAnchor),
      bannerOverlayView.topAnchor.constraint(equalTo: bannerImageView.topAnchor),
      bannerOverlayView.bottomAnchor.constraint(equalTo: bannerImageView.bottomAnchor)
    ])
    
    avatarBottomConstraint = avatarContainerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: avatarSize / 2)
    NSLayoutConstraint.activate([
      avatarContainerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      avatarBottomConstraint,
      avatarContainerView.widthAnchor.constraint(equalToConstant: avatarSize),
      avatarContainerView.heightAnchor.constraint(equalToConstant: avatarSize)
    ])
    
    NSLayoutConstraint.activate([
      avatarImageView.topAnchor.constraint(equalTo: avatarContainerView.topAnchor),
      avatarImageView.leadingAnchor.constraint(equalTo: avatarContainerView.leadingAnchor),
      avatarImageView.trailingAnchor.constraint(equalTo: avatarContainerView.trailingAnchor),
      avatarImageView.bottomAnchor.constraint(equalTo: avatarContainerView.bottomAnchor)
    ])
  }
  
  private func setupStyling() {
    backgroundColor = UIColor.systemGray6
    
    avatarImageView.layer.cornerRadius = avatarSize / 2
    avatarImageView.layer.borderWidth = avatarBorderWidth
    avatarImageView.backgroundColor = UIColor.systemGray4
    
    updateBorderColor()
  }
  
  override func layoutSubviews() {
    super.layoutSubviews()
    updateBorderColor()
  }
  
  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    updateBorderColor()
  }
  
  private func updateBorderColor() {
    avatarImageView.layer.borderColor = UIColor.systemBackground.cgColor
  }
  
  func configure(profile: AppBskyActorDefs.ProfileViewDetailed) {
    self.currentProfile = profile
    
    loadBannerImage(from: profile.banner)
    loadAvatarImage(from: profile.avatar)
  }
  
  private func loadBannerImage(from banner: URI?) {
    if let bannerURL = banner?.uriString(), let url = URL(string: bannerURL) {
      logger.debug("Loading banner image from: \(bannerURL, privacy: .public)")
      
      Task {
        do {
          let request = ImageRequest(url: url)
          let image = try await ImagePipeline.shared.image(for: request)
          await MainActor.run {
            self.bannerImageView.image = image
            self.bannerImageView.backgroundColor = .clear
          }
        } catch {
          logger.error("Failed to load banner image: \(error.localizedDescription, privacy: .public)")
          await MainActor.run {
            self.setupDefaultBanner()
          }
        }
      }
    } else {
      setupDefaultBanner()
    }
  }
  
  private func loadAvatarImage(from avatar: URI?) {
    if let avatarURL = avatar?.uriString(), let url = URL(string: avatarURL) {
      logger.debug("Loading avatar image from: \(avatarURL, privacy: .public)")
      
      Task {
        do {
          let request = ImageRequest(url: url)
          let image = try await ImagePipeline.shared.image(for: request)
          await MainActor.run {
            self.avatarImageView.image = image
            self.avatarImageView.backgroundColor = .clear
          }
        } catch {
          logger.error("Failed to load avatar image: \(error.localizedDescription, privacy: .public)")
          await MainActor.run {
            self.setupDefaultAvatar()
          }
        }
      }
    } else {
      setupDefaultAvatar()
    }
  }
  
  private func setupDefaultBanner() {
    bannerImageView.image = nil
    
    let gradientLayer = CAGradientLayer()
    gradientLayer.colors = [
      UIColor.systemBlue.withAlphaComponent(0.4).cgColor,
      UIColor.systemPurple.withAlphaComponent(0.3).cgColor
    ]
    gradientLayer.startPoint = CGPoint(x: 0, y: 0)
    gradientLayer.endPoint = CGPoint(x: 1, y: 1)
    gradientLayer.frame = bannerImageView.bounds
    
    bannerImageView.layer.sublayers?.removeAll()
    bannerImageView.layer.addSublayer(gradientLayer)
  }
  
  private func setupDefaultAvatar() {
    avatarImageView.image = nil
    avatarImageView.backgroundColor = UIColor.systemGray4
  }
  
  @MainActor
  func updateForStretch(stretchAmount: CGFloat) {
    let clampedStretch = max(0, stretchAmount)
    
    guard clampedStretch != lastStretchAmount else { return }
    lastStretchAmount = clampedStretch
    
    let newHeight = originalHeight + clampedStretch
    bannerHeightConstraint.constant = newHeight
    
    let scaleMultiplier: CGFloat = 0.08
    let maxScale: CGFloat = 1.15
    let scale = min(1 + (clampedStretch / originalHeight) * scaleMultiplier, maxScale)
    
    let overlayAlpha = min(clampedStretch / 150, 0.2)
    
    UIView.performWithoutAnimation {
      bannerImageView.transform = CGAffineTransform(scaleX: scale, y: scale)
      bannerOverlayView.alpha = overlayAlpha
      
      avatarBottomConstraint.constant = (avatarSize / 2) - (clampedStretch * 0.3)
      
      self.layoutIfNeeded()
    }
    
    if clampedStretch > 10 {
      logger.debug("Stretch update: amount=\(clampedStretch, privacy: .public), scale=\(scale, privacy: .public)")
    }
  }
  
  @MainActor
  func resetStretch() {
    guard lastStretchAmount != 0 else { return }
    
    lastStretchAmount = 0
    bannerHeightConstraint.constant = originalHeight
    
    UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2) {
      self.bannerImageView.transform = .identity
      self.bannerOverlayView.alpha = 0
      self.avatarBottomConstraint.constant = self.avatarSize / 2
      self.layoutIfNeeded()
    }
  }
  
  override func prepareForReuse() {
    super.prepareForReuse()
    
    bannerImageView.image = nil
    avatarImageView.image = nil
    bannerImageView.layer.sublayers?.removeAll()
    
    resetStretch()
    currentProfile = nil
  }
}
