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
///
/// On iOS there is no process-wide screen answer: scenes resize (Split View,
/// Stage Manager, iPhone Mirroring, a folding iPhone) and can move between
/// displays. Layout reads its container's size or size class, rendering reads
/// `displayScale` from the view's environment or trait collection, and display
/// capabilities are asked of the screen hosting the scene doing the work.
@MainActor
public struct PlatformScreenInfo {

    #if os(iOS)

    // MARK: - Display Capabilities

    /// Maximum frames per second supported by `screen`.
    ///
    /// Pass the screen of the scene doing the work, such as
    /// `view.window?.windowScene?.screen`.
    public static func maximumFramesPerSecond(of screen: UIScreen) -> Int {
        return screen.maximumFramesPerSecond
    }

    /// Whether `screen` supports ProMotion (refresh rates above 60 Hz)
    public static func supportsProMotion(_ screen: UIScreen) -> Bool {
        return maximumFramesPerSecond(of: screen) > 60
    }

    #elseif os(macOS)

    // MARK: - Screen Properties

    /// Key window content bounds
    public static var bounds: CGRect {
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) {
            let contentBounds = window.contentView?.bounds ?? window.frame
            if contentBounds.width > 0 && contentBounds.height > 0 {
                return contentBounds
            }
        }
        return CGRect(x: 0, y: 0, width: 1200, height: 800)
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
        return NSScreen.main?.backingScaleFactor ?? 1.0
    }

    /// Safe area insets
    public static var safeAreaInsets: EdgeInsets {
        // macOS doesn't have safe area insets concept
        return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
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
        return false // macOS is never compact width
    }

    /// Whether this is a regular width environment
    public static var isRegularWidth: Bool {
        return !isCompactWidth
    }

    // MARK: - Display Properties

    /// Refresh rate of the display (in Hz)
    public static var refreshRate: Double {
        // macOS screen refresh rate detection
        if let screen = NSScreen.main,
           let refreshRate = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenRefreshRate")] as? NSNumber {
            return refreshRate.doubleValue
        }
        return 60.0
    }

    /// Whether the display supports ProMotion (high refresh rates)
    public static var supportsProMotion: Bool {
        return refreshRate > 60.0
    }

    /// Maximum frames per second supported by the display
    public static var maximumFramesPerSecond: Int {
        return Int(refreshRate)
    }

    /// Whether this is a ProMotion display (alias for supportsProMotion)
    public static var isProMotionDisplay: Bool {
        return supportsProMotion
    }

    /// Whether the device has a Dynamic Island
    public static var hasDynamicIsland: Bool {
        return false // macOS devices don't have Dynamic Island
    }

    /// Points per inch for the display
    public static var pointsPerInch: Double {
        // macOS displays vary widely, use a reasonable default
        return 72.0 * scale
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

    #endif
}

// MARK: - Convenience Extensions

#if os(macOS)
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
            return width  // Full-bleed drawer on phones
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
#endif
