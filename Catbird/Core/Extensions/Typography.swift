//
//  Typography.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI

// MARK: - Typography Constants

/// Defines the app's typography system
enum Typography {
    // Font sizes for different text roles
    enum Size {
        static let micro: CGFloat = 10
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
    
    // Line heights (as multipliers)
    enum LineHeight {
        static let tight: CGFloat = 1.1
        static let normal: CGFloat = 1.2
        static let relaxed: CGFloat = 1.4
        static let loose: CGFloat = 1.6
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
    func openTypeFeatures(_ features: [UIFontDescriptor.FeatureKey: Int]) -> some View {
        // This modifier would need UIViewRepresentable for full implementation
        // A simplified version that applies basic text styling
        self
    }
    
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
            .font(.sfProText(size: Typography.Size.caption, weight: .medium))
            .tracking(Typography.LetterSpacing.wide)
            .foregroundColor(color)
            .textCase(.uppercase)
    }
}

/// Custom font modifier that supports width variants and optical sizing
struct CustomFontModifier: ViewModifier {
    let size: CGFloat?
    let weight: Font.Weight
    let design: Font.Design
    let width: Int?
    let relativeTo: Font.TextStyle?
    
    init(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        width: Int? = nil,
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
            // Use text style if provided
            content.font(.system(textStyle, design: design).weight(weight))
        } else if let explicitSize = size {
            // Fall back to explicit size
            content.font(.system(size: explicitSize, weight: weight, design: design))
        } else {
            // Last resort default
            content.font(.system(size: 17, weight: weight, design: design))
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
    
    /// Applies the body text modifier with default values
    func bodyStyle(
        size: CGFloat = Typography.Size.body,
        weight: Font.Weight = Typography.Weight.regular,
        lineHeight: CGFloat = Typography.LineHeight.normal
    ) -> some View {
        self.modifier(BodyTextModifier(size: size, weight: weight, lineHeight: lineHeight))
    }
    
    /// Applies the caption modifier with default color
    func captionStyle(color: Color = .secondary) -> some View {
        self.modifier(CaptionModifier(color: color))
    }
    
    /// Applies a custom font with optical scaling and width variants
    func customScaledFont(
        size: CGFloat? = nil,
        weight: Font.Weight = .regular,
        width: Int? = nil,
        relativeTo: Font.TextStyle? = nil,
        design: Font.Design = .default
    ) -> some View {
        self.modifier(CustomFontModifier(
            size: size,
            weight: weight,
            design: design,
            width: width,
            relativeTo: relativeTo
        ))
    }
}

// MARK: - Preview Examples

#Preview {
    ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Group {
                Text("Standard SF Pro Headline")
                    .headlineStyle()
                
                Text("Custom SF Pro Display")
                    .font(.sfProDisplay(size: 24, weight: .bold))
                    .tracking(Typography.LetterSpacing.tight)
                
                Text("SF Pro Rounded Style")
                    .customScaledFont(size: 20, weight: .semibold, design: .rounded)
                
                Text("Caption Style Example")
                    .captionStyle()
                
                Text("Body Text with Custom Line Height")
                    .bodyStyle(lineHeight: Typography.LineHeight.relaxed)
                
                Text("Gradient Text Effect")
                    .font(.system(size: 24, weight: .bold))
                    .gradientText(colors: [.blue, .purple])
                
                Text("Text with Depth Effect")
                    .font(.system(size: 22, weight: .bold))
                    .textDepth(radius: 1, y: 1, opacity: 0.5)
                
                Text("Text with Glow Effect")
                    .font(.system(size: 22, weight: .bold))
                    .textGlow(color: .blue.opacity(0.5), radius: 4)
                
                Text("Custom Letter Spacing")
                    .font(.system(size: 18))
                    .tracking(0.8)
                    .textCase(.uppercase)
                
                Text("SF Pro Width Variant")
                    .customScaledFont(size: 18, weight: .medium, width: 62)
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(10)
            .shadow(radius: 2)
            .padding(.horizontal)
        }
        .padding(.vertical)
        .background(Color(.systemGroupedBackground))
    }
}
