import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Theme Color System

/// Text style variations for different hierarchy levels
enum TextStyle {
    case primary
    case secondary
    case tertiary
    case disabled
}

/// Color elevation levels for creating depth hierarchy
enum ColorElevation: Int {
    case base = 0
    case low = 1
    case medium = 2
    case high = 3
    case modal = 4
    case popover = 5
}

// MARK: - Color Extensions

extension Color {
    
    // MARK: - Dynamic Background Colors
    
    /// Primary background color that adapts to theme
    static func dynamicBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return Color(red: 0, green: 0, blue: 0) // Pure black
        case (.dark, .dim):
            return Color(red: 0.18, green: 0.18, blue: 0.20) // Proper gray for dim mode
        default:
            #if os(iOS)
            return Color(.systemBackground)
            #elseif os(macOS)
            return Color(.windowBackgroundColor)
            #endif
        }
    }
    
    /// Secondary background color that adapts to theme
    static func dynamicSecondaryBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.04) // Subtle elevation
        case (.dark, .dim):
            return Color(red: 0.25, green: 0.25, blue: 0.27) // Lighter gray for secondary
        default:
            return Color(platformColor: PlatformColor.platformSecondarySystemBackground)
        }
    }
    
    /// Tertiary background color that adapts to theme
    static func dynamicTertiaryBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.06) // More elevation
        case (.dark, .dim):
            return Color(red: 0.32, green: 0.32, blue: 0.34) // Even lighter gray for tertiary
        default:
            return Color(platformColor: PlatformColor.platformTertiarySystemBackground)
        }
    }
    
    /// Grouped background color for list backgrounds
    static func dynamicGroupedBackground(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return Color(red: 0, green: 0, blue: 0) // Pure black
        case (.dark, .dim):
            return Color(red: 0.15, green: 0.15, blue: 0.17) // Slightly darker gray for grouped background
        default:
            #if os(iOS)
            return Color(.systemGroupedBackground)
            #elseif os(macOS)
            return Color(.windowBackgroundColor)
            #endif
        }
    }
    
    // MARK: - Elevated Backgrounds (with hierarchy)
    
    /// Elevated background with proper hierarchy for depth
    static func elevatedBackground(_ themeManager: ThemeManager, elevation: ColorElevation = .low, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        guard colorScheme == .dark else {
            // Light mode uses standard elevation
            switch elevation {
            case .base:
                #if os(iOS)
                return Color(.systemBackground)
                #elseif os(macOS)
                return Color(.windowBackgroundColor)
                #endif
            case .low, .medium:
                #if os(iOS)
                return Color(UIColor.secondarySystemBackground)
                #elseif os(macOS)
                return Color(.controlBackgroundColor)
                #endif
            case .high, .modal, .popover:
                #if os(iOS)
                return Color(platformColor: PlatformColor.platformTertiarySystemBackground)
                #elseif os(macOS)
                return Color(.underPageBackgroundColor)
                #endif
            }
        }
        
        // Dark mode elevation
        if themeManager.darkThemeMode == .black {
            // True black mode with subtle elevation steps
            switch elevation {
            case .base:
                return Color(white: 0.00) // Pure black
            case .low:
                return Color(white: 0.02) // Cards
            case .medium:
                return Color(white: 0.04) // Elevated cards
            case .high:
                return Color(white: 0.06) // Modals
            case .modal:
                return Color(white: 0.08) // Modal overlays
            case .popover:
                return Color(white: 0.10) // Popovers
            }
        } else {
            // Dim mode with proper gray hierarchy
            switch elevation {
            case .base:
                return Color(red: 0.18, green: 0.18, blue: 0.20) // Base gray
            case .low:
                return Color(red: 0.22, green: 0.22, blue: 0.24) // Cards
            case .medium:
                return Color(red: 0.25, green: 0.25, blue: 0.27) // Elevated
            case .high:
                return Color(red: 0.28, green: 0.28, blue: 0.30) // Modals
            case .modal:
                return Color(red: 0.32, green: 0.32, blue: 0.34) // Modal overlays
            case .popover:
                return Color(red: 0.35, green: 0.35, blue: 0.37) // Popovers
            }
        }
    }
    
    // MARK: - Text Colors
    
    /// Dynamic text color with proper contrast for readability
    static func dynamicText(_ themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        let isBlackMode = colorScheme == .dark && themeManager.darkThemeMode == .black
        
        switch style {
        case .primary:
            if isBlackMode {
                return increaseContrast ? Color(white: 1.0) : Color(white: 0.95)
            } else if colorScheme == .dark {
                return increaseContrast ? Color(white: 0.98) : Color(white: 0.92)
            } else {
                return increaseContrast ? Color.black : .primary
            }
            
        case .secondary:
            if isBlackMode {
                return increaseContrast ? Color(white: 0.85) : Color(white: 0.70)
            } else if colorScheme == .dark {
                return increaseContrast ? Color(white: 0.80) : Color(white: 0.65)
            } else {
                #if os(iOS)
                return increaseContrast ? Color(.systemGray) : .secondary
                #elseif os(macOS)
                return increaseContrast ? Color(.secondaryLabelColor) : Color(.secondaryLabelColor)
                #endif
            }
            
        case .tertiary:
            if isBlackMode {
                return increaseContrast ? Color(white: 0.65) : Color(white: 0.50)
            } else if colorScheme == .dark {
                return increaseContrast ? Color(white: 0.60) : Color(white: 0.45)
            } else {
                #if os(iOS)
                return increaseContrast ? Color(.systemGray2) : Color(.tertiaryLabel)
                #elseif os(macOS)
                return increaseContrast ? Color(.tertiaryLabelColor) : Color(.tertiaryLabelColor)
                #endif
            }
            
        case .disabled:
            if isBlackMode {
                return increaseContrast ? Color(white: 0.50) : Color(white: 0.35)
            } else if colorScheme == .dark {
                return increaseContrast ? Color(white: 0.45) : Color(white: 0.30)
            } else {
                #if os(iOS)
                return increaseContrast ? Color(platformColor: PlatformColor.platformSystemGray3) : Color(.quaternaryLabel)
                #elseif os(macOS)
                return increaseContrast ? Color(.quaternaryLabelColor) : Color(.quaternaryLabelColor)
                #endif
            }
        }
    }
    
    // MARK: - Separator Colors
    
    /// Dynamic separator color
    static func dynamicSeparator(_ themeManager: ThemeManager, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return increaseContrast ? Color(white: 0.30, opacity: 0.8) : Color(white: 0.15, opacity: 0.6)
        case (.dark, .dim):
            return increaseContrast ? Color(white: 0.60, opacity: 0.8) : Color(white: 0.45, opacity: 0.6)
        default:
            #if os(iOS)
            return increaseContrast ? Color(platformColor: PlatformColor.platformOpaqueSeparator) : Color(platformColor: PlatformColor.platformSeparator)
            #elseif os(macOS)
            return Color(platformColor: PlatformColor.platformSeparator)
            #endif
        }
    }
    
    // MARK: - Border Colors
    
    /// Dynamic border color for cards and containers
    static func dynamicBorder(_ themeManager: ThemeManager, isProminent: Bool = false, currentScheme: ColorScheme, increaseContrast: Bool = false) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            if increaseContrast {
                return isProminent
                    ? Color(white: 0.40, opacity: 0.8)
                    : Color(white: 0.30, opacity: 0.6)
            } else {
                return isProminent
                    ? Color(white: 0.25, opacity: 0.5)
                    : Color(white: 0.20, opacity: 0.3)
            }
        case (.dark, .dim):
            if increaseContrast {
                return isProminent
                    ? Color(white: 0.65, opacity: 0.8)
                    : Color(white: 0.55, opacity: 0.7)
            } else {
                return isProminent
                    ? Color(white: 0.50, opacity: 0.6)
                    : Color(white: 0.40, opacity: 0.5)
            }
        default:
            if increaseContrast {
                if isProminent {
                    #if os(iOS)
                    return Color(.systemGray2)
                    #elseif os(macOS)
                    return Color(.controlColor)
                    #endif
                } else {
                    #if os(iOS)
                    return Color(.systemGray4)
                    #elseif os(macOS)
                    return Color(.controlAccentColor)
                    #endif
                }
            } else {
                if isProminent {
                    #if os(iOS)
                    return Color(platformColor: PlatformColor.platformSystemGray3)
                    #elseif os(macOS)
                    return Color(.controlColor)
                    #endif
                } else {
                    #if os(iOS)
                    return Color(platformColor: PlatformColor.platformSystemGray5)
                    #elseif os(macOS)
                    return Color(.gridColor)
                    #endif
                }
            }
        }
    }
    
    // MARK: - Special Purpose Colors
    
    /// Glass overlay color for blur effects
    static func glassOverlay(_ themeManager: ThemeManager, intensity: GlassIntensity = .medium, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        if colorScheme == .dark && themeManager.darkThemeMode == .black {
            // No glass effect in true black mode
            return Color.clear
        }
        
        switch intensity {
        case .subtle:
            return Color.white.opacity(0.05)
        case .medium:
            return Color.white.opacity(0.08)
        case .strong:
            return Color.white.opacity(0.12)
        }
    }
    
    /// Shadow color that adapts to theme
    static func dynamicShadow(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        if colorScheme == .dark && themeManager.darkThemeMode == .black {
            // No shadows in true black mode (they won't be visible)
            return Color.clear
        } else if colorScheme == .dark {
            // Subtle shadows in dim mode
            return Color.black.opacity(0.5)
        } else {
            // Standard shadows in light mode
            return Color.black.opacity(0.15)
        }
    }
    
    // MARK: - Cross-Platform System Colors
    
    /// Cross-platform system background color
    static var systemBackground: Color {
        #if os(iOS)
        return Color(.systemBackground)
        #elseif os(macOS)
        return Color(.windowBackgroundColor)
        #endif
    }
    
    /// Cross-platform secondary system background color
    static var secondarySystemBackground: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSecondarySystemBackground)
        #elseif os(macOS)
        return Color(.controlBackgroundColor)
        #endif
    }
    
    /// Cross-platform tertiary system background color
    static var tertiarySystemBackground: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformTertiarySystemBackground)
        #elseif os(macOS)
        return Color(.underPageBackgroundColor)
        #endif
    }
    
    /// Cross-platform system grouped background color
    static var systemGroupedBackground: Color {
        #if os(iOS)
        return Color(.systemGroupedBackground)
        #elseif os(macOS)
        return Color(.windowBackgroundColor)
        #endif
    }
    
    /// Cross-platform label color
    static var label: Color {
        #if os(iOS)
        return Color(.label)
        #elseif os(macOS)
        return Color(.labelColor)
        #endif
    }
    
    /// Cross-platform secondary label color
    static var secondaryLabel: Color {
        #if os(iOS)
        return Color(.secondaryLabel)
        #elseif os(macOS)
        return Color(.secondaryLabelColor)
        #endif
    }
    
    /// Cross-platform tertiary label color
    static var tertiaryLabel: Color {
        #if os(iOS)
        return Color(.tertiaryLabel)
        #elseif os(macOS)
        return Color(.tertiaryLabelColor)
        #endif
    }
    
    /// Cross-platform quaternary label color
    static var quaternaryLabel: Color {
        #if os(iOS)
        return Color(.quaternaryLabel)
        #elseif os(macOS)
        return Color(.quaternaryLabelColor)
        #endif
    }
    
    /// Cross-platform system fill color
    static var systemFill: Color {
        #if os(iOS)
        return Color(.systemFill)
        #elseif os(macOS)
        return Color(.controlBackgroundColor)
        #endif
    }
    
    /// Cross-platform quaternary system fill color
    static var quaternarySystemFill: Color {
        #if os(iOS)
        return Color(.quaternarySystemFill)
        #elseif os(macOS)
        return Color(.controlBackgroundColor).opacity(0.3)
        #endif
    }
    
    /// Cross-platform system blue color
    static var systemBlue: Color {
        #if os(iOS)
        return Color(.systemBlue)
        #elseif os(macOS)
        return Color(.systemBlue)
        #endif
    }
    
    /// Cross-platform system red color
    static var systemRed: Color {
        #if os(iOS)
        return Color(.systemRed)
        #elseif os(macOS)
        return Color(.systemRed)
        #endif
    }
    
    /// Cross-platform system green color
    static var systemGreen: Color {
        #if os(iOS)
        return Color(.systemGreen)
        #elseif os(macOS)
        return Color(.systemGreen)
        #endif
    }
    
    /// Cross-platform system orange color
    static var systemOrange: Color {
        #if os(iOS)
        return Color(.systemOrange)
        #elseif os(macOS)
        return Color(.systemOrange)
        #endif
    }
    
    /// Cross-platform system yellow color
    static var systemYellow: Color {
        #if os(iOS)
        return Color(.systemYellow)
        #elseif os(macOS)
        return Color(.systemYellow)
        #endif
    }
    
    /// Cross-platform system pink color
    static var systemPink: Color {
        #if os(iOS)
        return Color(.systemPink)
        #elseif os(macOS)
        return Color(.systemPink)
        #endif
    }
    
    /// Cross-platform system purple color
    static var systemPurple: Color {
        #if os(iOS)
        return Color(.systemPurple)
        #elseif os(macOS)
        return Color(.systemPurple)
        #endif
    }
    
    /// Cross-platform system teal color
    static var systemTeal: Color {
        #if os(iOS)
        return Color(.systemTeal)
        #elseif os(macOS)
        return Color(.systemTeal)
        #endif
    }
    
    /// Cross-platform system indigo color
    static var systemIndigo: Color {
        #if os(iOS)
        return Color(.systemIndigo)
        #elseif os(macOS)
        return Color(.systemIndigo)
        #endif
    }
    
    /// Cross-platform system brown color
    static var systemBrown: Color {
        #if os(iOS)
        return Color(.systemBrown)
        #elseif os(macOS)
        return Color(.systemBrown)
        #endif
    }
    
    /// Cross-platform system gray color
    static var systemGray: Color {
        #if os(iOS)
        return Color(.systemGray)
        #elseif os(macOS)
        return Color(.systemGray)
        #endif
    }
    
    /// Cross-platform system gray2 color
    static var systemGray2: Color {
        #if os(iOS)
        return Color(.systemGray2)
        #elseif os(macOS)
        return Color(.controlColor)
        #endif
    }
    
    /// Cross-platform system gray3 color
    static var systemGray3: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSystemGray3)
        #elseif os(macOS)
        return Color(.controlColor)
        #endif
    }
    
    /// Cross-platform system gray4 color
    static var systemGray4: Color {
        #if os(iOS)
        return Color(.systemGray4)
        #elseif os(macOS)
        return Color(.controlAccentColor)
        #endif
    }
    
    /// Cross-platform system gray5 color
    static var systemGray5: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSystemGray5)
        #elseif os(macOS)
        return Color(.gridColor)
        #endif
    }
    
    /// Cross-platform system gray6 color
    static var systemGray6: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSystemGray6)
        #elseif os(macOS)
        return Color(.controlBackgroundColor)
        #endif
    }
    
    /// Cross-platform separator color
    static var separator: Color {
        #if os(iOS)
        return Color(platformColor: PlatformColor.platformSeparator)
        #elseif os(macOS)
        return Color(platformColor: PlatformColor.platformSeparator)
        #endif
    }
    
    /// Cross-platform opaque separator color
    static var opaqueSeparator: Color {
        #if os(iOS)
        return Color(.opaqueSeparator)
        #elseif os(macOS)
        return Color(platformColor: PlatformColor.platformSeparator)
        #endif
    }
}

// MARK: - Theme Color Cache

/// Performance optimization: Cache calculated colors
class ThemeColorCache {
    static let shared = ThemeColorCache()
    
    private var cache: [String: Color] = [:]
    private let queue = DispatchQueue(label: "catbird.theme.colorcache", attributes: .concurrent)
    
    func color(for key: String, generator: () -> Color) -> Color {
        // Try to read from cache
        var cachedColor: Color?
        queue.sync {
            cachedColor = cache[key]
        }
        
        if let cached = cachedColor {
            return cached
        }
        
        // Generate and cache
        let color = generator()
        queue.async(flags: .barrier) {
            self.cache[key] = color
        }
        
        return color
    }
    
    func invalidate() {
        queue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
    
    /// Selectively invalidate cache entries for a specific theme
    /// This reduces the performance impact compared to full invalidation
    func invalidateTheme(_ theme: String) {
        queue.async(flags: .barrier) {
            // Remove only cache entries that contain the theme name
            let keysToRemove = self.cache.keys.filter { key in
                key.contains(theme) || key.contains("dynamic")
            }
            
            for key in keysToRemove {
                self.cache.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - Accessibility Color Extensions

extension Color {
    /// Adaptive background color that respects contrast settings
    static func adaptiveBackground(appState: AppState?, defaultColor: Color) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return increaseContrast ? defaultColor.opacity(0.95) : defaultColor
    }
    
    /// Adaptive foreground color that respects contrast settings
    static func adaptiveForeground(appState: AppState?, defaultColor: Color) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return increaseContrast ? .primary : defaultColor
    }
    
    /// Adaptive border color that respects contrast settings
    static func adaptiveBorder(appState: AppState?) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return increaseContrast ? .primary.opacity(0.3) : .gray.opacity(0.2)
    }
    
    /// Adaptive text color that respects contrast settings
    static func adaptiveText(appState: AppState?, themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return dynamicText(themeManager, style: style, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
    
    /// Adaptive border color that respects theme and contrast settings
    static func adaptiveBorder(appState: AppState?, themeManager: ThemeManager, isProminent: Bool = false, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return dynamicBorder(themeManager, isProminent: isProminent, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
    
    /// Adaptive separator color that respects contrast settings
    static func adaptiveSeparator(appState: AppState?, themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let increaseContrast = appState?.appSettings.increaseContrast ?? false
        return dynamicSeparator(themeManager, currentScheme: currentScheme, increaseContrast: increaseContrast)
    }
}

// MARK: - UIColor Extensions (for UIKit components)

#if os(iOS)
extension UIColor {
    
    /// Convert our theme system colors to UIColor for UIKit components
    static func themed(_ color: (ThemeManager) -> Color, with themeManager: ThemeManager) -> UIColor {
        return UIColor(color(themeManager))
    }
    
    /// Helper to create dynamic colors that respond to theme changes
    static func dynamicThemed(
        light: @escaping () -> UIColor,
        dark: @escaping (ThemeManager.DarkThemeMode) -> UIColor
    ) -> UIColor {
        return UIColor { traitCollection in
            if traitCollection.userInterfaceStyle == .dark {
                // This is a limitation - we can't access ThemeManager here
                // For now, return the dim mode color
                return dark(.dim)
            } else {
                return light()
            }
        }
    }
}
#elseif os(macOS)
extension NSColor {
    
    /// Convert our theme system colors to NSColor for macOS components
    static func themed(_ color: (ThemeManager) -> Color, with themeManager: ThemeManager) -> NSColor {
        return NSColor(color(themeManager))
    }
    
    /// Helper to create dynamic colors that respond to theme changes
    static func dynamicThemed(
        light: @escaping () -> NSColor,
        dark: @escaping (ThemeManager.DarkThemeMode) -> NSColor
    ) -> NSColor {
        return NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return dark(.dim)
            } else {
                return light()
            }
        }
    }
}
#endif
