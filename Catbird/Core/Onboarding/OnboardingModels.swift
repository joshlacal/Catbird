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
  static var welcome: OnboardingStep {
    OnboardingStep(
      id: "welcome",
      type: .welcome,
      title: String(localized: "Welcome to Catbird", comment: "Onboarding welcome screen title."),
      description: String(
        localized: "A native Bluesky client for Apple platforms. Catbird makes it easy to connect with friends, discover new voices, and join conversations that matter to you.",
        comment: "Onboarding welcome screen description."
      ),
      imageName: "CatbirdIcon",
      primaryButtonTitle: String(localized: "Get Started", comment: "Primary action button on onboarding welcome screen."),
      secondaryButtonTitle: nil,
      showSkipButton: false
    )
  }
  
  /// Feed discovery help
  static var feedDiscovery: OnboardingStep {
    OnboardingStep(
      id: "feedDiscovery",
      type: .feedDiscovery,
      title: String(localized: "Discover Custom Feeds", comment: "Onboarding step title for discovering custom feeds."),
      description: String(
        localized: "Bluesky's custom feeds let you see exactly what you want. Tap Add Feed to explore feeds curated by the community.",
        comment: "Onboarding step description explaining Bluesky custom feeds."
      ),
      imageName: "plus.circle.fill",
      primaryButtonTitle: String(localized: "Got it", comment: "Button dismissing an onboarding help step."),
      secondaryButtonTitle: nil,
      showSkipButton: true
    )
  }
  
  /// Post creation tutorial
  static var postCreation: OnboardingStep {
    OnboardingStep(
      id: "postCreation",
      type: .postCreation,
      title: String(localized: "Share Your Thoughts", comment: "Onboarding step title for creating posts."),
      description: String(
        localized: "Ready to post? Tap the compose button to share text, photos, or start a conversation. You can also reply to posts and join discussions.",
        comment: "Onboarding step description explaining how to compose posts."
      ),
      imageName: "square.and.pencil",
      primaryButtonTitle: String(localized: "Got it", comment: "Button dismissing an onboarding help step."),
      secondaryButtonTitle: nil,
      showSkipButton: true
    )
  }
  
  /// Profile setup reminder
  static var profileSetup: OnboardingStep {
    OnboardingStep(
      id: "profileSetup",
      type: .profileSetup,
      title: String(localized: "Complete Your Profile", comment: "Onboarding step title reminding user to set up their profile."),
      description: String(
        localized: "Add a profile picture, bio, and banner to help others discover and connect with you. A complete profile gets more engagement!",
        comment: "Onboarding step description encouraging profile completion."
      ),
      imageName: "person.circle.fill",
      primaryButtonTitle: String(localized: "Set Up Profile", comment: "Button to begin profile setup from onboarding."),
      secondaryButtonTitle: String(localized: "Maybe Later", comment: "Secondary button to defer profile setup."),
      showSkipButton: true
    )
  }
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
  
  static var feedDiscovery: OnboardingTip {
    OnboardingTip(
      id: "feedDiscovery",
      title: String(localized: "Discover Feeds", comment: "Contextual tip title for feed discovery."),
      message: String(localized: "Tap + to explore custom feeds created by the community", comment: "Contextual tip message for adding feeds."),
      targetView: "addFeedButton",
      position: .bottom,
      showArrow: true
    )
  }
  
  static var composePost: OnboardingTip {
    OnboardingTip(
      id: "composePost",
      title: String(localized: "Create Your First Post", comment: "Contextual tip title for composing a post."),
      message: String(localized: "Share your thoughts with the world", comment: "Contextual tip message for composing a post."),
      targetView: "composeButton",
      position: .top,
      showArrow: true
    )
  }
  
  static var profileCompletion: OnboardingTip {
    OnboardingTip(
      id: "profileCompletion",
      title: String(localized: "Complete Your Profile", comment: "Contextual tip title for completing profile."),
      message: String(localized: "Add a photo and bio to help others connect with you", comment: "Contextual tip message for completing profile."),
      targetView: "profileTab",
      position: .top,
      showArrow: true
    )
  }
}

/// Interactive onboarding wizard steps
public enum OnboardingFlowStep: Int, CaseIterable, Identifiable, Sendable {
  case avatar = 0
  case interests = 1
  case suggestedAccounts = 2
  case finish = 3
  
  public var id: Int { rawValue }
  
  public var title: String {
    switch self {
    case .avatar: return String(localized: "Your Profile", comment: "Onboarding wizard step title for profile avatar.")
    case .interests: return String(localized: "Your Interests", comment: "Onboarding wizard step title for choosing interests.")
    case .suggestedAccounts: return String(localized: "Suggested Accounts", comment: "Onboarding wizard step title for suggested accounts.")
    case .finish: return String(localized: "You’re All Set", comment: "Onboarding wizard final step title.")
    }
  }
  
  public var subtitle: String {
    switch self {
    case .avatar: return String(localized: "Choose a photo or build an avatar to help others find you.", comment: "Onboarding wizard avatar step subtitle.")
    case .interests: return String(localized: "Select topics you care about to personalize your experience.", comment: "Onboarding wizard interests step subtitle.")
    case .suggestedAccounts: return String(localized: "Follow interesting people to kickstart your timeline.", comment: "Onboarding wizard suggested accounts step subtitle.")
    case .finish: return String(localized: "Catbird is ready for you. Let’s dive in.", comment: "Onboarding wizard final step subtitle.")
    }
  }
}
