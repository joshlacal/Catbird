import AVFoundation
import CoreText
import OSLog
import Petrel
import Security
import SwiftData
import SwiftUI
import UIKit
import UserNotifications
import WidgetKit

// App-wide logger
let logger = Logger(subsystem: "blue.catbird", category: "AppLifecycle")

@main
struct CatbirdApp: App {
  // MARK: - App Delegate for UIKit callbacks
  private class AppDelegate: NSObject, UIApplicationDelegate {
    var appState: AppState?

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      // Request widget updates at app launch
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        guard let self = self, let appState = self.appState else { return }
        // Force widget to refresh
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("🔄 Requested widget refresh at app launch")
      }
      return true
    }

    func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      // Forward the device token to our notification manager
      guard let appState = appState else { return }

      Task {
        await appState.notificationManager.handleDeviceToken(deviceToken)
      }
    }

    func application(
      _ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
      let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
      logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }
  }
  // MARK: - State
  @State private var appState: AppState
  @State private var didInitialize = false

  // MARK: - SwiftData
  let modelContainer: ModelContainer

  @Environment(\.modelContext) private var modelContext

  // App delegate instance
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  // MARK: - Initialization
  init() {
    logger.info("🚀 CatbirdApp initializing")
    
    // Create AppState instance once
    _appState = State(initialValue: AppState())

    // MARK: - Customizing Navigation Bar Fonts with CoreText
    // Note: Initial navigation bar setup is minimal here.
    // The actual theme-specific configuration is done by ThemeManager
    // after app settings are loaded in AppState.initialize()
    
    // Set initial appearance to saved theme colors to avoid black flash
    let initialAppearance = UINavigationBarAppearance()
    initialAppearance.configureWithOpaqueBackground()
    
    // Load saved theme settings from UserDefaults for initial setup
    let defaults = UserDefaults.standard
    let savedTheme = defaults.string(forKey: "theme") ?? "system"
    let savedDarkMode = defaults.string(forKey: "darkThemeMode") ?? "dim"
    
    // Apply appropriate background color based on saved settings
    if savedTheme == "dark" || (savedTheme == "system" && UITraitCollection.current.userInterfaceStyle == .dark) {
      if savedDarkMode == "black" {
        initialAppearance.backgroundColor = UIColor.black
      } else {
        // Use dim theme colors as default
        initialAppearance.backgroundColor = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
      }
    } else {
      // Light mode - use default background
      initialAppearance.configureWithDefaultBackground()
    }
    NavigationFontConfig.applyFonts(to: initialAppearance)
    
    // Set initial appearance that prevents black flash before theme is applied
    UINavigationBar.appearance().standardAppearance = initialAppearance
    UINavigationBar.appearance().scrollEdgeAppearance = initialAppearance
    UINavigationBar.appearance().compactAppearance = initialAppearance

    // Configure audio session at app launch
    do {
      let audioSession = AVAudioSession.sharedInstance()
      try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
      logger.debug("✅ Audio session configured at app launch")
    } catch {
      logger.error("❌ Failed to configure audio session: \(error)")
    }

    // Initialize model container
    do {
      modelContainer = try ModelContainer(
        for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: false)
      )
      logger.debug("✅ Model container initialized successfully")
    } catch {
      logger.error("❌ Could not initialize ModelContainer: \(error)")
      fatalError("Failed to initialize ModelContainer: \(error)")
    }

    // Initialize debug tools in development builds
    #if DEBUG
      setupDebugTools()
    #endif
  }

  // MARK: - Debug Tools Setup

  private func setupDebugTools() {
    // Set up logging tools for tracking blocking issues
    AVAssetPropertyTracker.setupBreakpointTracking()
    DebugMonitor.setupDebuggingRecommendations()

    // Log common debugging steps
    //    logger.info(
    //      """
    //      📊 PreferredTransform tracking enabled.
    //      You can diagnose the issue by:
    //      1. Looking for "PreferredTransform accessed on Main Thread" warnings in console
    //      2. Setting breakpoints as recommended by DebugMonitor
    //      3. Monitoring main thread blocking warnings
    //      """)
  }

  // MARK: - Body
  var body: some Scene {
    WindowGroup {
            ContentView()
        .onAppear {
          // Set app state reference in app delegate
          appDelegate.appState = appState

          if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let window = windowScene.windows.first,
            let rootVC = window.rootViewController {
            appState.urlHandler.registerTopViewController(rootVC)
          }
        }
        .environment(appState)
        .modelContainer(modelContainer)
        // Initialize app state when the app launches
        .task {

          // Only run the initialization process once
          guard !didInitialize else {
            logger.debug("⚠️ Skipping duplicate initialization - already initialized")
            return
          }

          // Mark as initialized immediately to prevent duplicate initialization
          didInitialize = true
          logger.debug("🎯 Starting first-time app initialization")

          // Perform the initialization process
          logger.info("Starting app initialization")
          await appState.initialize()
          logger.info("App initialization completed")

          // Add a small delay before the post-initialization check
          // Using separate try-catch to avoid diagnostic issues
          do {
            try await Task.sleep(for: .seconds(0.5))
          } catch {
            //                        logger.error("Sleep error: \(error)")
          }

          // Final auth state verification
          await appState.authManager.checkAuthenticationState()
          logger.info(
            "Post-initialization auth check completed: \(String(describing: appState.authState))")

          // Initialize preferences manager with modelContext
          appState.initializePreferencesManager(with: modelContext)

          // Only fix timeline feed issues when needed
          Task {
            do {
              if let prefs = try await appState.preferencesManager.loadPreferences(),
                !prefs.pinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) }) {
                //                try await appState.preferencesManager.fixTimelineFeedIssue()
              }
            } catch {
              logger.error("Error checking timeline feed: \(error)")
            }
          }
          
          // Apply saved language preferences
          Task { @MainActor in
            let defaults = UserDefaults(suiteName: "group.blue.catbird.shared")
            if let appLanguage = defaults?.string(forKey: "appLanguage") {
              AppLanguageManager.shared.applyLanguage(appLanguage)
              logger.info("Applied saved language preference: \(appLanguage)")
            }
          }

          // Fix any issues with timeline feeds and preferences
          // Task {
          //   do {
          //              // First fix specific timeline feed issues
          //              try await appState.preferencesManager.fixTimelineFeedIssue()
          //
          //              // Then perform a more comprehensive preferences repair
          //              try await appState.preferencesManager.repairPreferences()

          //              logger.info("Preferences repair completed successfully")
          //   } catch {
          //     logger.error("Error repairing preferences: \(error.localizedDescription)")
          //   }
          // }
        }
        // Handle URL callbacks (e.g. OAuth)
        .onOpenURL { url in
          logger.info("Received URL: \(url.absoluteString)")

          if url.absoluteString.contains("/oauth/callback") {
            Task {
              do {
                try await appState.authManager.handleCallback(url)
                logger.info("OAuth callback handled successfully")
              } catch {
                logger.error("Error handling OAuth callback: \(error)")
              }
            }
          } else if url.scheme == "blue.catbird" && url.host == "notifications" {
            // Handle widget notification deep link
            logger.info("Widget notification deep link received")

            // Instead of using the navigation system, directly set the selected tab
            Task { @MainActor in
              // Access the tab selection mechanism directly
              if let tabSelection = self.appState.navigationManager.tabSelection {
                tabSelection(2)  // Switch to notifications tab (index 2)
              } else {
                // Fallback if no tab selection mechanism is available
                self.appState.navigationManager.updateCurrentTab(2)
              }
            }
          } else {
            // Handle all other URLs through the URLHandler
            _ = appState.urlHandler.handle(url)
          }
        }
    }
  }
}
