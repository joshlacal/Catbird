import Foundation
import SwiftUI

// MARK: - Onboarding Models

/// Represents different types of onboarding content
enum OnboardingContentType {
  case welcome
  case feedDiscovery
  case postCreation
  case profileSetup
  case searchTips
  case chatIntro
}

/// Model for an individual onboarding step
struct OnboardingStep {
  let id: String
  let type: OnboardingContentType
  let title: String
  let description: String
  let imageName: String?
  let primaryButtonTitle: String
  let secondaryButtonTitle: String?
  let showSkipButton: Bool
}

/// Onboarding content definitions
struct OnboardingContent {
  
  /// Welcome screen content for new Catbird users
  static let welcome = OnboardingStep(
    id: "welcome",
    type: .welcome,
    title: "Welcome to Catbird",
    description: "A native Bluesky client for Apple platforms. Catbird makes it easy to connect with friends, discover new voices, and join conversations that matter to you.",
    imageName: "CatbirdIcon",
    primaryButtonTitle: "Get Started",
    secondaryButtonTitle: nil,
    showSkipButton: false
  )
  
  /// Feed discovery help
  static let feedDiscovery = OnboardingStep(
    id: "feedDiscovery",
    type: .feedDiscovery,
    title: "Discover Custom Feeds",
    description: "Bluesky's custom feeds let you see exactly what you want. Tap the + button to explore feeds curated by the community.",
    imageName: "plus.circle.fill",
    primaryButtonTitle: "Got it",
    secondaryButtonTitle: nil,
    showSkipButton: true
  )
  
  /// Post creation tutorial
  static let postCreation = OnboardingStep(
    id: "postCreation",
    type: .postCreation,
    title: "Share Your Thoughts",
    description: "Ready to post? Tap the compose button to share text, photos, or start a conversation. You can also reply to posts and join discussions.",
    imageName: "square.and.pencil",
    primaryButtonTitle: "Got it",
    secondaryButtonTitle: nil,
    showSkipButton: true
  )
  
  /// Profile setup reminder
  static let profileSetup = OnboardingStep(
    id: "profileSetup",
    type: .profileSetup,
    title: "Complete Your Profile",
    description: "Add a profile picture, bio, and banner to help others discover and connect with you. A complete profile gets more engagement!",
    imageName: "person.circle.fill",
    primaryButtonTitle: "Set Up Profile",
    secondaryButtonTitle: "Maybe Later",
    showSkipButton: true
  )
}

/// Tip overlay model for contextual hints
struct OnboardingTip {
  let id: String
  let title: String
  let message: String
  let targetView: String
  let position: TipPosition
  let showArrow: Bool
}

/// Position for tip overlays
enum TipPosition {
  case top
  case bottom
  case leading
  case trailing
  case center
}

/// Predefined tips for different app areas
struct OnboardingTips {
  
  static let feedDiscovery = OnboardingTip(
    id: "feedDiscovery",
    title: "Discover Feeds",
    message: "Tap + to explore custom feeds created by the community",
    targetView: "addFeedButton",
    position: .bottom,
    showArrow: true
  )
  
  static let composePost = OnboardingTip(
    id: "composePost",
    title: "Create Your First Post",
    message: "Share your thoughts with the world",
    targetView: "composeButton",
    position: .top,
    showArrow: true
  )
  
  static let profileCompletion = OnboardingTip(
    id: "profileCompletion",
    title: "Complete Your Profile",
    message: "Add a photo and bio to help others connect with you",
    targetView: "profileTab",
    position: .top,
    showArrow: true
  )
}
