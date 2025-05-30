//
//  Typography.swift
//  Catbird
//
//  Created by Josh LaCalamito on 2/25/25.
//

import SwiftUI
import UIKit

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
        width: CGFloat? = nil,
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

extension Font {
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
