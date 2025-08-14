import Foundation
import OSLog
import SwiftUI
import TipKit

/// Manages user onboarding state and progress tracking
@Observable
final class OnboardingManager {
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "blue.catbird", category: "OnboardingManager")
  
  // Onboarding completion states
  var hasCompletedWelcome: Bool = false
  var hasSeenSettingsTip: Bool = false
  
  // Control visibility of welcome sheet
  var showWelcomeSheet: Bool = false
  
  // TipKit instance
  let settingsAccessTip = SettingsAccessTip()
  
  // UserDefaults keys for persistence
  private enum UserDefaultsKeys {
    static let hasCompletedWelcome = "onboarding.hasCompletedWelcome"
    static let hasSeenSettingsTip = "onboarding.hasSeenSettingsTip"
    static let onboardingVersion = "onboarding.version"
  }
  
  // Current onboarding version - increment when adding new flows
  private let currentOnboardingVersion = 1
  
  // MARK: - Initialization
  
  init() {
    loadOnboardingState()
    logger.debug("OnboardingManager initialized")
  }
  
  // MARK: - State Management
  
  /// Load onboarding state from UserDefaults and sync with TipKit
  private func loadOnboardingState() {
    let defaults = UserDefaults.standard
    
    // Check if user needs to see new onboarding due to version update
    let savedVersion = defaults.integer(forKey: UserDefaultsKeys.onboardingVersion)
    if savedVersion < self.currentOnboardingVersion {
      logger.info("Onboarding version updated from \(savedVersion) to \(self.currentOnboardingVersion)")
      // Reset certain onboarding states for new features
      resetOnboardingForNewVersion()
    }
    
    self.hasCompletedWelcome = defaults.bool(forKey: UserDefaultsKeys.hasCompletedWelcome)
    self.hasSeenSettingsTip = defaults.bool(forKey: UserDefaultsKeys.hasSeenSettingsTip)
    
    // Invalidate tip if already seen
    Task {
      if self.hasSeenSettingsTip {
        self.settingsAccessTip.invalidate(reason: .actionPerformed)
      }
    }
    
    logger.debug("Loaded onboarding state - welcome: \(self.hasCompletedWelcome), settings: \(self.hasSeenSettingsTip)")
  }
  
  /// Save onboarding state to UserDefaults
  private func saveOnboardingState() {
    let defaults = UserDefaults.standard
    
    defaults.set(self.hasCompletedWelcome, forKey: UserDefaultsKeys.hasCompletedWelcome)
    defaults.set(self.hasSeenSettingsTip, forKey: UserDefaultsKeys.hasSeenSettingsTip)
    defaults.set(self.currentOnboardingVersion, forKey: UserDefaultsKeys.onboardingVersion)
    
    logger.debug("Saved onboarding state")
  }
  
  /// Reset onboarding state for new app version
  private func resetOnboardingForNewVersion() {
    // For future version updates, selectively reset onboarding states
    // Currently just update the version number
    UserDefaults.standard.set(self.currentOnboardingVersion, forKey: UserDefaultsKeys.onboardingVersion)
  }
  
  // MARK: - Onboarding Actions
  
  /// Check if user should see welcome onboarding after first successful login
  @MainActor
  func checkForWelcomeOnboarding(isFirstLogin: Bool = false) {
    if (!hasCompletedWelcome || isFirstLogin) && !showWelcomeSheet {
      logger.info("Showing welcome onboarding for new user")
      showWelcomeSheet = true
    }
  }
  
  /// Mark welcome onboarding as completed
  @MainActor
  func completeWelcomeOnboarding() {
    hasCompletedWelcome = true
    showWelcomeSheet = false
    saveOnboardingState()
    logger.info("Welcome onboarding completed")
  }
  
  /// Mark settings tip as seen and invalidate TipKit tip
  @MainActor
  func markSettingsTipAsSeen() {
    hasSeenSettingsTip = true
    saveOnboardingState()
    
    Task {
    settingsAccessTip.invalidate(reason: .actionPerformed)
    }
    
    logger.info("Settings tip marked as seen")
  }
  
  // MARK: - Utility Methods
  
  /// Reset all onboarding state (for testing or "show tips again" feature)
  @MainActor
  func resetAllOnboarding() {
    hasCompletedWelcome = false
    hasSeenSettingsTip = false
    
    // Hide any currently showing onboarding
    showWelcomeSheet = false
    
    saveOnboardingState()
    
    // Reset TipKit tips to make them eligible to show again
    Task {
      try? Tips.resetDatastore()
      logger.info("TipKit datastore reset")
    }
    
    logger.info("All onboarding state reset")
  }
  
  /// Force the settings tip to show again (for debugging)
  @MainActor
  func forceShowSettingsTip() {
    hasSeenSettingsTip = false
    saveOnboardingState()
    
    Task {
         settingsAccessTip.invalidate(reason: .actionPerformed)
      logger.info("Settings tip invalidated and reset for debugging")
    }
  }
  
  /// Check if all onboarding has been completed
  var hasCompletedAllOnboarding: Bool {
    return hasCompletedWelcome && hasSeenSettingsTip
  }
}
