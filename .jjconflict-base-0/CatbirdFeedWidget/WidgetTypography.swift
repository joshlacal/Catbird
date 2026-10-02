//
//  WidgetTypography.swift
//  CatbirdFeedWidget
//
//  Created by Claude Code on 6/11/25.
//

#if os(iOS)
import SwiftUI
import WidgetKit

// MARK: - Widget Font Manager

/// Simplified font management for widgets that reads user preferences from shared storage
@MainActor
final class WidgetFontManager: ObservableObject {
    @Published var fontSizeScale: CGFloat = 1.0
    @Published var fontFamily: FontFamily = .system
    @Published var lineSpacing: LineSpacing = .normal
    
    private let sharedDefaults = UserDefaults(suiteName: "group.blue.catbird.shared")
    
    enum FontFamily: String, CaseIterable {
        case system = "system"
        case inter = "inter"
        case atkinson = "atkinson"
        
        var displayName: String {
            switch self {
            case .system: return "SF Pro"
            case .inter: return "Inter"
            case .atkinson: return "Atkinson Hyperlegible"
            }
        }
    }
    
    enum LineSpacing: String, CaseIterable {
        case tight = "tight"
        case normal = "normal"
        case relaxed = "relaxed"
        
        var multiplier: CGFloat {
            switch self {
            case .tight: return 1.2
            case .normal: return 1.4
            case .relaxed: return 1.6
            }
        }
    }
    
    static let shared = WidgetFontManager()
    
    private init() {
        loadFontSettings()
    }
    
    /// Load font settings from shared UserDefaults
    private func loadFontSettings() {
        guard let sharedDefaults = sharedDefaults else { return }
        
        // Load font size scale (0.8 to 1.3 range)
        let sizeScale = sharedDefaults.double(forKey: "fontSizeScale")
        fontSizeScale = sizeScale > 0 ? sizeScale : 1.0
        
        // Load font family
        if let familyRaw = sharedDefaults.string(forKey: "fontFamily"),
           let family = FontFamily(rawValue: familyRaw) {
            fontFamily = family
        }
        
        // Load line spacing
        if let spacingRaw = sharedDefaults.string(forKey: "lineSpacing"),
           let spacing = LineSpacing(rawValue: spacingRaw) {
            lineSpacing = spacing
        }
    }
    
    /// Refresh font settings (call when widget updates)
    func refreshFontSettings() {
        loadFontSettings()
    }
    
    /// Get a scaled font for the given size and weight
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let scaledSize = size * fontSizeScale
        
        switch fontFamily {
        case .system:
            return .system(size: scaledSize, weight: weight, design: .default)
        case .inter:
            // In a real implementation, you'd load the Inter font family
            // For now, fallback to system with rounded design
            return .system(size: scaledSize, weight: weight, design: .rounded)
        case .atkinson:
            // In a real implementation, you'd load the Atkinson font
            // For now, fallback to system
            return .system(size: scaledSize, weight: weight, design: .default)
        }
    }
    
    /// Get line spacing for a given font size
    func getLineSpacing(for fontSize: CGFloat) -> CGFloat {
        let scaledSize = fontSize * fontSizeScale
        return (lineSpacing.multiplier - 1.0) * scaledSize
    }
}

// MARK: - Widget Text Roles

/// Text roles optimized for widget display
enum WidgetTextRole {
    case title
    case headline
    case subheadline
    case body
    case callout
    case caption
    case footnote
    case micro
    
    var fontSize: CGFloat {
        switch self {
        case .title: return WidgetDesignTokens.FontSize.title
        case .headline: return WidgetDesignTokens.FontSize.headline
        case .subheadline: return WidgetDesignTokens.FontSize.subheadline
        case .body: return WidgetDesignTokens.FontSize.body
        case .callout: return WidgetDesignTokens.FontSize.callout
        case .caption: return WidgetDesignTokens.FontSize.caption
        case .footnote: return WidgetDesignTokens.FontSize.small
        case .micro: return WidgetDesignTokens.FontSize.micro
        }
    }
    
    var weight: Font.Weight {
        switch self {
        case .title: return .bold
        case .headline: return .semibold
        case .subheadline: return .medium
        case .body: return .regular
        case .callout: return .medium
        case .caption: return .medium
        case .footnote: return .regular
        case .micro: return .medium
        }
    }
}

// MARK: - Widget Font Modifier

/// A view modifier that applies widget-specific font styling
struct WidgetFontModifier: ViewModifier {
    let role: WidgetTextRole
    let fontManager: WidgetFontManager
    
    func body(content: Content) -> some View {
        content
            .font(fontManager.scaledFont(size: role.fontSize, weight: role.weight))
            .lineSpacing(fontManager.getLineSpacing(for: role.fontSize))
    }
}

// MARK: - View Extensions for Widget Typography

extension View {
    /// Apply widget font styling with the given text role
    func widgetFont(_ role: WidgetTextRole, fontManager: WidgetFontManager = .shared) -> some View {
        self.modifier(WidgetFontModifier(role: role, fontManager: fontManager))
    }
    
    // Convenience methods for common text roles
    func widgetTitle(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.title, fontManager: fontManager)
    }
    
    func widgetHeadline(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.headline, fontManager: fontManager)
    }
    
    func widgetSubheadline(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.subheadline, fontManager: fontManager)
    }
    
    func widgetBody(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.body, fontManager: fontManager)
    }
    
    func widgetCallout(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.callout, fontManager: fontManager)
    }
    
    func widgetCaption(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.caption, fontManager: fontManager)
    }
    
    func widgetFootnote(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.footnote, fontManager: fontManager)
    }
    
    func widgetMicro(fontManager: WidgetFontManager = .shared) -> some View {
        self.widgetFont(.micro, fontManager: fontManager)
    }
    
    /// Apply custom widget font with size and weight
    func widgetCustomFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        fontManager: WidgetFontManager = .shared
    ) -> some View {
        self
            .font(fontManager.scaledFont(size: size, weight: weight))
            .lineSpacing(fontManager.getLineSpacing(for: size))
    }
}

// MARK: - Widget Accessibility Typography

extension View {
    /// Apply accessibility-aware text styling for widgets
    func widgetAccessibleText(
        role: WidgetTextRole,
        themeProvider: WidgetThemeProvider,
        fontManager: WidgetFontManager = .shared,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .widgetFont(role, fontManager: fontManager)
            .foregroundColor(.widgetPrimaryText(themeProvider, currentScheme: colorScheme))
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
    }
    
    /// Apply secondary text styling with proper color hierarchy
    func widgetSecondaryText(
        role: WidgetTextRole,
        themeProvider: WidgetThemeProvider,
        fontManager: WidgetFontManager = .shared,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .widgetFont(role, fontManager: fontManager)
            .foregroundColor(.widgetSecondaryText(themeProvider, currentScheme: colorScheme))
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
    }
    
    /// Apply tertiary text styling for less prominent content
    func widgetTertiaryText(
        role: WidgetTextRole,
        themeProvider: WidgetThemeProvider,
        fontManager: WidgetFontManager = .shared,
        colorScheme: ColorScheme
    ) -> some View {
        self
            .widgetFont(role, fontManager: fontManager)
            .foregroundColor(.widgetTertiaryText(themeProvider, currentScheme: colorScheme))
            .minimumScaleFactor(0.8)
            .allowsTightening(true)
    }
}

// MARK: - Widget Environment Values

private struct WidgetFontManagerKey: EnvironmentKey {
    static let defaultValue = WidgetFontManager.shared
}

private struct WidgetThemeProviderKey: EnvironmentKey {
    static let defaultValue = WidgetThemeProvider.shared
}

extension EnvironmentValues {
    var widgetFontManager: WidgetFontManager {
        get { self[WidgetFontManagerKey.self] }
        set { self[WidgetFontManagerKey.self] = newValue }
    }
    
    var widgetThemeProvider: WidgetThemeProvider {
        get { self[WidgetThemeProviderKey.self] }
        set { self[WidgetThemeProviderKey.self] = newValue }
    }
}
#endif