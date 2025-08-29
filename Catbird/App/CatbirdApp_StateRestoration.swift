//
//  CatbirdApp_StateRestoration.swift
//  Catbird
//
//  State restoration extensions for CatbirdApp
//

import Foundation
import SwiftUI
import OSLog

extension CatbirdApp {
  
  // MARK: - State Restoration
  
  @MainActor
  func restoreApplicationState() async {
    guard !hasRestoredState else { return }
    hasRestoredState = true
    
    logger.info("🔄 Starting application state restoration")
    
    do {
      // Restore user defaults state (now async)
      await restoreUserDefaultsState()
      
      // Wait for app state to be properly initialized
      var attempts = 0
      while !appState.isAuthenticated && attempts < 10 {
        try await Task.sleep(for: .milliseconds(100))
        attempts += 1
      }
      
      // Restore navigation state if authenticated
      if appState.isAuthenticated {
        await restoreNavigationState()
        await restoreFeedState()
      }
      
      logger.info("✅ Application state restoration completed")
    } catch {
      logger.error("❌ Error during state restoration: \(error.localizedDescription)")
    }
  }
  
  @MainActor
  func restoreUserDefaultsState() async {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? UserDefaults.standard
    
    // Restore biometric settings
    if let biometricEnabled = defaults.object(forKey: "biometric_auth_enabled") as? Bool {
      await appState.authManager.setBiometricAuthEnabled(biometricEnabled)
      logger.debug("Restored biometric auth setting: \(biometricEnabled)")
    }
    
    // Restore adult content setting
    if let adultContentEnabled = defaults.object(forKey: "isAdultContentEnabled") as? Bool {
      appState.isAdultContentEnabled = adultContentEnabled
      logger.debug("Restored adult content setting: \(adultContentEnabled)")
    }
    
    logger.debug("User defaults state restored")
  }
  
  @MainActor
  func restoreNavigationState() async {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? UserDefaults.standard
    
    // Restore last selected tab
    let lastTab = defaults.integer(forKey: "last_selected_tab")
    if lastTab >= 0 && lastTab <= 4 {
      // Update navigation manager with restored tab
      appState.navigationManager.updateCurrentTab(lastTab)
      logger.debug("Restored last selected tab: \(lastTab)")
    }
    
    // Restore drawer state for home tab
    let wasDrawerOpen = defaults.bool(forKey: "drawer_was_open")
    if wasDrawerOpen && lastTab == 0 {
      // Store drawer open state for restoration in ContentView
      defaults.set(true, forKey: "should_restore_drawer_open")
      logger.debug("Marked drawer for restoration")
    }
    
    logger.debug("Navigation state restoration prepared")
  }
  
  @MainActor
  func restoreFeedState() async {
    // Feed state restoration is handled by FeedStateStore and PersistentFeedStateManager
    // This just triggers the restoration process
    logger.debug("Feed state restoration delegated to FeedStateStore")
  }
  
  // MARK: - State Saving
  
  @MainActor
  func saveApplicationState() {
    let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? UserDefaults.standard
    
    // Save current navigation state
    let currentTab = appState.navigationManager.currentTabIndex
    defaults.set(currentTab, forKey: "last_selected_tab")
    
    // Save biometric settings
    defaults.set(appState.authManager.biometricAuthEnabled, forKey: "biometric_auth_enabled")
    
    // Save adult content setting
    defaults.set(appState.isAdultContentEnabled, forKey: "isAdultContentEnabled")
    
    logger.debug("Application state saved - tab: \(currentTab)")
  }
}
