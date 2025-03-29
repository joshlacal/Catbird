import AVFoundation
import OSLog
import Petrel
import Security
import SwiftData
import SwiftUI
import UIKit
import UserNotifications

// App-wide logger
private let logger = Logger(subsystem: "blue.catbird", category: "AppLifecycle")

@main
struct CatbirdApp: App {
  // MARK: - App Delegate for UIKit callbacks
  private class AppDelegate: NSObject, UIApplicationDelegate {
    var appState: AppState?
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
      // Forward the device token to our notification manager
      guard let appState = appState else { return }
      
      Task {
        await appState.notificationManager.handleDeviceToken(deviceToken)
      }
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
      let logger = Logger(subsystem: "blue.catbird", category: "AppDelegate")
      logger.error("Failed to register for remote notifications: \(error.localizedDescription)")
    }
  }
  // MARK: - State
  @State private var appState = AppState()
  @State private var didInitialize = false

  // MARK: - SwiftData
  let modelContainer: ModelContainer

  @Environment(\.modelContext) private var modelContext

  // App delegate instance
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
  
  // MARK: - Initialization
  init() {
    logger.info("🚀 CatbirdApp initializing")

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
        for: CachedFeedViewPost.self, Preferences.self,
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
            let rootVC = window.rootViewController
          {
            appState.urlHandler.registerTopViewController(rootVC)
          }
        }
        .environment(appState)
        .modelContainer(modelContainer)
        // Initialize app state when the app launches
        .task {

          // Only run the initialization process once
          guard !didInitialize else { return }

          // Mark as initialized immediately to prevent duplicate initialization
          didInitialize = true

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
            "Post-initialization auth check completed: \(String(describing:appState.authState))")

          // Initialize preferences manager with modelContext
          appState.initializePreferencesManager(with: modelContext)

          // Only fix timeline feed issues when needed
          Task {
            do {
              if let prefs = try await appState.preferencesManager.loadPreferences(),
                !prefs.pinnedFeeds.contains(where: { SystemFeedTypes.isTimelineFeed($0) })
              {
//                try await appState.preferencesManager.fixTimelineFeedIssue()
              }
            } catch {
              logger.error("Error checking timeline feed: \(error)")
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
          } else {
            // Handle all other URLs through the URLHandler
            _ = appState.urlHandler.handle(url)
          }
        }
    }
  }
}
