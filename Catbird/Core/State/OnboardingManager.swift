import Foundation
import OSLog
import Petrel
import SwiftUI
import TipKit
/// Manages user onboarding state and progress tracking
@Observable
final class OnboardingManager {
  // MARK: - Properties
  
  private let logger = Logger(subsystem: "blue.catbird", category: "OnboardingManager")
  private let defaults: UserDefaults
  
  /// Current account DID scoping this manager instance
  var accountDID: String?
  
  // Onboarding completion states
  var hasCompletedWelcome: Bool = false
  var hasSeenSettingsTip: Bool = false
  
  // Control visibility of welcome sheet
  var showWelcomeSheet: Bool = false
  
  // Signup Queue Gate (G67)
  var isSignupQueued: Bool = false
  var signupQueueState: SignupQueueState?
  // TipKit instance
  let settingsAccessTip = SettingsAccessTip()
  
  // UserDefaults keys for persistence
  private enum UserDefaultsKeys {
    static let hasCompletedWelcome = "onboarding.hasCompletedWelcome"
    static let hasSeenSettingsTip = "onboarding.hasSeenSettingsTip"
    static let onboardingVersion = "onboarding.version"
    static let currentStep = "onboarding.currentStep"
  }
  
  // Current onboarding version - increment when adding new flows
  private let currentOnboardingVersion = 1
  
  // MARK: - Initialization
  
  init(accountDID: String? = nil, userDefaults: UserDefaults = .standard) {
    self.accountDID = accountDID
    self.defaults = userDefaults
    loadOnboardingState()
    logger.debug("OnboardingManager initialized for account: \(accountDID ?? "global")")
  }
  
  // MARK: - Account Configuration
  
  /// Configure manager for a specific account DID
  func configure(accountDID: String) {
    self.accountDID = accountDID
    loadOnboardingState()
  }
  
  /// Helper to generate scoped UserDefaults keys
  func scopedKey(_ key: String, for did: String? = nil) -> String {
    let targetDID = did ?? accountDID
    if let targetDID, !targetDID.isEmpty {
      return "onboarding.\(targetDID).\(key)"
    }
    return key
  }
  
  // MARK: - State Management
  
  /// Load onboarding state from UserDefaults and sync with TipKit
  private func loadOnboardingState() {
    let savedVersion = defaults.integer(forKey: UserDefaultsKeys.onboardingVersion)
    if savedVersion < self.currentOnboardingVersion {
      logger.info("Onboarding version updated from \(savedVersion) to \(self.currentOnboardingVersion)")
      resetOnboardingForNewVersion()
    }
    
    let welcomeKey = scopedKey(UserDefaultsKeys.hasCompletedWelcome)
    self.hasCompletedWelcome = defaults.bool(forKey: welcomeKey)
    self.hasSeenSettingsTip = defaults.bool(forKey: UserDefaultsKeys.hasSeenSettingsTip)
    
    // Invalidate tip if already seen
    Task {
      if self.hasSeenSettingsTip {
        self.settingsAccessTip.invalidate(reason: .actionPerformed)
      }
    }
    
    logger.debug("Loaded onboarding state - welcome: \(self.hasCompletedWelcome), settings: \(self.hasSeenSettingsTip) for account: \(self.accountDID ?? "global")")
  }
  
  /// Save onboarding state to UserDefaults
  private func saveOnboardingState(for did: String? = nil) {
    let welcomeKey = scopedKey(UserDefaultsKeys.hasCompletedWelcome, for: did)
    defaults.set(self.hasCompletedWelcome, forKey: welcomeKey)
    defaults.set(self.hasSeenSettingsTip, forKey: UserDefaultsKeys.hasSeenSettingsTip)
    defaults.set(self.currentOnboardingVersion, forKey: UserDefaultsKeys.onboardingVersion)
    
    logger.debug("Saved onboarding state for account: \(did ?? self.accountDID ?? "global")")
  }
  
  /// Reset onboarding state for new app version
  private func resetOnboardingForNewVersion() {
    defaults.set(self.currentOnboardingVersion, forKey: UserDefaultsKeys.onboardingVersion)
  }
  
  // MARK: - Account Scoped Queries
  
  /// Check if a specific account DID has completed welcome onboarding
  func hasCompletedWelcome(for did: String) -> Bool {
    let key = scopedKey(UserDefaultsKeys.hasCompletedWelcome, for: did)
    return defaults.bool(forKey: key)
  }
  
  /// Set onboarding completion for a specific account DID
  func setCompletedWelcome(_ completed: Bool, for did: String) {
    let key = scopedKey(UserDefaultsKeys.hasCompletedWelcome, for: did)
    defaults.set(completed, forKey: key)
    if accountDID == did || accountDID == nil {
      hasCompletedWelcome = completed
    }
  }
  
  /// Get saved step for an account DID
  func savedStep(for did: String) -> Int {
    let key = scopedKey(UserDefaultsKeys.currentStep, for: did)
    return defaults.integer(forKey: key)
  }
  
  /// Save step progress for an account DID
  func saveStep(_ step: Int, for did: String) {
    let key = scopedKey(UserDefaultsKeys.currentStep, for: did)
    defaults.set(step, forKey: key)
  }
  
  // MARK: - Onboarding Actions
  
  /// Check if user should see welcome onboarding after first successful login
  @MainActor
  func checkForWelcomeOnboarding(for did: String? = nil, isFirstLogin: Bool = false) {
    prepareForCheck(for: did)
    let completed = isWelcomeCompleted(for: did)
    if (isSignupQueued || !completed || isFirstLogin) && !showWelcomeSheet {
      logger.info("Showing welcome onboarding for user: \(did ?? self.accountDID ?? "unknown")")
      showWelcomeSheet = true
    }
  }

  /// Check if user should see welcome onboarding or signup queue gate after first successful login
  @MainActor
  func checkForWelcomeOnboarding(client: ATProtoClient, for did: String? = nil, isFirstLogin: Bool = false) async {
    prepareForCheck(for: did)

    // Check signup queue status first
    if let queueOutput = try? await checkSignupQueue(client: client), !queueOutput.activated {
      logger.info("Account is queued; presenting signup queue gate for user: \(did ?? self.accountDID ?? "unknown")")
      showWelcomeSheet = true
      return
    }

    let completed = isWelcomeCompleted(for: did)
    if (!completed || isFirstLogin) && !showWelcomeSheet {
      logger.info("Showing welcome onboarding for user: \(did ?? self.accountDID ?? "unknown")")
      showWelcomeSheet = true
    }
  }

  @MainActor
  private func prepareForCheck(for did: String?) {
    if let did {
      self.accountDID = did
      loadOnboardingState()
    }
  }

  @MainActor
  private func isWelcomeCompleted(for did: String?) -> Bool {
    if let did {
      return hasCompletedWelcome(for: did)
    }
    return hasCompletedWelcome
  }
  
  /// Mark welcome onboarding as completed
  @MainActor
  func completeWelcomeOnboarding(for did: String? = nil) {
    let targetDID = did ?? accountDID
    hasCompletedWelcome = true
    showWelcomeSheet = false
    
    if let targetDID {
      setCompletedWelcome(true, for: targetDID)
      saveStep(0, for: targetDID)
    } else {
      saveOnboardingState()
    }
    logger.info("Welcome onboarding completed for: \(targetDID ?? "global")")
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
  func resetAllOnboarding(for did: String? = nil) {
    let targetDID = did ?? accountDID
    hasCompletedWelcome = false
    hasSeenSettingsTip = false
    showWelcomeSheet = false
    
    if let targetDID {
      setCompletedWelcome(false, for: targetDID)
      saveStep(0, for: targetDID)
    } else {
      saveOnboardingState()
    }
    
    // Reset TipKit tips to make them eligible to show again
    Task {
      try? Tips.resetDatastore()
      logger.info("TipKit datastore reset")
    }
    
    logger.info("All onboarding state reset for: \(targetDID ?? "global")")
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
  
  // MARK: - Signup Queue Management (G67)
  
  public struct SignupQueueState: Equatable, Sendable {
    public var isQueued: Bool
    public var placeInQueue: Int?
    public var estimatedTimeMs: Int?
    public var lastChecked: Date
    
    public init(
      isQueued: Bool = false,
      placeInQueue: Int? = nil,
      estimatedTimeMs: Int? = nil,
      lastChecked: Date = Date()
    ) {
      self.isQueued = isQueued
      self.placeInQueue = placeInQueue
      self.estimatedTimeMs = estimatedTimeMs
      self.lastChecked = lastChecked
    }
  }
  
  /// Check signup queue status via com.atproto.temp.checkSignupQueue
  @MainActor
  func checkSignupQueue(client: ATProtoClient) async throws -> ComAtprotoTempCheckSignupQueue.Output? {
    let (code, output) = try await client.com.atproto.temp.checkSignupQueue()
    if code == 200, let output {
      if !output.activated {
        self.isSignupQueued = true
        self.signupQueueState = SignupQueueState(
          isQueued: true,
          placeInQueue: max(1, output.placeInQueue ?? 1),
          estimatedTimeMs: output.estimatedTimeMs,
          lastChecked: Date()
        )
      } else {
        self.isSignupQueued = false
        self.signupQueueState = nil
      }
      return output
    }
    return nil
  }
}
