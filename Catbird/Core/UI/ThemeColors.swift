import SwiftUI
import UIKit

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
            return Color(.systemBackground)
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
            return Color(.secondarySystemBackground)
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
            return Color(.tertiarySystemBackground)
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
            return Color(.systemGroupedBackground)
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
                return Color(.systemBackground)
            case .low, .medium:
                return Color(.secondarySystemBackground)
            case .high, .modal, .popover:
                return Color(.tertiarySystemBackground)
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
    static func dynamicText(_ themeManager: ThemeManager, style: TextStyle = .primary, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        let isBlackMode = colorScheme == .dark && themeManager.darkThemeMode == .black
        
        switch style {
        case .primary:
            if isBlackMode {
                return Color(white: 0.95) // High contrast for black mode
            } else if colorScheme == .dark {
                return Color(white: 0.92) // Slightly less for dim mode
            } else {
                return .primary
            }
            
        case .secondary:
            if isBlackMode {
                return Color(white: 0.70)
            } else if colorScheme == .dark {
                return Color(white: 0.65)
            } else {
                return .secondary
            }
            
        case .tertiary:
            if isBlackMode {
                return Color(white: 0.50)
            } else if colorScheme == .dark {
                return Color(white: 0.45)
            } else {
                return Color(.tertiaryLabel)
            }
            
        case .disabled:
            if isBlackMode {
                return Color(white: 0.35)
            } else if colorScheme == .dark {
                return Color(white: 0.30)
            } else {
                return Color(.quaternaryLabel)
            }
        }
    }
    
    // MARK: - Separator Colors
    
    /// Dynamic separator color
    static func dynamicSeparator(_ themeManager: ThemeManager, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.15, opacity: 0.6) // Visible but subtle
        case (.dark, .dim):
            return Color(white: 0.45, opacity: 0.6) // Much brighter for gray mode
        default:
            return Color(.separator)
        }
    }
    
    // MARK: - Border Colors
    
    /// Dynamic border color for cards and containers
    static func dynamicBorder(_ themeManager: ThemeManager, isProminent: Bool = false, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeManager.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeManager.darkThemeMode) {
        case (.dark, .black):
            return isProminent
                ? Color(white: 0.25, opacity: 0.5)
                : Color(white: 0.20, opacity: 0.3)
        case (.dark, .dim):
            return isProminent
                ? Color(white: 0.50, opacity: 0.6)
                : Color(white: 0.40, opacity: 0.5)
        default:
            return isProminent
                ? Color(.systemGray3)
                : Color(.systemGray5)
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

// MARK: - UIColor Extensions (for UIKit components)

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