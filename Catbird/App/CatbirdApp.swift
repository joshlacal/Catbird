import AVFoundation
import CoreText
import OSLog
import Petrel
import Security
import SwiftData
import SwiftUI
import TipKit
import UIKit
import UserNotifications
import WidgetKit
import Darwin // For sysctl constants

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
      // FaultOrdering debugging and setup for physical devices
      print("🔍 App launched with environment:")
      for (key, value) in ProcessInfo.processInfo.environment {
        if key.contains("FAULT") || key.contains("RUN_") || key.contains("DYLD") || key.contains("XCTest") {
          print("  \(key) = \(value)")
        }
      }
      
      // CRITICAL FOR PHYSICAL DEVICE: Force set environment variables if in test environment
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        print("🧪 Running in XCTest environment - checking for FaultOrdering flags")
        
        // Only set FaultOrdering variables if explicitly requested
        if ProcessInfo.processInfo.environment["ENABLE_FAULT_ORDERING"] == "1" {
          print("✅ FaultOrdering explicitly enabled via ENABLE_FAULT_ORDERING")
          
          // Force set the environment variables that FaultOrdering needs
          setenv("RUN_FAULT_ORDER", "1", 1)
          setenv("RUN_FAULT_ORDER_SETUP", "1", 1)
          setenv("FAULT_ORDERING_ENABLE", "1", 1)
          
          // Verify they were set
          if let runFaultOrder = getenv("RUN_FAULT_ORDER") {
            print("✅ RUN_FAULT_ORDER set to: \(String(cString: runFaultOrder))")
          }
          if let runFaultOrderSetup = getenv("RUN_FAULT_ORDER_SETUP") {
            print("✅ RUN_FAULT_ORDER_SETUP set to: \(String(cString: runFaultOrderSetup))")
          }
        } else {
          print("⚠️ FaultOrdering not enabled - set ENABLE_FAULT_ORDERING=1 to activate")
        }
      }
      
      // Check if FaultOrdering framework is loaded
      if ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" || 
         ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        print("🔍 FaultOrdering mode detected in AppDelegate")
        
        // Check if debugger is attached (this is what FaultOrdering checks)
        var info = kinfo_proc()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, 4, &info, &size, nil, 0)
        let debuggerAttached = (result == 0) && (info.kp_proc.p_flag & P_TRACED) != 0
        print("🔍 Debugger attached: \(debuggerAttached)")
        
        // For physical devices, the debugger might not be attached in the traditional sense
        if !debuggerAttached {
          print("⚠️ Debugger not attached - FaultOrdering may not work correctly")
        }
      }
      
      // Request widget updates at app launch
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
        guard let self = self, let appState = self.appState else { return }
        // Force widget to refresh
        WidgetCenter.shared.reloadAllTimelines()
        logger.info("🔄 Requested widget refresh at app launch")
      }
      
      // Tell UIKit that state restoration setup is complete
      application.completeStateRestoration()
      
      return true
    }

    func application(
      _ application: UIApplication, 
      shouldSaveApplicationState coder: NSCoder
    ) -> Bool {
      // Enable state saving - always save unless in testing mode
      let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      logger.debug("State restoration: shouldSaveApplicationState = \(!isTesting)")
      return !isTesting
    }

    func application(
      _ application: UIApplication, 
      shouldRestoreApplicationState coder: NSCoder
    ) -> Bool {
      // Enable state restoration - always restore unless in testing mode
      let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
      logger.debug("State restoration: shouldRestoreApplicationState = \(!isTesting)")
      return !isTesting
    }

    func application(
      _ application: UIApplication,
      viewControllerWithRestorationIdentifierPath identifierComponents: [String],
      coder: NSCoder
    ) -> UIViewController? {
      // Let view controllers handle their own restoration
      logger.debug("State restoration: viewControllerWithRestorationIdentifierPath = \(identifierComponents)")
      return nil
    }

    func application(
      _ application: UIApplication,
      didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
      // Forward the device token to our notification manager
      guard let appState = self.appState else { return }

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
  // Use singleton AppState to prevent multiple instances
  private let appState = AppState.shared
  @State private var didInitialize = false
  @State private var isAuthenticatedWithBiometric = false
  @State private var showBiometricPrompt = false
  @State private var hasBiometricCheck = false

  // MARK: - SwiftData
  let modelContainer: ModelContainer

  @Environment(\.modelContext) private var modelContext
  @Environment(\.scenePhase) private var scenePhase

  // App delegate instance
  @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

  // MARK: - Initialization
  init() {
    logger.info("🚀 CatbirdApp initializing")

    // Fast path for FaultOrdering tests - skip expensive initialization
    let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
                              ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
                              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    
    if isFaultOrderingMode {
      logger.info("⚡ FaultOrdering mode detected - using fast initialization")
      // Force set environment for FaultOrdering on physical device
      setenv("FAULT_ORDERING_ENABLE", "1", 1)
    } else {
      // MARK: - Navigation Bar Configuration
      // Navigation bar theme is handled completely by ThemeManager during AppState.initialize()
      // to avoid conflicts between initial setup and dynamic theme changes

      // Configure audio session at app launch
      do {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        logger.debug("✅ Audio session configured at app launch")
      } catch {
        logger.error("❌ Failed to configure audio session: \(error)")
      }
    }

    // Initialize model container with error recovery (simplified for FaultOrdering)
    do {
      guard let appDocumentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
        throw NSError(domain: "CatbirdApp", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to access documents directory"])
      }
      let storeURL = appDocumentsURL.appendingPathComponent("Catbird.sqlite")
      
      if isFaultOrderingMode {
        // Minimal model container for FaultOrdering - only essential models
        self.modelContainer = try ModelContainer(
          for: Preferences.self, AppSettingsModel.self,
          configurations: ModelConfiguration("Catbird", schema: nil, url: storeURL)
        )
        logger.debug("✅ Minimal model container initialized for FaultOrdering")
      } else {
        // Full model container for normal use
        self.modelContainer = try ModelContainer(
          for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,               configurations: ModelConfiguration("Catbird", schema: nil, url: storeURL)
        )
        logger.debug("✅ Model container initialized successfully")
      }
    } catch {
      logger.error("❌ Could not initialize ModelContainer: \(error)")
      
      if isFaultOrderingMode {
        // For FaultOrdering, use in-memory store if file fails
        self.modelContainer = try! ModelContainer(
          for: Preferences.self, AppSettingsModel.self,
          configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
        )
        logger.debug("✅ In-memory model container created for FaultOrdering")
      } else {
        // Try to recover by deleting corrupted database
        let fileManager = FileManager.default
        guard let appDocumentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
          // Fallback to in-memory storage if documents directory is inaccessible
          logger.warning("⚠️ Documents directory inaccessible, using in-memory storage")
          self.modelContainer = try! ModelContainer(
            for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,             RepositoryRecord.self, ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self, ParsedConnection.self, ParsedMedia.self, ParsedUnknownRecord.self,
            configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
          )
          return
        }
        
        let dbURL = appDocumentsURL.appendingPathComponent("Catbird.sqlite")
        
        if fileManager.fileExists(atPath: dbURL.path) {
          do {
            try fileManager.removeItem(at: dbURL)
            logger.info("🔄 Removed corrupted database, attempting recreate")
            
            // Retry initialization
            self.modelContainer = try ModelContainer(
              for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,               // 🧪 EXPERIMENTAL: Repository parsing models
              RepositoryRecord.self, ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self, ParsedConnection.self, ParsedMedia.self, ParsedUnknownRecord.self,
              configurations: ModelConfiguration("Catbird", schema: nil, url: dbURL)
            )
            logger.debug("✅ Model container recreated successfully after recovery")
          } catch {
            logger.error("❌ Failed to recover database: \(error)")
            // Fallback to in-memory storage instead of crashing
            logger.warning("⚠️ Using in-memory storage as final fallback")
            self.modelContainer = try! ModelContainer(
              for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,               RepositoryRecord.self, ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self, ParsedConnection.self, ParsedMedia.self, ParsedUnknownRecord.self,
              configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
            )
          }
        } else {
          // Fallback to in-memory storage instead of crashing
          logger.warning("⚠️ Using in-memory storage as fallback")
          self.modelContainer = try! ModelContainer(
            for: CachedFeedViewPost.self, Preferences.self, AppSettingsModel.self,             RepositoryRecord.self, ParsedATProtocolRecord.self, ParsedPost.self, ParsedProfile.self, ParsedConnection.self, ParsedMedia.self, ParsedUnknownRecord.self,
            configurations: ModelConfiguration("Catbird", isStoredInMemoryOnly: true)
          )
        }
      }
    }

    // Initialize debug tools in development builds (skip for FaultOrdering)
    #if DEBUG
      if !isFaultOrderingMode {
        setupDebugTools()
      }
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
      // Only show content after biometric check is complete or not needed
      Group {
        if shouldShowContent {
          ContentView()
        } else {
          // Show loading screen while biometric check is pending
          LoadingView()
        }
      }
      .onAppear {
        // Set app state reference in app delegate
        appDelegate.appState = appState

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first,
          let rootVC = window.rootViewController {
          appState.urlHandler.registerTopViewController(rootVC)
          
          // Configure window for state restoration
          window.restorationIdentifier = "MainWindow"
        }
        
        // Setup background notification observer
        setupBackgroundNotification()
        
        // Initialize FeedStateStore with model context for persistence
        Task { @MainActor in
          FeedStateStore.shared.setModelContext(modelContext)
        }
      }
      .environment(appState)
      .modelContainer(modelContainer)
      // Monitor scene phase for feed state persistence
      .onChange(of: scenePhase) { oldPhase, newPhase in
        Task { @MainActor in
          await FeedStateStore.shared.handleScenePhaseChange(newPhase)
        }
      }
      // Handle biometric authentication when app becomes active
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
        Task {
          await performInitialBiometricCheck()
        }
      }
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
        
        // Special handling for FaultOrdering measurement phase
        let isFaultOrderingMode = ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] == "1" ||
                                  ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] == "1" ||
                                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                                  
        if isFaultOrderingMode {
          logger.info("⚡ FaultOrdering measurement mode detected - initializing measurement server")
          
          // Force set environment variables for physical device
          setenv("FAULT_ORDERING_ENABLE", "1", 1)
          
          // Debug environment variables
          logger.info("🔍 FaultOrdering debugging:")
          logger.info("FAULT_ORDERING_ENABLE: \(ProcessInfo.processInfo.environment["FAULT_ORDERING_ENABLE"] ?? "not set")")
          logger.info("RUN_FAULT_ORDER: \(ProcessInfo.processInfo.environment["RUN_FAULT_ORDER"] ?? "not set")")
          logger.info("XCTestConfigurationFilePath: \(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] ?? "not set")")
          logger.info("DYLD_INSERT_LIBRARIES: \(ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "not set")")
          
          // Check if we're on a physical device
          #if targetEnvironment(simulator)
          logger.info("💻 Running on simulator")
          #else
          logger.info("📱 Running on physical device")
          #endif
          
          // Check Documents directory for linkmap
          if let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let linkmapURL = documentsURL.appendingPathComponent("linkmap-addresses.json")
            let exists = FileManager.default.fileExists(atPath: linkmapURL.path)
            logger.info("🔍 Linkmap file exists at \(linkmapURL.path): \(exists)")
          }
          
          // Keep app alive for FaultOrdering measurement server
          // The FaultOrdering framework initializes itself when the environment is set
          Task.detached(priority: .high) {
            logger.info("⚡ Starting keep-alive task for FaultOrdering measurement")
            
            // Keep the app process alive during measurement
            while !Task.isCancelled {
              try? await Task.sleep(for: .seconds(1))
              // This prevents the app from being suspended during measurement
            }
          }
          
          // Additional background task to prevent app suspension
          Task.detached(priority: .background) {
            while !Task.isCancelled {
              try? await Task.sleep(for: .seconds(5))
              logger.debug("🔄 FaultOrdering keep-alive ping")
            }
          }
        }

        // Configure TipKit for onboarding tips (skip for FaultOrdering)
        if !isFaultOrderingMode {
          #if DEBUG
            // Reset tips in debug builds for testing
            try? Tips.resetDatastore()
          #endif
          
          // Configure TipKit with production settings
          try? Tips.configure([
            .displayFrequency(.immediate),
            .datastoreLocation(.applicationDefault)
          ])
        }
        
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
        
        // Check biometric authentication on app launch
        await performInitialBiometricCheck()

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
        .overlay {
          if showBiometricPrompt && !isAuthenticatedWithBiometric {
            BiometricAuthenticationOverlay(
              isAuthenticated: $isAuthenticatedWithBiometric,
              authManager: appState.authManager
            )
          }
        }
    }
  }
  
  // MARK: - Content Display Logic
  private var shouldShowContent: Bool {
    // Only show content if:
    // 1. Biometric check has been performed, AND
    // 2. Either biometric auth is disabled OR user has been authenticated
    return hasBiometricCheck && (!appState.authManager.biometricAuthEnabled || isAuthenticatedWithBiometric)
  }
  
  // MARK: - Loading View
  struct LoadingView: View {
    var body: some View {
      VStack(spacing: 20) {
        // App icon
        Image("CatbirdIcon")
          .resizable()
          .frame(width: 80, height: 80)
          .cornerRadius(16)
        
        ProgressView()
          .scaleEffect(1.5)
        
        Text("Loading...")
          .font(.headline)
          .foregroundColor(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(.systemBackground))
    }
  }
  
  // MARK: - Biometric Authentication
  private func performInitialBiometricCheck() async {
    // Perform biometric check first
    await checkBiometricAuthentication()
    
    // Mark that biometric check has been performed
    await MainActor.run {
      hasBiometricCheck = true
    }
  }
  
  private func checkBiometricAuthentication() async {
    // Check if biometric auth is enabled and we haven't authenticated yet
    guard appState.authManager.biometricAuthEnabled,
          !isAuthenticatedWithBiometric else {
      return
    }
    
    await MainActor.run {
      showBiometricPrompt = true
    }
  }
  
  // Reset authentication when app goes to background
  private func setupBackgroundNotification() {
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { _ in
      // Reset authentication state when app enters background
      self.isAuthenticatedWithBiometric = false
      // Reset biometric check to require re-authentication on foreground
      self.hasBiometricCheck = false
    }
  }
}

// MARK: - Biometric Authentication Overlay
struct BiometricAuthenticationOverlay: View {
  @Binding var isAuthenticated: Bool
  let authManager: AuthenticationManager
  @State private var isAuthenticating = false
  
  var body: some View {
    ZStack {
      // Full screen background
      Color.black
        .ignoresSafeArea()
      
      VStack(spacing: 30) {
        // App icon
        Image("CatbirdIcon")
          .resizable()
          .frame(width: 80, height: 80)
          .cornerRadius(16)
        
        Text("Catbird Locked")
          .font(.largeTitle)
          .fontWeight(.bold)
          .foregroundColor(.white)
        
        Text("Authenticate to continue")
          .font(.subheadline)
          .foregroundColor(.gray)
        
        if isAuthenticating {
          ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
        } else {
          Button {
            Task {
              await authenticateWithBiometrics()
            }
          } label: {
            Label("Unlock with \(authManager.biometricType.displayName)", systemImage: biometricIcon)
              .font(.headline)
              .foregroundColor(.white)
              .padding()
              .background(Color.blue)
              .cornerRadius(10)
          }
        }
      }
    }
    .task {
      // Automatically prompt for biometric authentication when view appears
      await authenticateWithBiometrics()
    }
  }
  
  private var biometricIcon: String {
    switch authManager.biometricType {
    case .faceID:
      return "faceid"
    case .touchID:
      return "touchid"
    case .opticID:
      return "opticid"
    default:
      return "lock.shield"
    }
  }
  
  private func authenticateWithBiometrics() async {
    await MainActor.run {
      isAuthenticating = true
    }
    
    let success = await authManager.quickAuthenticationCheck()
    
    await MainActor.run {
      isAuthenticating = false
      if success {
        isAuthenticated = true
      }
    }
  }
}
