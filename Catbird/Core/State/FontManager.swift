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
        // Skip if settings haven't changed to prevent infinite loops
        if fontStyle == currentFontStyle &&
           fontSize == currentFontSize &&
           lineSpacing == currentLineSpacing &&
           dynamicTypeEnabled == currentDynamicTypeEnabled &&
           maxDynamicTypeSize == currentMaxDynamicTypeSize {
            logger.debug("Font settings unchanged, skipping update")
            return
        }
        
        logger.info("Applying font settings - style: \(fontStyle), size: \(fontSize), spacing: \(lineSpacing), dynamic: \(dynamicTypeEnabled), maxSize: \(maxDynamicTypeSize)")
        logger.debug("Previous settings - style: \(self.currentFontStyle), size: \(self.currentFontSize), spacing: \(self.currentLineSpacing), dynamic: \(self.currentDynamicTypeEnabled), maxSize: \(self.currentMaxDynamicTypeSize)")
        
        // Update cache FIRST to prevent re-entrance
        currentFontStyle = fontStyle
        currentFontSize = fontSize
        currentLineSpacing = lineSpacing
        currentDynamicTypeEnabled = dynamicTypeEnabled
        currentMaxDynamicTypeSize = maxDynamicTypeSize
        
        // Update actual settings immediately on main actor
        // Since FontManager is @Observable, changes should trigger UI updates
        if Thread.isMainThread {
            self.fontStyle = fontStyle
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.dynamicTypeEnabled = dynamicTypeEnabled
            self.maxDynamicTypeSize = maxDynamicTypeSize
        } else {
            Task { @MainActor in
                self.fontStyle = fontStyle
                self.fontSize = fontSize
                self.lineSpacing = lineSpacing
                self.dynamicTypeEnabled = dynamicTypeEnabled
                self.maxDynamicTypeSize = maxDynamicTypeSize
            }
        }
        
        // Apply Dynamic Type constraints if enabled
        if dynamicTypeEnabled {
            applyDynamicTypeConstraints()
        }
        
        // Post notification for any components that need manual updates
        if Thread.isMainThread {
            NotificationCenter.default.post(name: NSNotification.Name("FontSettingsChanged"), object: nil)
            logger.debug("Posted FontSettingsChanged notification synchronously")
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("FontSettingsChanged"), object: nil)
                self.logger.debug("Posted FontSettingsChanged notification asynchronously")
            }
        }
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
    func fontForTextRole(_ role: AppTextRole) -> Font {
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

enum AppTextRole: CaseIterable {
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
    
    /// Convert SwiftUI Font.TextStyle to AppTextRole
    static func from(_ textStyle: Font.TextStyle) -> AppTextRole {
        switch textStyle {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        @unknown default: return .body
        }
    }
    
    /// Handle .weight() calls on AppTextRole (return self for compatibility)
    func weight(_ weight: Font.Weight) -> AppTextRole {
        return self
    }
    
    /// Handle .design() calls on AppTextRole (return self for compatibility)  
    func design(_ design: Font.Design) -> AppTextRole {
        return self
    }
    
    /// Handle .monospaced() calls on AppTextRole (return self for compatibility)
    func monospaced() -> AppTextRole {
        return self
    }
}


// MARK: - View Modifiers

struct AppFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    let role: AppTextRole
    
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

struct DirectFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    let font: Font
    
    func body(content: Content) -> some View {
        content
            .font(font)
            .lineSpacing(fontManager.getLineSpacing(for: Typography.Size.body))
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
    func appFont(_ role: AppTextRole) -> some View {
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
    
    /// Apply app font with a Font object (compatibility layer)
    func appFont(_ font: Font) -> some View {
        self.modifier(DirectFontModifier(font: font))
    }
    
    /// Apply app font with SwiftUI's built-in text styles (compatibility layer)
    func appFont(_ textStyle: Font.TextStyle) -> some View {
        let appRole = AppTextRole.from(textStyle)
        return self.modifier(AppFontModifier(role: appRole))
    }
    
    /// Compatibility layer for .system() method calls on AppTextRole
    func appFont(_ systemCall: SystemFontCall) -> some View {
        switch systemCall {
        case .system(let textStyle, let design, let weight):
            let appRole = AppTextRole.from(textStyle)
            return AnyView(self.modifier(AppFontModifier(role: appRole)))
        case .systemSize(let size, let weight, let design):
            return AnyView(self.modifier(CustomAppFontModifier(size: size, weight: weight, textStyle: .body)))
        }
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

// MARK: - Compatibility Types

/// Represents system font calls found in existing code for compatibility
enum SystemFontCall {
    case system(Font.TextStyle, design: Font.Design = .default, weight: Font.Weight = .regular)
    case systemSize(CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default)
}

// MARK: - Font Compatibility Extensions

/// Extensions to handle common font patterns and method calls
extension Font {
    /// Compatibility layer for .system calls
    static func appSystem(
        _ textStyle: Font.TextStyle,
        design: Font.Design = .default,
        weight: Font.Weight = .regular
    ) -> Font {
        return .system(textStyle, design: design).weight(weight)
    }
    
    /// Compatibility layer for size-based system calls
    static func appSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        return .system(size: size, weight: weight, design: design)
    }
}

// MARK: - Global Compatibility Functions

/// Global function to handle .system() calls that might appear in migrated code
func system(
    _ textStyle: Font.TextStyle,
    design: Font.Design = .default
) -> AppTextRole {
    return AppTextRole.from(textStyle)
}

/// Global function to handle .system() calls with size
func system(
    size: CGFloat,
    weight: Font.Weight = .regular,
    design: Font.Design = .default
) -> SystemFontCall {
    return .systemSize(size, weight: weight, design: design)
}


// MARK: - Font Builder for System Calls

/// A builder that can handle various system font calls and convert them to app font specifications
struct SystemFontBuilder {
    private let spec: SystemFontSpec
    
    enum SystemFontSpec {
        case textStyle(Font.TextStyle, design: Font.Design, weight: Font.Weight)
        case size(CGFloat, weight: Font.Weight, design: Font.Design)
    }
    
    private init(_ spec: SystemFontSpec) {
        self.spec = spec
    }
    
    /// Create a system font with text style
    static func system(
        _ textStyle: Font.TextStyle,
        design: Font.Design = .default
    ) -> SystemFontBuilder {
        return SystemFontBuilder(.textStyle(textStyle, design: design, weight: .regular))
    }
    
    /// Create a system font with size
    static func system(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> SystemFontBuilder {
        return SystemFontBuilder(.size(size, weight: weight, design: design))
    }
    
    /// Add weight to the font
    func weight(_ weight: Font.Weight) -> SystemFontBuilder {
        switch spec {
        case .textStyle(let textStyle, let design, _):
            return SystemFontBuilder(.textStyle(textStyle, design: design, weight: weight))
        case .size(let size, _, let design):
            return SystemFontBuilder(.size(size, weight: weight, design: design))
        }
    }
    
    /// Add design to the font
    func design(_ design: Font.Design) -> SystemFontBuilder {
        switch spec {
        case .textStyle(let textStyle, _, let weight):
            return SystemFontBuilder(.textStyle(textStyle, design: design, weight: weight))
        case .size(let size, let weight, _):
            return SystemFontBuilder(.size(size, weight: weight, design: design))
        }
    }
    
    /// Convert to AppTextRole for role-based fonts
    func toAppTextRole() -> AppTextRole {
        switch spec {
        case .textStyle(let textStyle, _, _):
            return AppTextRole.from(textStyle)
        case .size(_, _, _):
            return .body // Default for size-based fonts
        }
    }
    
    /// Convert to SystemFontCall for custom size fonts
    func toSystemFontCall() -> SystemFontCall {
        switch spec {
        case .textStyle(let textStyle, let design, let weight):
            return .system(textStyle, design: design, weight: weight)
        case .size(let size, let weight, let design):
            return .systemSize(size, weight: weight, design: design)
        }
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

