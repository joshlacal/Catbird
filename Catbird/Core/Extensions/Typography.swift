//
//  Typography.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
// MARK: - Typography Constants

/// Defines the app's typography system
/// 
/// ## Font System Overview
/// 
/// This typography system provides two complementary approaches:
/// 
/// ### 1. Traditional Typography (Direct Usage)
/// - Use `Typography.Size.*` constants for fixed font sizes
/// - Use view modifiers like `.textStyle()`, `.headlineStyle()`, `.bodyStyle()`
/// - These provide precise control but don't respond to user font preferences
/// 
/// ### 2. App Font System (Recommended)
/// - Use `.appBody()`, `.appHeadline()`, `.appTitle()` etc. for automatic scaling
/// - These respect user settings for:
///   - Font size preference (small, default, large, extra large)
///   - Font style preference (system, serif, rounded, monospaced)  
///   - Line spacing preference (tight, normal, relaxed)
///   - Dynamic Type accessibility settings
///   - Maximum Dynamic Type size limits
/// 
/// ### Accessibility Integration
/// 
/// The app font system automatically:
/// - Scales text based on user's font size preference (85% to 130%)
/// - Respects iOS Dynamic Type when `dynamicTypeEnabled` is true
/// - Constrains Dynamic Type to user's maximum preferred size
/// - Applies user's preferred font design (serif, rounded, etc.)
/// - Adjusts line spacing based on user preference
/// 
/// ### Usage Examples
/// 
/// ```swift
/// // Recommended: Respects all user preferences
/// Text("Title").appTitle()
/// Text("Body text").appBody()
/// Text("Custom").appText(size: 18, weight: .medium)
/// 
/// // Traditional: Fixed styling
/// Text("Fixed headline").headlineStyle()
/// Text("Fixed body").bodyStyle()
/// ```
/// 
/// The FontManager provides the bridge between user settings and font application.
enum Typography {
    // Font sizes for different text roles (normalized with 17pt body)
    enum Size {
        static let micro: CGFloat = 11
        static let caption: CGFloat = 12
        static let footnote: CGFloat = 13
        static let subheadline: CGFloat = 15
        static let body: CGFloat = 17
        static let headline: CGFloat = 17
        static let callout: CGFloat = 16
        static let title3: CGFloat = 20
        static let title2: CGFloat = 22
        static let title1: CGFloat = 28
        static let largeTitle: CGFloat = 34
    }
    
    // Font weights
    enum Weight {
        static let ultraLight = Font.Weight.ultraLight
        static let thin = Font.Weight.thin
        static let light = Font.Weight.light
        static let regular = Font.Weight.regular
        static let medium = Font.Weight.medium
        static let semibold = Font.Weight.semibold
        static let bold = Font.Weight.bold
        static let heavy = Font.Weight.heavy
        static let black = Font.Weight.black
    }
    
    // Font designs
    enum Design {
        case `default`
        case serif
        case rounded
        case monospaced
        
        var fontDesign: Font.Design {
            switch self {
            case .default: return .default
            case .serif: return .serif
            case .rounded: return .rounded
            case .monospaced: return .monospaced
            }
        }
    }
    
    // Line heights (as multipliers) - generous spacing for excellent readability
    enum LineHeight {
        static let tight: CGFloat = 1.3   // For headlines
        static let snug: CGFloat = 1.4    // For subheadings  
        static let normal: CGFloat = 1.5  // For UI text
        static let relaxed: CGFloat = 1.7 // For body reading
        static let loose: CGFloat = 1.9   // For long-form reading
    }
    
    // Letter spacing
    enum LetterSpacing {
        static let tighter: CGFloat = -0.5
        static let tight: CGFloat = -0.25
        static let normal: CGFloat = 0
        static let wide: CGFloat = 0.25
        static let wider: CGFloat = 0.5
    }
}

// MARK: - Font Extensions

extension Font {
    /// Creates an SF Pro font with specified size and weight
    static func sfPro(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .default)
    }
    
    /// Creates an SF Pro Rounded font with specified size and weight
    static func sfProRounded(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        return .system(size: size, weight: weight, design: .rounded)
    }
    
    /// Creates an SF Pro Text font optimized for smaller sizes
    static func sfProText(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // SF Pro Text is optimized for sizes below 20pt
        return .system(size: min(size, 19), weight: weight, design: .default)
    }
    
    /// Creates an SF Pro Display font optimized for larger sizes
    static func sfProDisplay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        // SF Pro Display is optimized for sizes 20pt and above
        return .system(size: max(size, 20), weight: weight, design: .default)
    }
    
    /// Creates a custom scaled font with specified width variant
    static func sfProWidth(size: CGFloat, weight: Font.Weight = .regular, width: Any? = nil) -> Font {
        // Width variants would need to be registered if using custom fonts
        return .system(size: size, weight: weight, design: .default)
    }
}

// MARK: - View Extensions for Typography

extension View {
    /// Applies a custom text style with SF Pro font
    func textStyle(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Typography.Design = .default,
        lineHeight: CGFloat = Typography.LineHeight.normal,
        letterSpacing: CGFloat = Typography.LetterSpacing.normal,
        isUppercased: Bool = false
    ) -> some View {
        self
            .font(.system(size: size, weight: weight, design: design.fontDesign))
            .lineSpacing((lineHeight - 1.0) * size)
            .tracking(letterSpacing)
            .textCase(isUppercased ? .uppercase : nil)
    }
    
    /// Applies text scaling more precisely than the default `.textScale` modifier
    func customTextScale(_ scale: CGFloat) -> some View {
        self.transformEffect(CGAffineTransform(scaleX: scale, y: scale))
    }
    
    /// Applies a modern gradient text effect
    func gradientText(colors: [Color]) -> some View {
        self.overlay(
            LinearGradient(
                gradient: Gradient(colors: colors),
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask(self)
        )
    }
    
    /// Applies a subtle shadow effect to text for depth
    func textDepth(radius: CGFloat = 0.5, y: CGFloat = 0.5, opacity: Double = 0.3) -> some View {
        self.shadow(color: .black.opacity(opacity), radius: radius, x: 0, y: y)
    }
    
    /// Applies a subtle glow effect to text
    func textGlow(color: Color = .white, radius: CGFloat = 2) -> some View {
        self.shadow(color: color, radius: radius)
    }
    
    /// Applies custom OpenType features to text (when available in the font)
    #if canImport(UIKit)
    func openTypeFeatures(_ features: [UIFontDescriptor.FeatureKey: Int]) -> some View {
        // This modifier would need UIViewRepresentable for full implementation
        // A simplified version that applies basic text styling
        self
    }
    #elseif canImport(AppKit)
    func openTypeFeatures(_ features: [NSFontDescriptor.FeatureKey: Int]) -> some View {
        // macOS version - simplified implementation
        self
    }
    #endif
    
    /// Applies kerning to specific letter pairs (a simplified version)
    func customKerning(pairs: [String: CGFloat]) -> some View {
        // This would need a custom text renderer for full implementation
        // A simplified version that applies general tracking
        self.tracking(pairs.values.first ?? 0)
    }
}

// MARK: - Custom Text Modifiers

/// Applies a modern headline style
struct HeadlineModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(.sfProDisplay(size: size, weight: weight))
            .tracking(Typography.LetterSpacing.tight)
            .lineSpacing((Typography.LineHeight.normal - 1.0) * size)
            .foregroundColor(color)
            .textDepth()
    }
}

/// Applies a modern body text style
struct BodyTextModifier: ViewModifier {
    let size: CGFloat
    let weight: Font.Weight
    let lineHeight: CGFloat
    
    func body(content: Content) -> some View {
        content
            .font(.sfProText(size: size, weight: weight))
            .tracking(Typography.LetterSpacing.normal)
            .lineSpacing((lineHeight - 1.0) * size)
            .allowsTightening(true)
            .minimumScaleFactor(0.9)
    }
}

/// Applies a caption text style
struct CaptionModifier: ViewModifier {
    let color: Color
    
    func body(content: Content) -> some View {
        content
            .font(.sfProText(size: Typography.Size.caption, weight: Typography.Weight.medium))
            .tracking(Typography.LetterSpacing.wide)
            .foregroundColor(color)
            .textCase(.uppercase)
    }
}

/// Custom font modifier that supports width variants and optical sizing (legacy)
struct CustomFontModifier: ViewModifier {
    let size: CGFloat?
    let weight: Font.Weight
    let design: Font.Design
    let width: CGFloat?   // Note: Changed type to CGFloat for precision control
    let relativeTo: Font.TextStyle?
    
    init(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        width: CGFloat? = nil,
        relativeTo: Font.TextStyle? = nil
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.width = width
        self.relativeTo = relativeTo
    }
    
    func body(content: Content) -> some View {
        if let textStyle = relativeTo {
            content.font(.system(textStyle, design: design).weight(weight))
        } else if let explicitSize = size {
            // Use our custom font if a width is provided.
            if let width = width {
                content.font(Font.customSystemFont(size: explicitSize, weight: weight, width: width, design: design))
            } else {
                content.font(.system(size: explicitSize, weight: weight, design: design))
            }
        } else {
            content.font(.system(size: 17, weight: weight, design: design))
        }
    }
}

/// FontManager-integrated custom font modifier that supports width variants and accessibility scaling
struct FontManagerCustomFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    let size: CGFloat?
    let weight: Font.Weight
    let design: Font.Design
    let width: CGFloat?
    let relativeTo: Font.TextStyle?
    
    init(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        width: CGFloat? = nil,
        relativeTo: Font.TextStyle? = nil
    ) {
        self.size = size
        self.weight = weight
        self.design = design
        self.width = width
        self.relativeTo = relativeTo
    }
    
    func body(content: Content) -> some View {
        content
            .font(createFont())
            .lineSpacing(fontManager.getLineSpacing(for: effectiveSize))
    }
    
    private var effectiveSize: CGFloat {
        return size ?? Typography.Size.body
    }
    
    private func createFont() -> Font {
        let baseSize = effectiveSize
        
        if let width = width {
            // Use FontManager's scaledCustomFont which handles width variants
            return fontManager.scaledCustomFont(
                size: baseSize,
                weight: weight,
                width: width,
                relativeTo: relativeTo
            )
        } else {
            // Use FontManager's regular scaledFont
            return fontManager.scaledFont(
                size: baseSize,
                weight: weight,
                relativeTo: relativeTo
            )
        }
    }
}

// MARK: - Extension helpers for the modifiers

extension View {
    /// Applies the headline modifier with default values
    func headlineStyle(
        size: CGFloat = Typography.Size.headline,
        weight: Font.Weight = Typography.Weight.semibold,
        color: Color = .primary
    ) -> some View {
        self.modifier(HeadlineModifier(size: size, weight: weight, color: color))
    }
    
    /// Applies the body text modifier with default values - optimized for readability
    func bodyStyle(
        size: CGFloat = Typography.Size.body,
        weight: Font.Weight = Typography.Weight.regular,
        lineHeight: CGFloat = Typography.LineHeight.relaxed  // Better for reading
    ) -> some View {
        self.modifier(BodyTextModifier(size: size, weight: weight, lineHeight: lineHeight))
    }
    
    /// Applies the caption modifier with default color
    func captionStyle(color: Color = .secondary) -> some View {
        self.modifier(CaptionModifier(color: color))
    }
    
    // MARK: - App Font Helpers
    
    /// Quick helpers for common text roles using the app font system
    /// These automatically respect user font size, style, and accessibility preferences
    func appHeadline() -> some View {
        self.appFont(AppTextRole.headline)
    }
    
    func appTitle() -> some View {
        self.appFont(AppTextRole.title1)
    }
    
    func appBody() -> some View {
        self.appFont(AppTextRole.body)
    }
    
    func appCaption() -> some View {
        self.appFont(AppTextRole.caption)
    }
    
    func appSubheadline() -> some View {
        self.appFont(AppTextRole.subheadline)
    }
    
    func appLargeTitle() -> some View {
        self.appFont(AppTextRole.largeTitle)
    }
    
    func appTitle2() -> some View {
        self.appFont(AppTextRole.title2)
    }
    
    func appTitle3() -> some View {
        self.appFont(AppTextRole.title3)
    }
    
    func appCallout() -> some View {
        self.appFont(AppTextRole.callout)
    }
    
    func appFootnote() -> some View {
        self.appFont(AppTextRole.footnote)
    }
    
    func appCaption2() -> some View {
        self.appFont(AppTextRole.caption2)
    }
    
    /// Apply app text style with custom parameters
    /// Respects user font preferences while allowing customization
    func appText(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle? = .body
    ) -> some View {
        self.appFont(size: size, weight: weight, relativeTo: textStyle)
            .appLineSpacing()
    }
    
    /// Applies a custom font with optical scaling and width variants
    /// This version integrates with FontManager for proper accessibility scaling
    func customScaledFont(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        width: CGFloat? = nil,
        relativeTo: Font.TextStyle? = nil,
        design: Font.Design = .default
    ) -> some View {
        self.modifier(FontManagerCustomFontModifier(
            size: size,
            weight: weight,
            design: design,
            width: width,
            relativeTo: relativeTo
        ))
    }
    
    // MARK: - Design Tokens Integration with FontManager
    
    /// Enhanced app body that uses design tokens for consistent typography
    /// while preserving FontManager scaling and accessibility features
    func enhancedAppBody() -> some View {
        self.modifier(AppFontModifier(role: AppTextRole.body))
            .tracking(Typography.LetterSpacing.normal)
    }
    
    /// Enhanced app headline with design token typography principles
    func enhancedAppHeadline() -> some View {
        self.modifier(AppFontModifier(role: AppTextRole.headline))
            .tracking(Typography.LetterSpacing.tight)
    }
    
    /// Enhanced app subheadline with consistent letter spacing
    func enhancedAppSubheadline() -> some View {
        self.modifier(AppFontModifier(role: AppTextRole.subheadline))
            .tracking(Typography.LetterSpacing.normal)
    }
    
    /// Enhanced app caption with proper letter spacing
    func enhancedAppCaption() -> some View {
        self.modifier(AppFontModifier(role: AppTextRole.caption))
            .tracking(Typography.LetterSpacing.wide)
    }
    
    // MARK: - Legacy Token Helpers (for non-accessibility critical areas)
    
    /// Quick typography using design tokens - USE SPARINGLY
    /// Only for decorative text that doesn't need accessibility scaling
    func tokenText(
        size: CGFloat,
        weight: Font.Weight = .regular,
        lineHeight: CGFloat = Typography.LineHeight.normal,
        letterSpacing: CGFloat = Typography.LetterSpacing.normal
    ) -> some View {
        self
            .font(.system(size: size, weight: weight))
            .lineSpacing((lineHeight - 1.0) * size)
            .tracking(letterSpacing)
    }
    
    /// Fixed body text - USE ONLY for decorative elements
    func tokenBody() -> some View {
        self.tokenText(
            size: Typography.Size.body,
            weight: .regular,
            lineHeight: Typography.LineHeight.relaxed
        )
    }
}

extension Font {
    #if canImport(UIKit) && (os(iOS) || targetEnvironment(macCatalyst))
    /// Creates a dynamic font that hijacks iOS Dynamic Type to use app-specific base sizes
    /// This allows us to combine user's app font size preference with Dynamic Type scaling
    /// Works on both iOS and Mac Catalyst
    static func customDynamicFont(
        baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle,
        maxContentSizeCategory: CrossPlatformContentSizeCategory? = nil
    ) -> Font {
        #if targetEnvironment(macCatalyst)
        // On Mac Catalyst, use fixed-size font to respect app's custom sizing
        // System Dynamic Type behaves differently on Catalyst and conflicts with app preferences
        return .system(size: baseSize, weight: weight, design: design)
        #else
        // Map SwiftUI text style to UIFont text style
        let uiTextStyle: UIFont.TextStyle
        switch textStyle {
        case .largeTitle: uiTextStyle = .largeTitle
        case .title: uiTextStyle = .title1
        case .title2: uiTextStyle = .title2
        case .title3: uiTextStyle = .title3
        case .headline: uiTextStyle = .headline
        case .subheadline: uiTextStyle = .subheadline
        case .body: uiTextStyle = .body
        case .callout: uiTextStyle = .callout
        case .footnote: uiTextStyle = .footnote
        case .caption: uiTextStyle = .caption1
        case .caption2: uiTextStyle = .caption2
        @unknown default: uiTextStyle = .body
        }
        
        // Convert SwiftUI weight to UIFont weight
        let uiWeight: UIFont.Weight
        switch weight {
        case .ultraLight: uiWeight = .ultraLight
        case .thin: uiWeight = .thin
        case .light: uiWeight = .light
        case .regular: uiWeight = .regular
        case .medium: uiWeight = .medium
        case .semibold: uiWeight = .semibold
        case .bold: uiWeight = .bold
        case .heavy: uiWeight = .heavy
        case .black: uiWeight = .black
        default: uiWeight = .regular
        }
        
        // Convert SwiftUI design to UIFont design
        let uiDesign: UIFontDescriptor.SystemDesign
        switch design {
        case .default: uiDesign = .default
        case .serif: uiDesign = .serif
        case .rounded: uiDesign = .rounded
        case .monospaced: uiDesign = .monospaced
        @unknown default: uiDesign = .default
        }
        
        // Create base font with our custom size
        let baseFont = UIFont.systemFont(ofSize: baseSize, weight: uiWeight)
        let descriptor = baseFont.fontDescriptor.withDesign(uiDesign) ?? baseFont.fontDescriptor
        let customBaseFont = UIFont(descriptor: descriptor, size: baseSize)
        
        // Use UIFontMetrics to scale our custom base font with Dynamic Type
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle)
        
        // Apply maximum content size category constraint if provided
        if let maxCategory = maxContentSizeCategory {
            let maxUICategory = maxCategory.uiContentSizeCategory
            let scaledFont = metrics.scaledFont(for: customBaseFont, maximumPointSize: UIFont.preferredFont(forTextStyle: uiTextStyle, compatibleWith: UITraitCollection(preferredContentSizeCategory: maxUICategory)).pointSize)
            return Font(scaledFont)
        } else {
            let scaledFont = metrics.scaledFont(for: customBaseFont)
            return Font(scaledFont)
        }
        #endif
    }
    
    /// Creates a custom system font that supports width variants and dynamic type scaling.
    /// - Parameters:
    ///   - size: The base font size.
    ///   - weight: The font weight.
    ///   - width: The width trait adjustment (if nil, it uses standard width).
    ///   - design: The font design.
    ///   - relativeTo: The SwiftUI text style to scale relative to.
    /// - Returns: A SwiftUI Font that scales dynamically.
    static func customSystemFont(
        size: CGFloat,
        weight: Font.Weight,
        width: CGFloat = 120, 
        opticalSize: Bool = true, // Whether to apply optical size adjustments
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> Font {
        // Define the OpenType variation axes as hex integers (4-char codes)
        let wdthAxisID: Int = 0x77647468 // 'wdth' in hex
        let wghtAxisID: Int = 0x77676874 // 'wght' in hex
        let opszAxisID: Int = 0x6F70737A // 'opsz' in hex
        
        // Convert SwiftUI weight to numeric weight
        let numericWeight: CGFloat = {
            switch weight {
            case .ultraLight: return 100.0
            case .thin:       return 200.0
            case .light:      return 300.0
            case .regular:    return 400.0
            case .medium:     return 500.0
            case .semibold:   return 600.0
            case .bold:       return 700.0
            case .heavy:      return 800.0
            case .black:      return 900.0
            default:          return 400.0
            }
        }()
        
        // Create variations dictionary
        var variations: [Int: Any] = [
            wdthAxisID: width,
            wghtAxisID: numericWeight
        ]
        
        // Add optical size if enabled
        if opticalSize {
            variations[opszAxisID] = Double(size)
        }
        
        // Start with the system font
        let baseFont = UIFont.systemFont(ofSize: size)
        let fontDesc = baseFont.fontDescriptor
        
        // Apply the variations to the font descriptor
        let variableDescriptor = fontDesc.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: variations
        ])
        
        // Create the font with the modified descriptor
        let customUIFont = UIFont(descriptor: variableDescriptor, size: 0)
        
        // If a text style is provided, scale using UIFontMetrics
        if let textStyle = textStyle {
            // Map SwiftUI Font.TextStyle to UIFont.TextStyle
            let uiTextStyle: UIFont.TextStyle
            switch textStyle {
            case .largeTitle: uiTextStyle = .largeTitle
            case .title:      uiTextStyle = .title1
            case .title2:     uiTextStyle = .title2
            case .title3:     uiTextStyle = .title3
            case .headline:   uiTextStyle = .headline
            case .subheadline: uiTextStyle = .subheadline
            case .body:       uiTextStyle = .body
            case .callout:    uiTextStyle = .callout
            case .footnote:   uiTextStyle = .footnote
            case .caption:    uiTextStyle = .caption1
            case .caption2:   uiTextStyle = .caption2
            default:          uiTextStyle = .body
            }
            
            let metrics = UIFontMetrics(forTextStyle: uiTextStyle)
            let scaledFont = metrics.scaledFont(for: customUIFont)
            return Font(scaledFont)
        } else {
            // Fallback to no scaling
            return Font(customUIFont)
        }
    }
    
    #elseif canImport(AppKit) && os(macOS) && !targetEnvironment(macCatalyst)

    /// macOS version - simplified dynamic font (pure macOS only, not Mac Catalyst)
    static func customDynamicFont(
        baseSize: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle,
        maxContentSizeCategory: CrossPlatformContentSizeCategory? = nil
    ) -> Font {
        // On macOS, apply a simple scale factor based on the maxContentSizeCategory if provided
        let scaledSize = maxContentSizeCategory?.scaleFactor ?? 1.0
        return .system(size: baseSize * scaledSize, weight: weight, design: design)
    }
    
    /// macOS version - simplified custom system font (pure macOS only, not Mac Catalyst)
    static func customSystemFont(
        size: CGFloat,
        weight: Font.Weight,
        width: CGFloat = 120,
        opticalSize: Bool = true,
        design: Font.Design = .default,
        relativeTo textStyle: Font.TextStyle? = nil
    ) -> Font {
        return .system(size: size, weight: weight, design: design)
    }
    
    #endif
}

// MARK: - Accessibility-Aware Text Modifiers

extension View {
    /// Apply accessibility-aware text styling that respects contrast and bold text settings
    func accessibleText(appState: AppState?) -> some View {
        self.modifier(AccessibleTextModifier(appState: appState))
    }
    
    /// Apply comprehensive accessibility styling including font, contrast, and scaling
    func accessibilityStyledText(appState: AppState?) -> some View {
        self.modifier(ComprehensiveAccessibilityModifier(appState: appState))
    }
}

/// A view modifier that applies accessibility text settings
struct AccessibleTextModifier: ViewModifier {
    let appState: AppState?
    
    func body(content: Content) -> some View {
        let settings = appState?.appSettings
        let shouldIncreaseContrast = settings?.increaseContrast ?? false
        let shouldUseBoldText = settings?.boldText ?? false
        
        content
            .fontWeight(adjustedFontWeight(shouldUseBoldText: shouldUseBoldText))
            .foregroundStyle(shouldIncreaseContrast ? Color.adaptiveForeground(appState: appState, defaultColor: .primary) : Color.primary)
            .contrastAwareBackground(appState: appState, defaultColor: .clear)
    }
    
    private func adjustedFontWeight(shouldUseBoldText: Bool) -> Font.Weight {
        guard shouldUseBoldText else { return .regular }
        
        // Apply appropriate bold weight adjustment
        // Use semibold to avoid making text too heavy
        return .semibold
    }
}

/// A comprehensive view modifier that applies all accessibility settings
struct ComprehensiveAccessibilityModifier: ViewModifier {
    let appState: AppState?
    
    func body(content: Content) -> some View {
        let settings = appState?.appSettings
        let shouldIncreaseContrast = settings?.increaseContrast ?? false
        let shouldUseBoldText = settings?.boldText ?? false
        
        content
            .fontWeight(shouldUseBoldText ? .semibold : .regular)
            .foregroundStyle(shouldIncreaseContrast ? Color.adaptiveForeground(appState: appState, defaultColor: .primary) : Color.primary)
            .contrastAwareBackground(appState: appState, defaultColor: .clear)
    }
}

// MARK: - Preview Examples

#Preview("Typography System") {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            // Traditional Typography Examples
            Group {
                Text("Traditional Typography Examples")
                    .appTitle2()
                    .fontWeight(.bold)
                    .padding(.bottom, 8)
                
                Text("Standard SF Pro Headline")
                    .headlineStyle()
                
                Text("Custom SF Pro Display")
                    .font(.sfProDisplay(size: 24, weight: Typography.Weight.bold))
                    .tracking(Typography.LetterSpacing.tight)
                
                Text("SF Pro Rounded Style")
                    .customScaledFont(size: 20, weight: .semibold, design: .rounded)
                
                Text("Caption Style Example")
                    .captionStyle()
                
                Text("Body Text with Custom Line Height")
                    .bodyStyle(lineHeight: Typography.LineHeight.relaxed)
            }
            .padding()
            #if os(iOS)
            .background(Color.systemBackground)
            #elseif os(macOS)
            .background(Color(.windowBackgroundColor))
            #endif
            .cornerRadius(10)
            .shadow(radius: 1)
            .padding(.horizontal)
            
            // New App Font System Examples
            Group {
                Text("App Font System (Accessibility-Aware)")
                    .appTitle2()
                    .fontWeight(.bold)
                    .padding(.bottom, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("App Large Title")
                        .appLargeTitle()
                    
                    Text("App Title")
                        .appTitle()
                    
                    Text("App Title 2")
                        .appTitle2()
                    
                    Text("App Title 3")
                        .appTitle3()
                    
                    Text("App Headline")
                        .appHeadline()
                    
                    Text("App Subheadline")
                        .appSubheadline()
                    
                    Text("App Body Text - This text automatically scales with user font size preferences, respects Dynamic Type settings, and adapts to the user's chosen font style.")
                        .appBody()
                    
                    Text("App Callout")
                        .appCallout()
                    
                    Text("App Footnote")
                        .appFootnote()
                    
                    Text("App Caption")
                        .appCaption()
                    
                    Divider()
                    
                    Text("Custom App Text (20pt, medium weight)")
                        .appText(size: 20, weight: .medium)
                    
                    Text("Accessibility-optimized text that respects user preferences")
                        .appFont(AppTextRole.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            #if os(iOS)
            .background(Color.systemBackground)
            #elseif os(macOS)
            .background(Color(.windowBackgroundColor))
            #endif
            .cornerRadius(10)
            .shadow(radius: 1)
            .padding(.horizontal)
            
            // Effects Examples
            Group {
                Text("Text Effects")
                    .appTitle2()
                    .fontWeight(.bold)
                    .padding(.bottom, 8)
                
                Text("Gradient Text Effect")
                    .appHeadline()
                    .gradientText(colors: [.blue, .purple])
                
                Text("Text with Depth Effect")
                    .appHeadline()
                    .textDepth(radius: 1, y: 1, opacity: 0.5)
                
                Text("Text with Glow Effect")
                    .appHeadline()
                    .textGlow(color: .blue.opacity(0.5), radius: 4)
                
                Text("CUSTOM LETTER SPACING")
                    .appBody()
                    .tracking(0.8)
                    .textCase(.uppercase)
            }
            .padding()
            #if os(iOS)
            .background(Color.systemBackground)
            #elseif os(macOS)
            .background(Color(.windowBackgroundColor))
            #endif
            .cornerRadius(10)
            .shadow(radius: 1)
            .padding(.horizontal)
        }
        .padding(.vertical)
        #if os(iOS)
        .background(Color.systemGroupedBackground)
        #elseif os(macOS)
        .background(Color(.controlBackgroundColor))
        #endif
    }
    .environment(\.fontManager, FontManager()) // Provide default FontManager for preview
}
/*
extension Font {
    /// Creates a custom font that supports a width variant by leveraging UIKit's UIFontDescriptor.
    /// - Parameters:
    ///   - size: The font size.
    ///   - weight: The font weight.
    ///   - width: A CGFloat representing the width trait. Negative values produce a condensed variant, while positive values produce an expanded variant.
    ///   - design: The font design (default, serif, rounded, monospaced).
    /// - Returns: A SwiftUI Font that applies the specified width variant.
    static func customSystemFont(size: CGFloat, weight: Font.Weight, width: CGFloat? = nil, design: Font.Design = .default) -> Font {
        // If no width is provided, fallback to the standard system font.
        guard let width = width else {
            return .system(size: size, weight: weight, design: design)
        }
        
        // Convert SwiftUI weight to UIFont.Weight
        let uiWeight: UIFont.Weight = {
            switch weight {
            case .ultraLight: return .ultraLight
            case .thin:       return .thin
            case .light:      return .light
            case .regular:    return .regular
            case .medium:     return .medium
            case .semibold:   return .semibold
            case .bold:       return .bold
            case .heavy:      return .heavy
            case .black:      return .black
            default:          return .regular
            }
        }()
        
        // Create the base UIFont from the system font.
        let baseUIFont = UIFont.systemFont(ofSize: size, weight: uiWeight)
        
        // Create a new font descriptor by adding the width trait.
        let traits: [UIFontDescriptor.TraitKey: Any] = [.width: width]
        let descriptor = baseUIFont.fontDescriptor.addingAttributes([UIFontDescriptor.AttributeName.traits: traits])
        
        // Create a new UIFont with the modified descriptor.
        let customUIFont = UIFont(descriptor: descriptor, size: size)
        
        // Convert it to SwiftUI Font.
        return Font(customUIFont)
    }
}
*/
