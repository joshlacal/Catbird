//
//  PlatformScreenInfo.swift
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

private let screenInfoLogger = Logger(subsystem: "blue.catbird", category: "PlatformScreenInfo")

/// Cross-platform screen information utilities
@MainActor
public struct PlatformScreenInfo {
    
    // MARK: - Screen Properties
    
    /// Main screen bounds
    public static var bounds: CGRect {
        #if os(iOS)
        return UIScreen.main.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        #elseif os(macOS)
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        #endif
    }
    
    /// Screen size
    public static var size: CGSize {
        return bounds.size
    }
    
    /// Screen width
    public static var width: CGFloat {
        return bounds.width
    }
    
    /// Screen height
    public static var height: CGFloat {
        return bounds.height
    }
    
    /// Screen scale factor
    public static var scale: CGFloat {
        #if os(iOS)
        return UIScreen.main.scale
        #elseif os(macOS)
        return NSScreen.main?.backingScaleFactor ?? 1.0
        #endif
    }
    
    /// Safe area insets
    public static var safeAreaInsets: EdgeInsets {
        #if os(iOS)
        let window = PlatformApplication.windows.first { $0.isKeyWindow }
        
        let insets = window?.safeAreaInsets ?? .zero
        return EdgeInsets(
            top: insets.top,
            leading: insets.left,
            bottom: insets.bottom,
            trailing: insets.right
        )
        #elseif os(macOS)
        // macOS doesn't have safe area insets concept
        return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        #endif
    }
    
    // MARK: - Screen State
    
    /// Whether the screen is in landscape orientation
    public static var isLandscape: Bool {
        return width > height
    }
    
    /// Whether the screen is in portrait orientation
    public static var isPortrait: Bool {
        return height > width
    }
    
    /// Whether the screen is considered large (iPad-sized or desktop)
    public static var isLargeScreen: Bool {
        let minDimension = min(width, height)
        return minDimension >= 768 // iPad mini width
    }
    
    /// Whether this is a compact width environment
    public static var isCompactWidth: Bool {
        #if os(iOS)
        return width < 414 // iPhone Plus/Max width threshold
        #elseif os(macOS)
        return false // macOS is never compact width
        #endif
    }
    
    /// Whether this is a regular width environment
    public static var isRegularWidth: Bool {
        return !isCompactWidth
    }
    
    // MARK: - Display Properties
    
    /// Refresh rate of the display (in Hz)
    public static var refreshRate: Double {
        #if os(iOS)
        if let displayLink = UIScreen.main.displayLink(withTarget: DummyTarget(), selector: #selector(DummyTarget.dummy)) {
            let rate = displayLink.preferredFramesPerSecond
            displayLink.invalidate()
            return rate > 0 ? Double(rate) : 60.0
        }
        return 60.0
        #elseif os(macOS)
        // macOS screen refresh rate detection
        if let screen = NSScreen.main,
           let refreshRate = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenRefreshRate")] as? NSNumber {
            return refreshRate.doubleValue
        }
        return 60.0
        #endif
    }
    
    /// Whether the display supports ProMotion (high refresh rates)
    public static var supportsProMotion: Bool {
        return refreshRate > 60.0
    }
    
    /// Maximum frames per second supported by the display
    public static var maximumFramesPerSecond: Int {
        #if os(iOS)
        return UIScreen.main.maximumFramesPerSecond
        #elseif os(macOS)
        return Int(refreshRate)
        #endif
    }
    
    /// Whether this is a ProMotion display (alias for supportsProMotion)
    public static var isProMotionDisplay: Bool {
        return supportsProMotion
    }
    
    /// Whether the device has a Dynamic Island (iPhone 14 Pro and later)
    public static var hasDynamicIsland: Bool {
        #if os(iOS)
        // Check if device has Dynamic Island by checking safe area and screen characteristics
        let window = PlatformApplication.windows.first { $0.isKeyWindow }
        
        if let safeAreaInsets = window?.safeAreaInsets {
            // Dynamic Island devices have specific safe area characteristics
            // This is a heuristic based on known Dynamic Island devices
            let hasLargeTopInset = safeAreaInsets.top > 47 // Dynamic Island devices have > 47pt top inset
            let screenWidth = bounds.width
            let screenHeight = bounds.height
            
            // Check for iPhone 14 Pro/Pro Max screen dimensions with Dynamic Island
            let isDynamicIslandSize = (screenWidth == 393 && screenHeight == 852) ||  // iPhone 14 Pro
                                     (screenWidth == 430 && screenHeight == 932)    // iPhone 14 Pro Max
            
            return hasLargeTopInset && isDynamicIslandSize && supportsProMotion
        }
        return false
        #elseif os(macOS)
        return false // macOS devices don't have Dynamic Island
        #endif
    }
    
    /// Points per inch for the display
    public static var pointsPerInch: Double {
        #if os(iOS)
        // Approximate PPI for common iOS devices
        let screenSize = size
        let screenArea = screenSize.width * screenSize.height
        
        // Rough estimation based on screen area
        if screenArea > 800000 { // iPad Pro territory
            return scale > 2.0 ? 264.0 : 132.0
        } else if screenArea > 400000 { // iPad territory
            return scale > 2.0 ? 264.0 : 132.0
        } else { // iPhone territory
            return scale > 3.0 ? 460.0 : (scale > 2.0 ? 326.0 : 163.0)
        }
        #elseif os(macOS)
        // macOS displays vary widely, use a reasonable default
        return 72.0 * scale
        #endif
    }
    
    // MARK: - Utility Methods
    
    /// Convert points to pixels based on screen scale
    public static func pointsToPixels(_ points: CGFloat) -> CGFloat {
        return points * scale
    }
    
    /// Convert pixels to points based on screen scale
    public static func pixelsToPoints(_ pixels: CGFloat) -> CGFloat {
        return pixels / scale
    }
    
    /// Get the center point of the screen
    public static var centerPoint: CGPoint {
        return CGPoint(x: width / 2, y: height / 2)
    }
    
    /// Calculate aspect ratio (width / height)
    public static var aspectRatio: CGFloat {
        return width / height
    }
    
    // MARK: - Screen Information Summary
    
    /// Get a summary of screen information for debugging
    public static var debugDescription: String {
        return """
        Screen Info:
        - Size: \(Int(width)) x \(Int(height)) points
        - Scale: \(scale)x
        - Refresh Rate: \(refreshRate) Hz
        - Orientation: \(isLandscape ? "Landscape" : "Portrait")
        - Size Class: \(isLargeScreen ? "Large" : "Compact")
        - ProMotion: \(supportsProMotion ? "Yes" : "No")
        - PPI: ~\(Int(pointsPerInch))
        """
    }
}

#if os(iOS)
// Helper class for display link creation
private class DummyTarget: NSObject {
    @objc func dummy() {}
}
#endif

// MARK: - Convenience Extensions

extension PlatformScreenInfo {
    
    /// Screen size categories for responsive design
    public enum SizeCategory {
        case compact    // Small phones
        case regular    // Large phones, small tablets
        case large      // Large tablets, desktops
    }
    
    /// Current size category
    public static var sizeCategory: SizeCategory {
        let minDimension = min(width, height)
        
        if minDimension < 414 {
            return .compact
        } else if minDimension < 768 {
            return .regular
        } else {
            return .large
        }
    }
    
    /// Whether the current screen size is suitable for multi-column layouts
    public static var supportsMultiColumn: Bool {
        return sizeCategory == .large || (sizeCategory == .regular && isLandscape)
    }
    
    /// Calculate responsive drawer width for side drawers
    /// Uses progressive scaling to provide better experience on larger displays
    public static var responsiveDrawerWidth: CGFloat {
        switch width {
        case ..<768: // iPhone Portrait
            return width * 0.82  // Slightly wider on phones
        case ..<1024: // iPhone Landscape / Small iPad
            return min(420, width * 0.45)
        case ..<1200: // Standard iPad
            return min(480, width * 0.4)
        case ..<1600: // Large iPad / Small Mac
            return min(550, width * 0.38)
        default: // Very large displays (Mac Studio Display, etc.)
            return min(600, width * 0.32)
        }
    }
}

