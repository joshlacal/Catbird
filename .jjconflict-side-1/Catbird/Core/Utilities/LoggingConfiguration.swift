import Foundation
import OSLog

/// Centralized logging configuration for Catbird
/// Provides standardized OSLog categories for consistent debugging across the app
extension OSLog {
  // MARK: - Subsystem
  
  /// Common subsystem identifier for all Catbird logs
  static let subsystem = "blue.catbird"
  
  // MARK: - Core System Categories
  
  /// App state management and lifecycle
  static let appState = OSLog(subsystem: subsystem, category: "AppState")
  
  /// Authentication and user sessions
  static let authentication = OSLog(subsystem: subsystem, category: "Auth")
  
  /// State invalidation and event coordination
  static let stateInvalidation = OSLog(subsystem: subsystem, category: "StateInvalidation")
  
  /// Navigation and routing
  static let navigation = OSLog(subsystem: subsystem, category: "Navigation")
  
  /// Preferences and settings management
  static let preferences = OSLog(subsystem: subsystem, category: "Preferences")
  
  // MARK: - Feed System Categories
  
  /// Feed loading and management
  static let feedSystem = OSLog(subsystem: subsystem, category: "FeedSystem")
  
  /// Feed model state changes
  static let feedModel = OSLog(subsystem: subsystem, category: "FeedModel")
  
  /// Feed filtering and tuning
  static let feedTuning = OSLog(subsystem: subsystem, category: "FeedTuning")
  
  /// Feed prefetching and caching
  static let feedCache = OSLog(subsystem: subsystem, category: "FeedCache")
  
  // MARK: - Post System Categories
  
  /// Post creation and management
  static let postManager = OSLog(subsystem: subsystem, category: "PostManager")
  
  /// Post interactions (likes, reposts, replies)
  static let postShadow = OSLog(subsystem: subsystem, category: "PostShadow")
  
  /// Thread processing and display
  static let threadSystem = OSLog(subsystem: subsystem, category: "ThreadSystem")
  
  // MARK: - Content Categories
  
  /// Media handling (images, videos)
  static let media = OSLog(subsystem: subsystem, category: "Media")
  
  /// Search functionality
  static let search = OSLog(subsystem: subsystem, category: "Search")
  
  /// Chat and messaging
  static let chat = OSLog(subsystem: subsystem, category: "Chat")
  
  /// Notifications and push messaging
  static let notifications = OSLog(subsystem: subsystem, category: "Notifications")
  
  // MARK: - Network Categories
  
  /// AT Protocol client and networking
  static let networking = OSLog(subsystem: subsystem, category: "Networking")
  
  /// API request/response logging
  static let api = OSLog(subsystem: subsystem, category: "API")
  
  /// Network error handling
  static let networkErrors = OSLog(subsystem: subsystem, category: "NetworkErrors")
  
  // MARK: - UI Categories
  
  /// View lifecycle and updates
  static let userInterface = OSLog(subsystem: subsystem, category: "UI")
  
  /// Gesture handling and interactions
  static let gestures = OSLog(subsystem: subsystem, category: "Gestures")
  
  /// Animation and transitions
  static let animations = OSLog(subsystem: subsystem, category: "Animations")
  
  /// Accessibility and VoiceOver
  static let accessibility = OSLog(subsystem: subsystem, category: "Accessibility")
  
  // MARK: - Performance Categories
  
  /// Performance monitoring and profiling
  static let performance = OSLog(subsystem: subsystem, category: "Performance")
  
  /// Memory usage and management
  static let memory = OSLog(subsystem: subsystem, category: "Memory")
  
  /// Background task processing
  static let backgroundTasks = OSLog(subsystem: subsystem, category: "BackgroundTasks")
  
  // MARK: - Debug Categories
  
  /// Debug state inspection
  static let debug = OSLog(subsystem: subsystem, category: "Debug")
  
  /// Developer tools and diagnostics
  static let devTools = OSLog(subsystem: subsystem, category: "DevTools")
  
  /// Test execution and validation
  static let testing = OSLog(subsystem: subsystem, category: "Testing")
  
  // MARK: - Error Categories
  
  /// General error handling
  static let errors = OSLog(subsystem: subsystem, category: "Errors")
  
  /// Crash reporting and recovery
  static let crashes = OSLog(subsystem: subsystem, category: "Crashes")
  
  /// Data corruption and validation errors
  static let dataIntegrity = OSLog(subsystem: subsystem, category: "DataIntegrity")
}

/// Convenience methods for common logging patterns
extension Logger {
  /// Log a state transition with before/after values
  func logStateTransition<T>(_ property: String, from oldValue: T, to newValue: T, in context: String = "") {
    self.info("State transition: \(property) changed from \(String(describing: oldValue)) to \(String(describing: newValue))\(context.isEmpty ? "" : " in \(context)")")
  }
  
  /// Log a performance measurement
  func logPerformance(_ operation: String, duration: TimeInterval) {
    self.info("Performance: \(operation) completed in \(String(format: "%.3f", duration))s")
  }
  
  /// Log an error with context
  func logError(_ error: Error, context: String = "", additionalInfo: [String: Any] = [:]) {
    var message = "Error: \(error.localizedDescription)"
    if !context.isEmpty {
      message += " [Context: \(context)]"
    }
    if !additionalInfo.isEmpty {
      let infoString = additionalInfo.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
      message += " [Info: \(infoString)]"
    }
    self.error("\(message)")
  }
}

/// Logger factory for consistent logger creation
struct LoggerFactory {
  /// Create a logger for a specific component
  static func logger(for component: String) -> Logger {
    return Logger(subsystem: OSLog.subsystem, category: component)
  }
  
  /// Create a logger using an existing OSLog category
  static func logger(osLog: OSLog) -> Logger {
    return Logger(osLog)
  }
}

/// Macro for quick logger creation in classes
#if DEBUG
extension NSObject {
  /// Convenience property for creating a logger based on the class name
  var logger: Logger {
    return LoggerFactory.logger(for: String(describing: type(of: self)))
  }
}
#endif
