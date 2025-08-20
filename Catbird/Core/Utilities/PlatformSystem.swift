//
//  PlatformSystem.swift
//  Catbird
//
//  Created by Claude on 8/19/25.
//

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI
import OSLog
import Foundation

private let platformSystemLogger = Logger(subsystem: "blue.catbird", category: "PlatformSystem")

// MARK: - Platform Application

/// Unified application interface across iOS and macOS platforms
@MainActor
public struct PlatformApplication {
  
  // MARK: - Application State
  
  /// Whether the application is currently active
  public static var isActive: Bool {
    #if os(iOS)
    return UIApplication.shared.applicationState == .active
    #elseif os(macOS)
    return NSApplication.shared.isActive
    #endif
  }
  
  /// Whether the application is in the background
  public static var isInBackground: Bool {
    #if os(iOS)
    return UIApplication.shared.applicationState == .background
    #elseif os(macOS)
    return !NSApplication.shared.isActive
    #endif
  }
  
  /// Whether the application supports multiple scenes (iOS) or windows (macOS)
  public static var supportsMultipleScenes: Bool {
    #if os(iOS)
    return UIApplication.shared.supportsMultipleScenes
    #elseif os(macOS)
    return true // macOS always supports multiple windows
    #endif
  }
  
  // MARK: - Notification Names
  
  /// Memory warning notification
  public static var memoryWarningNotification: Notification.Name {
    #if os(iOS)
    return UIApplication.didReceiveMemoryWarningNotification
    #elseif os(macOS)
    return Notification.Name("PlatformMemoryWarning")
    #endif
  }
  
  /// Battery level change notification
  public static var batteryLevelDidChangeNotification: Notification.Name {
    #if os(iOS)
    return UIDevice.batteryLevelDidChangeNotification
    #elseif os(macOS)
    return Notification.Name("PlatformBatteryLevelDidChange")
    #endif
  }
  
  /// Battery state change notification
  public static var batteryStateDidChangeNotification: Notification.Name {
    #if os(iOS)
    return UIDevice.batteryStateDidChangeNotification
    #elseif os(macOS)
    return Notification.Name("PlatformBatteryStateDidChange")
    #endif
  }
  
  /// Background notification name
  public static var didEnterBackgroundNotification: Notification.Name {
    #if os(iOS)
    return UIApplication.didEnterBackgroundNotification
    #elseif os(macOS)
    return NSApplication.didHideNotification
    #endif
  }
  
  /// Foreground notification name
  public static var willEnterForegroundNotification: Notification.Name {
    #if os(iOS)
    return UIApplication.willEnterForegroundNotification
    #elseif os(macOS)
    return NSApplication.willUnhideNotification
    #endif
  }
  
  // MARK: - Sharing
  
  /// Present sharing interface with items
  public static func presentSharing(items: [Any], completion: (() -> Void)? = nil) {
    #if os(iOS)
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let rootViewController = windowScene.windows.first?.rootViewController else {
      platformSystemLogger.error("Could not find root view controller for sharing")
      return
    }
    
    let activityViewController = UIActivityViewController(activityItems: items, applicationActivities: nil)
    
    // Handle iPad presentation
    if let popover = activityViewController.popoverPresentationController {
      popover.sourceView = rootViewController.view
      popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX, 
                                  y: rootViewController.view.bounds.midY, 
                                  width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    
    rootViewController.present(activityViewController, animated: true) {
      completion?()
    }
    #elseif os(macOS)
    guard let window = NSApplication.shared.keyWindow else {
      platformSystemLogger.error("Could not find key window for sharing")
      return
    }
    
    let sharingService = NSSharingService.sharingServices(forItems: items).first
    sharingService?.perform(withItems: items)
    completion?()
    #endif
  }
  
  // MARK: - Window Management
  
  /// Get the main window for the application
  public static var mainWindow: PlatformWindow? {
    #if os(iOS)
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
      return windowScene.windows.first
    }
    return nil
    #elseif os(macOS)
    return NSApplication.shared.mainWindow
    #endif
  }
  
  /// Get all windows for the application
  public static var windows: [PlatformWindow] {
    #if os(iOS)
    var allWindows: [UIWindow] = []
    for scene in UIApplication.shared.connectedScenes {
      if let windowScene = scene as? UIWindowScene {
        allWindows.append(contentsOf: windowScene.windows)
      }
    }
    return allWindows
    #elseif os(macOS)
    return NSApplication.shared.windows
    #endif
  }
  
  /// Get the key window (the one receiving input)
  public static var keyWindow: PlatformWindow? {
    #if os(iOS)
    return windows.first { $0.isKeyWindow }
    #elseif os(macOS)
    return NSApplication.shared.keyWindow
    #endif
  }
  
  // MARK: - External URL Handling
  
  /// Open a URL using the system's default handler
  public static func open(_ url: URL, completionHandler: ((Bool) -> Void)? = nil) {
    #if os(iOS)
    UIApplication.shared.open(url, options: [:]) { success in
      completionHandler?(success)
    }
    #elseif os(macOS)
    let success = NSWorkspace.shared.open(url)
    completionHandler?(success)
    #endif
  }
  
  /// Check if the system can open a URL
  public static func canOpen(_ url: URL) -> Bool {
    #if os(iOS)
    return UIApplication.shared.canOpenURL(url)
    #elseif os(macOS)
    // macOS can generally open any URL, but we can check if there's an app registered
    return NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    #endif
  }
  
  // MARK: - Sharing and Activity
  
  /// Present a system sharing interface
  public static func presentSharing(
    items: [Any],
    from sourceView: PlatformView? = nil,
    completion: (() -> Void)? = nil
  ) {
    #if os(iOS)
    let activityVC = UIActivityViewController(
      activityItems: items,
      applicationActivities: nil
    )
    
    if let window = mainWindow {
      // Configure for iPad popover presentation if needed
      if let popover = activityVC.popoverPresentationController {
        if let sourceView = sourceView {
          popover.sourceView = sourceView
          popover.sourceRect = sourceView.bounds
        } else {
          popover.sourceView = window
          popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 0, height: 0)
          popover.permittedArrowDirections = []
        }
      }
      
      window.rootViewController?.present(activityVC, animated: true) {
        completion?()
      }
    }
    #elseif os(macOS)
    // macOS uses NSSharingService
    if let firstItem = items.first {
      let picker = NSSharingServicePicker(items: [firstItem])
      
      if let sourceView = sourceView {
        picker.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .minY)
      } else if let window = mainWindow {
        let rect = CGRect(x: window.frame.midX, y: window.frame.midY, width: 0, height: 0)
        picker.show(relativeTo: rect, of: window.contentView ?? NSView(), preferredEdge: .minY)
      }
      
      completion?()
    }
    #endif
  }
  
  /// Copy text to the system pasteboard/clipboard
  public static func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    #endif
    
    platformSystemLogger.info("Copied text to clipboard: \(text.prefix(50))...")
  }
  
  /// Copy URL to the system pasteboard/clipboard
  public static func copyToClipboard(_ url: URL) {
    #if os(iOS)
    UIPasteboard.general.url = url
    #elseif os(macOS)
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .string)
    #endif
    
    platformSystemLogger.info("Copied URL to clipboard: \(url.absoluteString)")
  }
  
}

// MARK: - Platform Window Type Alias

#if os(iOS)
public typealias PlatformWindow = UIWindow
#elseif os(macOS)
public typealias PlatformWindow = NSWindow
#endif


// MARK: - Platform Content Size Category

/// Unified content size category support
@MainActor
public struct PlatformContentSizeCategory {
  
  /// Current content size category
  public static var current: ContentSizeCategory {
    #if os(iOS)
    return ContentSizeCategory(UIApplication.shared.preferredContentSizeCategory) ?? .large
    #elseif os(macOS)
    // macOS doesn't have UIContentSizeCategory, use system preferences
    return .large // Default to large for macOS
    #endif
  }
  
  /// Content size category change notification
  public static var didChangeNotification: Notification.Name {
    #if os(iOS)
    return UIContentSizeCategory.didChangeNotification
    #elseif os(macOS)
    // macOS doesn't have this notification, create a custom one
    return Notification.Name("PlatformContentSizeCategory.DidChange")
    #endif
  }
  
  /// Check if current size is accessibility size
  public static var isAccessibilityCategory: Bool {
    #if os(iOS)
    return UIApplication.shared.preferredContentSizeCategory.isAccessibilityCategory
    #elseif os(macOS)
    return false // macOS doesn't have accessibility size categories
    #endif
  }
}


// MARK: - Memory Management

extension PlatformApplication {
  
  /// Simulate memory warning on macOS for testing purposes
  #if os(macOS)
  public static func simulateMemoryWarning() {
    NotificationCenter.default.post(name: PlatformApplication.memoryWarningNotification, object: nil)
    platformSystemLogger.info("Simulated memory warning on macOS")
  }
  #endif
  
  #if os(macOS)
  /// Setup macOS battery monitoring (should be called during app initialization)
  public static func setupMacOSBatteryMonitoring() {
    // Create a timer to periodically check battery status on macOS
    Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
      checkAndNotifyBatteryChanges()
    }
  }
  
  private static var lastBatteryLevel: Float = -1
  private static var lastBatteryState: PlatformDeviceInfo.BatteryState = .unknown
  
  private static func checkAndNotifyBatteryChanges() {
    let currentLevel = PlatformDeviceInfo.batteryLevel
    let currentState = PlatformDeviceInfo.batteryState
    
    if lastBatteryLevel != -1 && abs(currentLevel - lastBatteryLevel) > 0.01 {
      NotificationCenter.default.post(name: PlatformApplication.batteryLevelDidChangeNotification, object: nil)
      platformSystemLogger.debug("macOS Battery level changed: \(currentLevel * 100)%")
    }
    
    if lastBatteryState != .unknown && lastBatteryState != currentState {
      NotificationCenter.default.post(name: PlatformApplication.batteryStateDidChangeNotification, object: nil)
      platformSystemLogger.debug("macOS Battery state changed: \(String(describing: currentState))")
    }
    
    lastBatteryLevel = currentLevel
    lastBatteryState = currentState
  }
  #endif
  
  /// Get available memory information
  public static var availableMemory: UInt64 {
    #if os(iOS)
    // Use iOS-specific memory checking
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
    
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_,
                  task_flavor_t(MACH_TASK_BASIC_INFO),
                  $0,
                  &count)
      }
    }
    
    if kerr == KERN_SUCCESS {
      let physicalMemory = ProcessInfo.processInfo.physicalMemory
      return physicalMemory - UInt64(info.resident_size)
    }
    
    return 0
    #elseif os(macOS)
    // Use macOS-specific memory checking
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
    
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_,
                  task_flavor_t(MACH_TASK_BASIC_INFO),
                  $0,
                  &count)
      }
    }
    
    if kerr == KERN_SUCCESS {
      let physicalMemory = ProcessInfo.processInfo.physicalMemory
      return physicalMemory - UInt64(info.resident_size)
    }
    
    return ProcessInfo.processInfo.physicalMemory / 2 // Conservative estimate
    #endif
  }
}

