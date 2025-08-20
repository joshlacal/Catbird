//
//  PlatformColors.swift
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

private let platformColorsLogger = Logger(subsystem: "blue.catbird", category: "PlatformColors")

// MARK: - Platform Color Type Aliases

#if os(iOS)
public typealias PlatformColor = UIColor
#elseif os(macOS)
public typealias PlatformColor = NSColor
#endif

// MARK: - Cross-Platform System Color Extensions

public extension PlatformColor {
    
    // MARK: - Background Colors
    
    /// Primary system background color (cross-platform)
    static var platformSystemBackground: PlatformColor {
        #if os(iOS)
        return UIColor.systemBackground
        #elseif os(macOS)
        return NSColor.windowBackgroundColor
        #endif
    }
    
    /// Secondary system background color (cross-platform)
    static var platformSecondarySystemBackground: PlatformColor {
        #if os(iOS)
        return UIColor.secondarySystemBackground
        #elseif os(macOS)
        return NSColor.controlBackgroundColor
        #endif
    }
    
    /// Tertiary system background color (cross-platform)
    static var platformTertiarySystemBackground: PlatformColor {
        #if os(iOS)
        return UIColor.tertiarySystemBackground
        #elseif os(macOS)
        return NSColor.underPageBackgroundColor
        #endif
    }
    
    /// System grouped background color (cross-platform)
    static var platformSystemGroupedBackground: PlatformColor {
        #if os(iOS)
        return UIColor.systemGroupedBackground
        #elseif os(macOS)
        return NSColor.windowBackgroundColor
        #endif
    }
    
    /// Secondary system grouped background color (cross-platform)
    static var platformSecondarySystemGroupedBackground: PlatformColor {
        #if os(iOS)
        return UIColor.secondarySystemGroupedBackground
        #elseif os(macOS)
        return NSColor.controlBackgroundColor
        #endif
    }
    
    /// Tertiary system grouped background color (cross-platform)
    static var platformTertiarySystemGroupedBackground: PlatformColor {
        #if os(iOS)
        return UIColor.tertiarySystemGroupedBackground
        #elseif os(macOS)
        return NSColor.underPageBackgroundColor
        #endif
    }
    
    // MARK: - Fill Colors
    
    /// System fill color (cross-platform)
    static var platformSystemFill: PlatformColor {
        #if os(iOS)
        return UIColor.systemFill
        #elseif os(macOS)
        return NSColor.controlBackgroundColor
        #endif
    }
    
    /// Secondary system fill color (cross-platform)
    static var platformSecondarySystemFill: PlatformColor {
        #if os(iOS)
        return UIColor.secondarySystemFill
        #elseif os(macOS)
        return NSColor.controlBackgroundColor.withAlphaComponent(0.8)
        #endif
    }
    
    /// Tertiary system fill color (cross-platform)
    static var platformTertiarySystemFill: PlatformColor {
        #if os(iOS)
        return UIColor.tertiarySystemFill
        #elseif os(macOS)
        return NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        #endif
    }
    
    /// Quaternary system fill color (cross-platform)
    static var platformQuaternarySystemFill: PlatformColor {
        #if os(iOS)
        return UIColor.quaternarySystemFill
        #elseif os(macOS)
        return NSColor.controlBackgroundColor.withAlphaComponent(0.3)
        #endif
    }
    
    // MARK: - Label Colors
    
    /// Primary label color (cross-platform)
    static var platformLabel: PlatformColor {
        #if os(iOS)
        return UIColor.label
        #elseif os(macOS)
        return NSColor.labelColor
        #endif
    }
    
    /// Secondary label color (cross-platform)
    static var platformSecondaryLabel: PlatformColor {
        #if os(iOS)
        return UIColor.secondaryLabel
        #elseif os(macOS)
        return NSColor.secondaryLabelColor
        #endif
    }
    
    /// Tertiary label color (cross-platform)
    static var platformTertiaryLabel: PlatformColor {
        #if os(iOS)
        return UIColor.tertiaryLabel
        #elseif os(macOS)
        return NSColor.tertiaryLabelColor
        #endif
    }
    
    /// Quaternary label color (cross-platform)
    static var platformQuaternaryLabel: PlatformColor {
        #if os(iOS)
        return UIColor.quaternaryLabel
        #elseif os(macOS)
        return NSColor.quaternaryLabelColor
        #endif
    }
    
    /// Placeholder text color (cross-platform)
    static var platformPlaceholderText: PlatformColor {
        #if os(iOS)
        return UIColor.placeholderText
        #elseif os(macOS)
        return NSColor.placeholderTextColor
        #endif
    }
    
    // MARK: - Separator Colors
    
    /// Separator color (cross-platform)
    static var platformSeparator: PlatformColor {
        #if os(iOS)
        return UIColor.separator
        #elseif os(macOS)
        return NSColor.separatorColor
        #endif
    }
    
    /// Opaque separator color (cross-platform)
    static var platformOpaqueSeparator: PlatformColor {
        #if os(iOS)
        return UIColor.opaqueSeparator
        #elseif os(macOS)
        return NSColor.separatorColor
        #endif
    }
    
    // MARK: - Link Colors
    
    /// Link color (cross-platform)
    static var platformLink: PlatformColor {
        #if os(iOS)
        return UIColor.link
        #elseif os(macOS)
        return NSColor.linkColor
        #endif
    }
    
    // MARK: - System Colors
    
    /// System blue color (cross-platform)
    static var platformSystemBlue: PlatformColor {
        #if os(iOS)
        return UIColor.systemBlue
        #elseif os(macOS)
        return NSColor.systemBlue
        #endif
    }
    
    /// System brown color (cross-platform)
    static var platformSystemBrown: PlatformColor {
        #if os(iOS)
        return UIColor.systemBrown
        #elseif os(macOS)
        return NSColor.systemBrown
        #endif
    }
    
    /// System cyan color (cross-platform)
    static var platformSystemCyan: PlatformColor {
        #if os(iOS)
        return UIColor.systemCyan
        #elseif os(macOS)
        return NSColor.systemTeal // macOS doesn't have cyan, use teal
        #endif
    }
    
    /// System green color (cross-platform)
    static var platformSystemGreen: PlatformColor {
        #if os(iOS)
        return UIColor.systemGreen
        #elseif os(macOS)
        return NSColor.systemGreen
        #endif
    }
    
    /// System indigo color (cross-platform)
    static var platformSystemIndigo: PlatformColor {
        #if os(iOS)
        return UIColor.systemIndigo
        #elseif os(macOS)
        return NSColor.systemIndigo
        #endif
    }
    
    /// System mint color (cross-platform)
    static var platformSystemMint: PlatformColor {
        #if os(iOS)
        if #available(iOS 15.0, *) {
            return UIColor.systemMint
        } else {
            return UIColor.systemTeal
        }
        #elseif os(macOS)
        if #available(macOS 12.0, *) {
            return NSColor.systemMint
        } else {
            return NSColor.systemTeal
        }
        #endif
    }
    
    /// System orange color (cross-platform)
    static var platformSystemOrange: PlatformColor {
        #if os(iOS)
        return UIColor.systemOrange
        #elseif os(macOS)
        return NSColor.systemOrange
        #endif
    }
    
    /// System pink color (cross-platform)
    static var platformSystemPink: PlatformColor {
        #if os(iOS)
        return UIColor.systemPink
        #elseif os(macOS)
        return NSColor.systemPink
        #endif
    }
    
    /// System purple color (cross-platform)
    static var platformSystemPurple: PlatformColor {
        #if os(iOS)
        return UIColor.systemPurple
        #elseif os(macOS)
        return NSColor.systemPurple
        #endif
    }
    
    /// System red color (cross-platform)
    static var platformSystemRed: PlatformColor {
        #if os(iOS)
        return UIColor.systemRed
        #elseif os(macOS)
        return NSColor.systemRed
        #endif
    }
    
    /// System teal color (cross-platform)
    static var platformSystemTeal: PlatformColor {
        #if os(iOS)
        return UIColor.systemTeal
        #elseif os(macOS)
        return NSColor.systemTeal
        #endif
    }
    
    /// System yellow color (cross-platform)
    static var platformSystemYellow: PlatformColor {
        #if os(iOS)
        return UIColor.systemYellow
        #elseif os(macOS)
        return NSColor.systemYellow
        #endif
    }
    
    // MARK: - System Gray Colors
    
    /// System gray color (cross-platform)
    static var platformSystemGray: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray
        #elseif os(macOS)
        return NSColor.systemGray
        #endif
    }
    
    /// System gray 2 color (cross-platform)
    static var platformSystemGray2: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray2
        #elseif os(macOS)
        return NSColor.controlColor
        #endif
    }
    
    /// System gray 3 color (cross-platform)
    static var platformSystemGray3: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray3
        #elseif os(macOS)
        return NSColor.controlColor.blended(withFraction: 0.2, of: .black) ?? NSColor.controlColor
        #endif
    }
    
    /// System gray 4 color (cross-platform)
    static var platformSystemGray4: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray4
        #elseif os(macOS)
        return NSColor.controlAccentColor
        #endif
    }
    
    /// System gray 5 color (cross-platform)
    static var platformSystemGray5: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray5
        #elseif os(macOS)
        return NSColor.gridColor
        #endif
    }
    
    /// System gray 6 color (cross-platform)
    static var platformSystemGray6: PlatformColor {
        #if os(iOS)
        return UIColor.systemGray6
        #elseif os(macOS)
        return NSColor.controlBackgroundColor
        #endif
    }
    
    // MARK: - Control Colors (macOS specific, mapped to iOS equivalents)
    
    #if os(macOS)
    /// Control accent color (macOS only)
    static var platformControlAccent: NSColor {
        return NSColor.controlAccentColor
    }
    
    /// Control color (macOS only)
    static var platformControl: NSColor {
        return NSColor.controlColor
    }
    
    /// Control background color (macOS only)
    static var platformControlBackground: NSColor {
        return NSColor.controlBackgroundColor
    }
    
    /// Control text color (macOS only)
    static var platformControlText: NSColor {
        return NSColor.controlTextColor
    }
    
    /// Disabled control text color (macOS only)
    static var platformDisabledControlText: NSColor {
        return NSColor.disabledControlTextColor
    }
    
    /// Selected control color (macOS only)
    static var platformSelectedControl: NSColor {
        return NSColor.selectedControlColor
    }
    
    /// Selected control text color (macOS only)
    static var platformSelectedControlText: NSColor {
        return NSColor.selectedControlTextColor
    }
    
    /// Alternate selected control text color (macOS only)
    static var platformAlternateSelectedControlText: NSColor {
        return NSColor.alternateSelectedControlTextColor
    }
    
    /// Scrubber textured background color (macOS only)
    static var platformScrubberTexturedBackground: NSColor {
        return NSColor.scrubberTexturedBackground
    }
    
    /// Window background color (macOS only)
    static var platformWindowBackground: NSColor {
        return NSColor.windowBackgroundColor
    }
    
    /// Window frame text color (macOS only)
    static var platformWindowFrameText: NSColor {
        return NSColor.windowFrameTextColor
    }
    
    /// Under page background color (macOS only)
    static var platformUnderPageBackground: NSColor {
        return NSColor.underPageBackgroundColor
    }
    
    /// Find highlight color (macOS only)
    static var platformFindHighlight: NSColor {
        return NSColor.findHighlightColor
    }
    
    /// Text color (macOS only)
    static var platformText: NSColor {
        return NSColor.textColor
    }
    
    /// Text background color (macOS only)
    static var platformTextBackground: NSColor {
        return NSColor.textBackgroundColor
    }
    
    /// Selected text color (macOS only)
    static var platformSelectedText: NSColor {
        return NSColor.selectedTextColor
    }
    
    /// Selected text background color (macOS only)
    static var platformSelectedTextBackground: NSColor {
        return NSColor.selectedTextBackgroundColor
    }
    
    /// Unemphasized selected text color (macOS only)
    static var platformUnemphasizedSelectedText: NSColor {
        return NSColor.unemphasizedSelectedTextColor
    }
    
    /// Unemphasized selected text background color (macOS only)
    static var platformUnemphasizedSelectedTextBackground: NSColor {
        return NSColor.unemphasizedSelectedTextBackgroundColor
    }
    #endif
    
    // MARK: - iOS Specific Colors (mapped to macOS equivalents)
    
    #if os(iOS)
    /// Dark text color (iOS only)
    static var platformDarkText: UIColor {
        return UIColor.darkText
    }
    
    /// Light text color (iOS only)
    static var platformLightText: UIColor {
        return UIColor.lightText
    }
    
    /// Tint color (iOS only, context-dependent)
    static var platformTint: UIColor {
        return UIColor.tintColor
    }
    #endif
}

// MARK: - Cross-Platform Color Creation

public extension PlatformColor {
    
    /// Create a color from RGB values (0-255)
    convenience init(platformRed red: Int, green: Int, blue: Int, alpha: CGFloat = 1.0) {
        let r = CGFloat(red) / 255.0
        let g = CGFloat(green) / 255.0
        let b = CGFloat(blue) / 255.0
        
        #if os(iOS)
        self.init(red: r, green: g, blue: b, alpha: alpha)
        #elseif os(macOS)
        self.init(red: r, green: g, blue: b, alpha: alpha)
        #endif
    }
    
    /// Create a color from a hex string
    convenience init?(platformHex hexString: String) {
        let hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)
        
        var hexNumber: UInt64 = 0
        
        guard scanner.scanHexInt64(&hexNumber) else {
            platformColorsLogger.error("Invalid hex color string: \(hexString)")
            return nil
        }
        
        let r, g, b, a: CGFloat
        switch hex.count {
        case 6: // RGB
            r = CGFloat((hexNumber & 0xFF0000) >> 16) / 255
            g = CGFloat((hexNumber & 0x00FF00) >> 8) / 255
            b = CGFloat(hexNumber & 0x0000FF) / 255
            a = 1.0
        case 8: // RGBA
            r = CGFloat((hexNumber & 0xFF000000) >> 24) / 255
            g = CGFloat((hexNumber & 0x00FF0000) >> 16) / 255
            b = CGFloat((hexNumber & 0x0000FF00) >> 8) / 255
            a = CGFloat(hexNumber & 0x000000FF) / 255
        default:
            platformColorsLogger.error("Invalid hex color length: \(hex.count) for string: \(hexString)")
            return nil
        }
        
        #if os(iOS)
        self.init(red: r, green: g, blue: b, alpha: a)
        #elseif os(macOS)
        self.init(red: r, green: g, blue: b, alpha: a)
        #endif
    }
    
    /// Get hex string representation of the color
    var platformHexString: String? {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        
        #if os(iOS)
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return nil
        }
        #elseif os(macOS)
        guard let rgbColor = usingColorSpace(.deviceRGB) else {
            return nil
        }
        rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        
        let rgb = (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
        
        if a < 1.0 {
            let rgba = (Int(r * 255) << 24) | (Int(g * 255) << 16) | (Int(b * 255) << 8) | Int(a * 255)
            return String(format: "#%08X", rgba)
        } else {
            return String(format: "#%06X", rgb)
        }
    }
    
    /// Create a lighter version of the color
    func lighter(by percentage: CGFloat = 0.2) -> PlatformColor {
        #if os(iOS)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s, brightness: min(b + percentage, 1.0), alpha: a)
        }
        return self
        #elseif os(macOS)
        return blended(withFraction: percentage, of: .white) ?? self
        #endif
    }
    
    /// Create a darker version of the color
    func darker(by percentage: CGFloat = 0.2) -> PlatformColor {
        #if os(iOS)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
            return UIColor(hue: h, saturation: s, brightness: max(b - percentage, 0.0), alpha: a)
        }
        return self
        #elseif os(macOS)
        return blended(withFraction: percentage, of: .black) ?? self
        #endif
    }
}

// MARK: - Color Accessibility Utilities

public extension PlatformColor {
    
    /// Calculate the relative luminance of the color for accessibility
    var luminance: CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        
        #if os(iOS)
        getRed(&r, green: &g, blue: &b, alpha: &a)
        #elseif os(macOS)
        if let rgbColor = usingColorSpace(.deviceRGB) {
            rgbColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        } else {
            return 0.5 // Fallback value
        }
        #endif
        
        func adjust(component: CGFloat) -> CGFloat {
            return component <= 0.03928 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        
        let adjustedR = adjust(component: r)
        let adjustedG = adjust(component: g)
        let adjustedB = adjust(component: b)
        
        return 0.2126 * adjustedR + 0.7152 * adjustedG + 0.0722 * adjustedB
    }
    
    /// Calculate contrast ratio between two colors
    func contrastRatio(with otherColor: PlatformColor) -> CGFloat {
        let luminance1 = self.luminance
        let luminance2 = otherColor.luminance
        
        let lighter = max(luminance1, luminance2)
        let darker = min(luminance1, luminance2)
        
        return (lighter + 0.05) / (darker + 0.05)
    }
    
    /// Check if the color meets WCAG AA accessibility standards when used with another color
    func meetsAccessibilityStandards(with otherColor: PlatformColor) -> Bool {
        return contrastRatio(with: otherColor) >= 4.5
    }
    
    /// Check if the color meets WCAG AAA accessibility standards when used with another color
    func meetsHighAccessibilityStandards(with otherColor: PlatformColor) -> Bool {
        return contrastRatio(with: otherColor) >= 7.0
    }
    
    /// Get an appropriate text color (black or white) for this background color
    var appropriateTextColor: PlatformColor {
        let whiteContrast = contrastRatio(with: .white)
        let blackContrast = contrastRatio(with: .black)
        
        return whiteContrast > blackContrast ? .white : .black
    }
}

// MARK: - SwiftUI Color Conversion

public extension Color {
    
    /// Create a SwiftUI Color from a PlatformColor
    init(platformColor: PlatformColor) {
        #if os(iOS)
        self.init(uiColor: platformColor)
        #elseif os(macOS)
        self.init(nsColor: platformColor)
        #endif
    }
    
    /// Convert SwiftUI Color to PlatformColor
    var platformColor: PlatformColor {
        #if os(iOS)
        return UIColor(self)
        #elseif os(macOS)
        return NSColor(self)
        #endif
    }
}

// MARK: - Dynamic Color Creation

public extension PlatformColor {
    
    /// Create a dynamic color that adapts to light/dark mode
    static func dynamicColor(
        light: PlatformColor,
        dark: PlatformColor
    ) -> PlatformColor {
        #if os(iOS)
        return UIColor { traitCollection in
            switch traitCollection.userInterfaceStyle {
            case .dark:
                return dark
            default:
                return light
            }
        }
        #elseif os(macOS)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        }
        #endif
    }
    
    /// Create a dynamic color with elevated variants
    static func dynamicElevatedColor(
        lightBase: PlatformColor,
        lightElevated: PlatformColor,
        darkBase: PlatformColor,
        darkElevated: PlatformColor
    ) -> PlatformColor {
        #if os(iOS)
        return UIColor { traitCollection in
            let isDark = traitCollection.userInterfaceStyle == .dark
            let isElevated = traitCollection.userInterfaceLevel == .elevated
            
            switch (isDark, isElevated) {
            case (true, true):
                return darkElevated
            case (true, false):
                return darkBase
            case (false, true):
                return lightElevated
            case (false, false):
                return lightBase
            }
        }
        #elseif os(macOS)
        // macOS doesn't have elevation levels, so we just use base colors
        return dynamicColor(light: lightBase, dark: darkBase)
        #endif
    }
}

// MARK: - Platform Color Constants

public struct PlatformColorConstants {
    
    // MARK: - Catbird Brand Colors
    
    /// Catbird primary blue color
    public static let catbirdBlue = PlatformColor(platformRed: 29, green: 161, blue: 242)
    
    /// Catbird secondary blue color (darker)
    public static let catbirdBlueDark = PlatformColor(platformRed: 26, green: 140, blue: 216)
    
    /// Catbird accent color
    public static let catbirdAccent = PlatformColor(platformRed: 255, green: 122, blue: 0)
    
    /// Catbird error color
    public static let catbirdError = PlatformColor(platformRed: 244, green: 67, blue: 54)
    
    /// Catbird success color
    public static let catbirdSuccess = PlatformColor(platformRed: 76, green: 175, blue: 80)
    
    /// Catbird warning color
    public static let catbirdWarning = PlatformColor(platformRed: 255, green: 193, blue: 7)
    
    // MARK: - Social Media Colors
    
    /// Bluesky brand color
    public static let blueskyBlue = PlatformColor(platformRed: 0, green: 133, blue: 255)
    
    /// Twitter/X brand color (legacy)
    public static let twitterBlue = PlatformColor(platformRed: 29, green: 161, blue: 242)
    
    /// Mastodon brand color
    public static let mastodonPurple = PlatformColor(platformRed: 99, green: 100, blue: 255)
    
    // MARK: - Accessibility Colors
    
    /// High contrast text color
    public static let highContrastText = PlatformColor.black
    
    /// High contrast background color
    public static let highContrastBackground = PlatformColor.white
    
    /// Reduced transparency background
    public static let reducedTransparencyBackground = PlatformColor.platformSystemBackground
}

// MARK: - Color Theme Support

public extension PlatformColor {
    
    /// Apply theme-specific modifications to a color
    func themed(for themeMode: ThemeMode, appearance: PlatformAppearance) -> PlatformColor {
        switch (themeMode, appearance) {
        case (.auto, .dark), (.dark, _):
            return self.darker(by: 0.1)
        case (.auto, .light), (.light, _), (.auto, .unspecified):
            return self
        }
    }
}

// MARK: - Theme Mode and Appearance Enums

public enum ThemeMode {
    case auto
    case light
    case dark
}

public enum PlatformAppearance {
    case light
    case dark
    case unspecified
}

public extension PlatformAppearance {
    
    /// Get the current system appearance
    static var current: PlatformAppearance {
        #if os(iOS)
        switch UITraitCollection.current.userInterfaceStyle {
        case .dark:
            return .dark
        case .light:
            return .light
        default:
            return .unspecified
        }
        #elseif os(macOS)
        let appearance = NSApp.effectiveAppearance
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return .dark
        } else {
            return .light
        }
        #endif
    }
}