//
//  PlatformDeviceInfo.swift
//  Catbird
//
//  Platform device utilities for Catbird's macOS compatibility
//  Provides cross-platform abstractions for device detection and capabilities
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
import Foundation

/// Focused platform device utilities providing cross-platform compatibility
@MainActor
public struct PlatformDeviceInfo {
  
  // MARK: - User Interface Idiom Abstraction
  
  /// Cross-platform user interface idiom
  public enum UserInterfaceIdiom: CaseIterable {
    case phone
    case pad
    case mac
    case tv
    case carPlay
    case vision
    case unknown
    
    /// User-friendly description of the idiom
    public var description: String {
      switch self {
      case .phone: return "iPhone"
      case .pad: return "iPad"
      case .mac: return "Mac"
      case .tv: return "Apple TV"
      case .carPlay: return "CarPlay"
      case .vision: return "Vision Pro"
      case .unknown: return "Unknown"
      }
    }
    
    /// Whether this idiom represents a mobile device
    public var isMobile: Bool {
      return self == .phone || self == .pad
    }
    
    /// Whether this idiom represents a touch-capable device
    public var supportsTouchInput: Bool {
      return self == .phone || self == .pad || self == .vision
    }
  }
  
  /// Current device's user interface idiom (cross-platform)
  public static var userInterfaceIdiom: UserInterfaceIdiom {
    #if os(iOS)
    switch UIDevice.current.userInterfaceIdiom {
    case .phone: return .phone
    case .pad: return .pad
    case .tv: return .tv
    case .carPlay: return .carPlay
    case .mac: return .mac
    case .vision: return .vision
    default: return .unknown
    }
    #elseif os(macOS)
    return .mac
    #else
    return .unknown
    #endif
  }
  
  // MARK: - Device Type Detection
  
  /// Whether the current device is an iPhone
  public static var isPhone: Bool {
    return userInterfaceIdiom == .phone
  }
  
  /// Whether the current device is an iPhone (alias for isPhone)
  public static var isIPhone: Bool {
    return isPhone
  }
  
  /// Whether the current device is an iPad
  public static var isPad: Bool {
    return userInterfaceIdiom == .pad
  }
  
  /// Whether the current device is an iPad (alias for isPad)
  public static var isIPad: Bool {
    return isPad
  }
  
  /// Whether the current device is a Mac
  public static var isMac: Bool {
    return userInterfaceIdiom == .mac
  }
  
  /// Whether the current device is an Apple TV
  public static var isTV: Bool {
    return userInterfaceIdiom == .tv
  }
  
  /// Whether the current device is Apple Vision Pro
  public static var isVision: Bool {
    return userInterfaceIdiom == .vision
  }
  
  /// Whether the current device supports CarPlay
  public static var isCarPlay: Bool {
    return userInterfaceIdiom == .carPlay
  }
  
  // MARK: - Screen Size Helpers
  
  /// Current screen bounds
  public static var screenBounds: CGRect {
    #if os(iOS)
      return UIScreen.main.bounds
    #elseif os(macOS)
    return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    #else
    return .zero
    #endif
  }
  
  /// Current screen size
  public static var screenSize: CGSize {
    return screenBounds.size
  }
  
  /// Screen width
  public static var screenWidth: CGFloat {
    return screenSize.width
  }
  
  /// Screen height  
  public static var screenHeight: CGFloat {
    return screenSize.height
  }
  
  /// Display scale factor
  public static var screenScale: CGFloat {
    #if os(iOS)
      return UIScreen.main.scale
    #elseif os(macOS)
    return NSScreen.main?.backingScaleFactor ?? 2.0
    #else
    return 1.0
    #endif
  }
  
  /// Whether the screen is in landscape orientation
  public static var isLandscape: Bool {
    return screenWidth > screenHeight
  }
  
  /// Whether the screen is in portrait orientation
  public static var isPortrait: Bool {
    return screenHeight > screenWidth
  }
  
  /// Whether the screen is considered large (iPad-sized or larger)
  public static var isLargeScreen: Bool {
    let minDimension = min(screenWidth, screenHeight)
    return minDimension >= 768
  }
  
  // MARK: - Battery Monitoring
  
  /// Battery state abstraction
  public enum BatteryState {
    case unknown
    case unplugged
    case charging
    case full
    
    public var description: String {
      switch self {
      case .unknown: return "Unknown"
      case .unplugged: return "Unplugged"
      case .charging: return "Charging"
      case .full: return "Full"
      }
    }
    
    public var isCharging: Bool {
      return self == .charging
    }
  }
  
  /// Current battery level (0.0 to 1.0)
  public static var batteryLevel: Float {
    #if os(iOS)
    UIDevice.current.isBatteryMonitoringEnabled = true
    return UIDevice.current.batteryLevel
    #elseif os(macOS)
    // macOS battery monitoring stub - return reasonable default
    return 0.8 // Assume 80% for desktop use
    #else
    return 1.0
    #endif
  }
  
  /// Current battery state
  public static var batteryState: BatteryState {
    #if os(iOS)
    UIDevice.current.isBatteryMonitoringEnabled = true
    switch UIDevice.current.batteryState {
    case .unknown: return .unknown
    case .unplugged: return .unplugged  
    case .charging: return .charging
    case .full: return .full
    @unknown default: return .unknown
    }
    #elseif os(macOS)
    // macOS battery monitoring stub - assume plugged in
    return .full
    #else
    return .unknown
    #endif
  }
  
  /// Enable or disable battery monitoring (iOS only, no-op on macOS)
  public static var isBatteryMonitoringEnabled: Bool {
    get {
      #if os(iOS)
      return UIDevice.current.isBatteryMonitoringEnabled
      #elseif os(macOS)
      return true // Always available on macOS
      #else
      return false
      #endif
    }
    set {
      #if os(iOS)
      UIDevice.current.isBatteryMonitoringEnabled = newValue
      #elseif os(macOS)
      // No-op on macOS - battery info always conceptually available
      #endif
    }
  }
  
  /// Whether the device is currently on low power mode
  public static var isLowPowerModeEnabled: Bool {
    #if os(iOS)
    return ProcessInfo.processInfo.isLowPowerModeEnabled
    #elseif os(macOS)
    return false // macOS doesn't have low power mode
    #else
    return false
    #endif
  }
  
  // MARK: - Device Capabilities
  
  /// Whether the device has camera capability
  public static var hasCamera: Bool {
    #if os(iOS)
    return UIImagePickerController.isSourceTypeAvailable(.camera)
    #elseif os(macOS)
    return true // Most Macs have cameras
    #else
    return false
    #endif
  }
  
  /// Whether the device has haptic feedback capability
  public static var hasHapticFeedback: Bool {
    #if os(iOS)
    return isPhone || isPad // iPhone and iPad support haptics
    #elseif os(macOS)
    return false // macOS doesn't have haptic feedback
    #else
    return false
    #endif
  }
  
  /// Whether the device supports multiple windows
  public static var supportsMultipleWindows: Bool {
    #if os(iOS)
    return isPad || isMac // iPad and Catalyst apps support multiple windows
    #elseif os(macOS) 
    return true // macOS natively supports multiple windows
    #else
    return false
    #endif
  }
  
  /// Whether the device supports external displays
  public static var supportsExternalDisplay: Bool {
    #if os(iOS)
    return isPad // iPad can connect to external displays
    #elseif os(macOS)
    return true // macOS supports external displays
    #else
    return false
    #endif
  }
  
  // MARK: - System Information
  
  /// Device model identifier
  public static var deviceModel: String {
    #if os(iOS)
    return userInterfaceIdiom.description
    #elseif os(macOS)
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var machine = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &machine, &size, nil, 0)
    return String(cString: machine)
    #else
    return "Unknown"
    #endif
  }
  
  /// Operating system version
  public static var systemVersion: String {
    #if os(iOS)
    return UIDevice.current.systemVersion
    #elseif os(macOS)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    #else
    return "Unknown"
    #endif
  }
  
  /// Full device description for debugging
  public static var deviceDescription: String {
    let model = deviceModel
    let version = systemVersion
    let screen = "\(Int(screenWidth))x\(Int(screenHeight))"
    
    #if os(iOS)
    return "\(model) (iOS \(version)) - \(screen)@\(screenScale)x"
    #elseif os(macOS)
    return "\(model) (macOS \(version)) - \(screen)@\(screenScale)x"
    #else
    return "Unknown Device"
    #endif
  }
}

// MARK: - Convenience Extensions

extension PlatformDeviceInfo {
  
  /// Quick check for mobile devices (iPhone/iPad)
  public static var isMobileDevice: Bool {
    return userInterfaceIdiom.isMobile
  }
  
  /// Quick check for touch-capable devices
  public static var isTouchDevice: Bool {
    return userInterfaceIdiom.supportsTouchInput
  }
  
  /// Get a pixel-perfect value rounded to the display scale
  public static func pixelPerfect(_ value: CGFloat) -> CGFloat {
    return round(value * screenScale) / screenScale
  }
  
  /// Check if device supports advanced features based on capabilities
  public static var supportsAdvancedFeatures: Bool {
    if isMac {
      return true // macOS generally supports advanced features
    } else if isPad {
      return true // iPad generally supports advanced features
    } else if isPhone {
      // Check for ProMotion or newer devices
      #if os(iOS)
        return (UIScreen.main.maximumFramesPerSecond) > 60
      #else
      return false
      #endif
    } else {
      return false
    }
  }
}
