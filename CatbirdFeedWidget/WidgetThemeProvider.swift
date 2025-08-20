//
//  WidgetThemeProvider.swift
//  CatbirdFeedWidget
//
//  Created by Claude Code on 6/11/25.
//

#if os(iOS)
import SwiftUI
import WidgetKit
import UIKit

// MARK: - Widget Theme Provider

/// Provides theme functionality for widgets by reading from shared preferences
/// This allows widgets to match the main app's theme settings
@MainActor
final class WidgetThemeProvider: ObservableObject {
    @Published var currentTheme: String = "system"
    @Published var darkThemeMode: DarkThemeMode = .dim
    
    private let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    
    enum DarkThemeMode: String, CaseIterable, Codable {
        case dim = "dim"
        case black = "black"
        
        var displayName: String {
            switch self {
            case .dim: return "Dim"
            case .black: return "Black"
            }
        }
    }
    
    static let shared = WidgetThemeProvider()
    
    private init() {
        loadThemeSettings()
    }
    
    /// Load theme settings from shared UserDefaults
    private func loadThemeSettings() {
        guard let sharedDefaults = sharedDefaults else { return }
        
        currentTheme = sharedDefaults.string(forKey: "selectedTheme") ?? "system"
        
        if let darkModeRaw = sharedDefaults.string(forKey: "darkThemeMode"),
           let darkMode = DarkThemeMode(rawValue: darkModeRaw) {
            darkThemeMode = darkMode
        }
    }
    
    /// Get the effective color scheme based on current theme and system appearance
    func effectiveColorScheme(for systemScheme: ColorScheme) -> ColorScheme {
        switch currentTheme {
        case "light":
            return .light
        case "dark":
            return .dark
        case "system":
            return systemScheme
        default:
            return systemScheme
        }
    }
    
    /// Refresh theme settings (call when widget updates)
    func refreshThemeSettings() {
        loadThemeSettings()
    }
}

// MARK: - Widget Theme Colors

extension Color {
    
    // MARK: - Widget Background Colors
    
    /// Primary background color for widgets
    @MainActor
    static func widgetBackground(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeProvider.darkThemeMode) {
        case (.dark, .black):
            return Color(red: 0, green: 0, blue: 0)
        case (.dark, .dim):
            return Color(red: 0.18, green: 0.18, blue: 0.20)
        default:
            return Color(UIColor.systemBackground)
        }
    }
    
    /// Secondary background color for elevated elements
    @MainActor
    static func widgetElevatedBackground(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeProvider.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.04)
        case (.dark, .dim):
            return Color(red: 0.25, green: 0.25, blue: 0.27)
        default:
            return Color(UIColor.secondarySystemBackground)
        }
    }
    
    /// Card background color for post cards
    @MainActor
    static func widgetCardBackground(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeProvider.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.02)
        case (.dark, .dim):
            return Color(red: 0.22, green: 0.22, blue: 0.24)
        default:
            return Color(UIColor.tertiarySystemBackground)
        }
    }
    
    // MARK: - Widget Text Colors
    
    /// Primary text color for widgets
    @MainActor
    static func widgetPrimaryText(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        let isBlackMode = colorScheme == .dark && themeProvider.darkThemeMode == .black
        
        if isBlackMode {
            return Color(white: 0.95)
        } else if colorScheme == .dark {
            return Color(white: 0.92)
        } else {
            return .primary
        }
    }
    
    /// Secondary text color for widgets
    @MainActor
    static func widgetSecondaryText(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        let isBlackMode = colorScheme == .dark && themeProvider.darkThemeMode == .black
        
        if isBlackMode {
            return Color(white: 0.70)
        } else if colorScheme == .dark {
            return Color(white: 0.65)
        } else {
            return .secondary
        }
    }
    
    /// Tertiary text color for widgets
    @MainActor
    static func widgetTertiaryText(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        let isBlackMode = colorScheme == .dark && themeProvider.darkThemeMode == .black
        
        if isBlackMode {
            return Color(white: 0.50)
        } else if colorScheme == .dark {
            return Color(white: 0.45)
        } else {
            return Color(UIColor.tertiaryLabel)
        }
    }
    
    // MARK: - Widget Border Colors
    
    /// Border color for widget elements
    @MainActor
    static func widgetBorder(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeProvider.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.20, opacity: 0.3)
        case (.dark, .dim):
            return Color(white: 0.40, opacity: 0.5)
        default:
            return Color(UIColor.systemGray5)
        }
    }
    
    /// Separator color for widget dividers
    @MainActor
    static func widgetSeparator(_ themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> Color {
        let colorScheme = themeProvider.effectiveColorScheme(for: currentScheme)
        
        switch (colorScheme, themeProvider.darkThemeMode) {
        case (.dark, .black):
            return Color(white: 0.15, opacity: 0.6)
        case (.dark, .dim):
            return Color(white: 0.45, opacity: 0.6)
        default:
            return Color(UIColor.separator)
        }
    }
}

// MARK: - Widget Design Tokens

/// Design tokens optimized for widget constraints
struct WidgetDesignTokens {
    // Base unit for widget layouts (slightly smaller than app)
    static let baseUnit: CGFloat = 3
    
    // Widget-specific spacing
    enum Spacing {
        static let xs: CGFloat = baseUnit * 1    // 3pt
        static let sm: CGFloat = baseUnit * 2    // 6pt
        static let md: CGFloat = baseUnit * 3    // 9pt
        static let base: CGFloat = baseUnit * 4  // 12pt
        static let lg: CGFloat = baseUnit * 5    // 15pt
        static let xl: CGFloat = baseUnit * 6    // 18pt
    }
    
    // Widget-optimized component sizes
    enum Size {
        // Avatar sizes for widgets
        static let avatarXS: CGFloat = baseUnit * 6  // 18pt
        static let avatarSM: CGFloat = baseUnit * 8  // 24pt
        static let avatarMD: CGFloat = baseUnit * 10 // 30pt
        static let avatarLG: CGFloat = baseUnit * 12 // 36pt
        
        // Corner radius
        static let radiusXS: CGFloat = baseUnit * 1  // 3pt
        static let radiusSM: CGFloat = baseUnit * 2  // 6pt
        static let radiusMD: CGFloat = baseUnit * 3  // 9pt
        static let radiusLG: CGFloat = baseUnit * 4  // 12pt
        
        // Icon sizes
        static let iconXS: CGFloat = baseUnit * 3  // 9pt
        static let iconSM: CGFloat = baseUnit * 4  // 12pt
        static let iconMD: CGFloat = baseUnit * 5  // 15pt
        static let iconLG: CGFloat = baseUnit * 6  // 18pt
    }
    
    // Widget-optimized font sizes
    enum FontSize {
        static let micro: CGFloat = 9
        static let caption: CGFloat = 10
        static let small: CGFloat = 11
        static let body: CGFloat = 12
        static let callout: CGFloat = 13
        static let subheadline: CGFloat = 14
        static let headline: CGFloat = 15
        static let title: CGFloat = 16
    }
}

// MARK: - Widget View Extensions

extension View {
    /// Apply widget-specific spacing
    func widgetSpacing(_ spacing: CGFloat) -> some View {
        self.padding(spacing)
    }
    
    /// Apply widget corner radius
    func widgetCornerRadius(_ radius: CGFloat = WidgetDesignTokens.Size.radiusMD) -> some View {
        self.clipShape(RoundedRectangle(cornerRadius: radius))
    }
    
    /// Apply widget card styling
    @MainActor
    func widgetCard(themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> some View {
        self
            .background(Color.widgetCardBackground(themeProvider, currentScheme: currentScheme))
            .widgetCornerRadius(WidgetDesignTokens.Size.radiusMD)
            .overlay(
                RoundedRectangle(cornerRadius: WidgetDesignTokens.Size.radiusMD)
                    .stroke(Color.widgetBorder(themeProvider, currentScheme: currentScheme), lineWidth: 0.5)
            )
    }
    
    /// Apply widget elevation background
    @MainActor
    func widgetElevation(themeProvider: WidgetThemeProvider, currentScheme: ColorScheme) -> some View {
        self
            .background(Color.widgetElevatedBackground(themeProvider, currentScheme: currentScheme))
            .widgetCornerRadius()
    }
}
#endif
