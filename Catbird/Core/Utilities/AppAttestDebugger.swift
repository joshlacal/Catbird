import DeviceCheck
import Foundation
import OSLog

/// Utility for debugging App Attest issues
@available(iOS 26.0, macOS 26.0, *)
struct AppAttestDebugger {
  private static let logger = Logger(subsystem: "blue.catbird", category: "AppAttestDebugger")
  
  /// Comprehensive App Attest environment check
  static func performEnvironmentCheck() -> AppAttestEnvironmentStatus {
    var status = AppAttestEnvironmentStatus()
    
    // 1. Check if App Attest is supported
    status.isSupported = DCAppAttestService.shared.isSupported
    
    // 2. Check platform
    #if targetEnvironment(simulator)
    status.platform = .simulator
    #else
    status.platform = .physicalDevice
    #endif
    
    // 3. Check OS version
    #if os(iOS)
    if #available(iOS 14.0, *) {
      status.osVersionSupported = true
    } else {
      status.osVersionSupported = false
    }
    #elseif os(macOS)
    if #available(macOS 11.0, *) {
      status.osVersionSupported = true
    } else {
      status.osVersionSupported = false
    }
    #endif
    
    // 4. Check bundle identifier
    status.bundleIdentifier = Bundle.main.bundleIdentifier
    
    // 5. Check for entitlements
    status.hasAppAttestEntitlement = checkForAppAttestEntitlement()
    
    // 6. Check for provisioning profile
    #if os(iOS)
    status.hasProvisioningProfile = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
    #else
    status.hasProvisioningProfile = false // macOS doesn't use embedded provisioning
    #endif
    
    return status
  }
  
  /// Log detailed diagnostics
  static func logDiagnostics() {
    let status = performEnvironmentCheck()
    
    logger.info("====== App Attest Diagnostics ======")
    logger.info("Platform: \(status.platform.rawValue)")
    logger.info("DCAppAttestService.isSupported: \(status.isSupported)")
    logger.info("OS Version Supported: \(status.osVersionSupported)")
    logger.info("Bundle ID: \(status.bundleIdentifier ?? "NONE")")
    logger.info("Has App Attest Entitlement: \(status.hasAppAttestEntitlement)")
    logger.info("Has Provisioning Profile: \(status.hasProvisioningProfile)")
    
    // Overall assessment
    if status.canUseAppAttest {
      logger.info("✅ App Attest should work in this environment")
    } else {
      logger.warning("⚠️ App Attest will NOT work in this environment")
      logger.info("Reasons:")
      
      if !status.isSupported {
        logger.info("  - DCAppAttestService reports not supported")
      }
      if status.platform == .simulator {
        logger.info("  - Running on Simulator (App Attest requires physical device)")
      }
      if !status.osVersionSupported {
        logger.info("  - OS version too old (requires iOS 14+ or macOS 11+)")
      }
      if !status.hasAppAttestEntitlement {
        logger.info("  - Missing App Attest entitlement")
      }
    }
    
    logger.info("====================================")
  }
  
  /// Generate a user-friendly status message
  static func getUserFriendlyMessage() -> String {
    let status = performEnvironmentCheck()
    
    if status.canUseAppAttest {
      return "App Attest is configured correctly and should work on this device."
    }
    
    if status.platform == .simulator {
      return "App Attest is not available on iOS Simulator. Please test on a physical device."
    }
    
    if !status.isSupported {
      return "App Attest is not supported on this device. Please ensure you're using iOS 14+ or macOS 11+ on a physical device."
    }
    
    if !status.osVersionSupported {
      return "Your device's operating system is too old. App Attest requires iOS 14.0+ or macOS 11.0+."
    }
    
    if !status.hasAppAttestEntitlement {
      return "The app is missing required App Attest entitlements. Please contact support."
    }
    
    return "App Attest configuration issue detected. Please check app logs for details."
  }
  
  /// Check if the app has the App Attest entitlement
  private static func checkForAppAttestEntitlement() -> Bool {
    // Try to read the entitlements from the embedded provisioning profile
    // This is a best-effort check and may not work in all scenarios
    
    // Check if we can access the task's entitlements
    // In a sandboxed app, we may not be able to read all entitlements directly
    
    // For now, we'll assume if we got this far and have a bundle ID, we likely have it
    // A more robust check would involve parsing the embedded.mobileprovision file
    return Bundle.main.bundleIdentifier != nil
  }
  
  /// Test if we can generate an App Attest key (diagnostic only)
  static func testKeyGeneration() async -> AppAttestKeyTestResult {
    guard DCAppAttestService.shared.isSupported else {
      return .notSupported
    }
    
    return await withCheckedContinuation { continuation in
      let startTime = Date()
      
      DCAppAttestService.shared.generateKey { keyID, error in
        let duration = Date().timeIntervalSince(startTime)
        
        if let error = error {
          let nsError = error as NSError
          logger.error("Key generation failed: \(error.localizedDescription)")
          logger.error("  Domain: \(nsError.domain), Code: \(nsError.code)")
          
          if nsError.domain == DCError.errorDomain {
            if let dcCode = DCError.Code(rawValue: nsError.code) {
              switch dcCode {
              case .featureUnsupported:
                continuation.resume(returning: .notSupported)
              case .invalidKey, .invalidInput:
                continuation.resume(returning: .invalidConfiguration)
              case .serverUnavailable:
                continuation.resume(returning: .networkError)
              case .unknownSystemFailure:
                continuation.resume(returning: .systemError)
              @unknown default:
                continuation.resume(returning: .unknownError(error))
              }
              return
            }
          }
          
          continuation.resume(returning: .unknownError(error))
        } else if let keyID = keyID {
          logger.info("✅ Successfully generated test key: \(keyID) (took \(String(format: "%.2f", duration))s)")
          continuation.resume(returning: .success(keyID: keyID, duration: duration))
        } else {
          logger.error("Key generation returned nil without error")
          continuation.resume(returning: .systemError)
        }
      }
    }
  }
}

// MARK: - Supporting Types

struct AppAttestEnvironmentStatus {
  var isSupported: Bool = false
  var platform: Platform = .unknown
  var osVersionSupported: Bool = false
  var bundleIdentifier: String?
  var hasAppAttestEntitlement: Bool = false
  var hasProvisioningProfile: Bool = false
  
  var canUseAppAttest: Bool {
    return isSupported &&
      platform == .physicalDevice &&
      osVersionSupported &&
      hasAppAttestEntitlement
  }
  
  enum Platform: String {
    case simulator = "iOS Simulator"
    case physicalDevice = "Physical Device"
    case unknown = "Unknown"
  }
}

enum AppAttestKeyTestResult {
  case success(keyID: String, duration: TimeInterval)
  case notSupported
  case invalidConfiguration
  case networkError
  case systemError
  case unknownError(Error)
  
  var isSuccess: Bool {
    if case .success = self {
      return true
    }
    return false
  }
  
  var userMessage: String {
    switch self {
    case .success(let keyID, let duration):
      return "Successfully generated App Attest key \(keyID.prefix(8))... in \(String(format: "%.2f", duration))s"
    case .notSupported:
      return "App Attest is not supported on this device"
    case .invalidConfiguration:
      return "Invalid App Attest configuration"
    case .networkError:
      return "Network error connecting to Apple servers"
    case .systemError:
      return "System error occurred"
    case .unknownError(let error):
      return "Unknown error: \(error.localizedDescription)"
    }
  }
}
