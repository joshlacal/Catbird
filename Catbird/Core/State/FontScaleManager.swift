import SwiftUI
import OSLog

/// Manages font scaling based on user preferences
@Observable final class FontScaleManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "FontScaleManager")
    
    // MARK: - Properties
    
    /// Current font size setting
    var fontSize: String = "default"
    
    /// Current font style setting
    var fontStyle: String = "system"
    
    // MARK: - Caching Properties
    
    /// Cache current font settings to avoid redundant applications
    private var currentFontSize: String = ""
    private var currentFontStyle: String = ""
    
    // MARK: - Computed Properties
    
    /// Scale factor based on font size preference
    var sizeScale: CGFloat {
        let baseScale: CGFloat
        switch fontSize {
        case "small":
            baseScale = 0.85
        case "default":
            baseScale = 1.0
        case "large":
            baseScale = 1.15
        case "extraLarge":
            baseScale = 1.3
        default:
            baseScale = 1.0
        }

        // Apply additional scaling for Mac Catalyst
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Mac Catalyst needs larger base scaling due to display differences
            let catalystScale = baseScale * 1.2
            return catalystScale
        }
        #endif

        return baseScale
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
    
    // MARK: - Methods
    
    /// Apply font settings from AppSettings
    func applyFontSettings(fontSize: String, fontStyle: String) {
        // Skip if settings haven't changed
        if fontSize == currentFontSize && fontStyle == currentFontStyle {
            return
        }
        
        logger.info("Applying font settings - size: \(fontSize), style: \(fontStyle)")
        
        // Update cache
        currentFontSize = fontSize
        currentFontStyle = fontStyle
        
        // Update actual settings
        self.fontSize = fontSize
        self.fontStyle = fontStyle
    }
    
    /// Get scaled font size
    func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        return baseSize * sizeScale
    }
    
    /// Create a scaled system font
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle? = nil) -> Font {
        let scaledSize = self.scaledSize(size)
        
        if let textStyle = textStyle {
            // Use dynamic type scaling
            return Font.system(textStyle, design: fontDesign).weight(weight)
        } else {
            // Use fixed size with scale factor
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
            relativeTo: textStyle
        )
    }
}

// MARK: - Typography Extensions with Font Scaling

extension Typography {
    /// Scaled font sizes based on user preferences
    struct ScaledSize {
        let manager: FontScaleManager
        
        var micro: CGFloat { manager.scaledSize(Size.micro) }
        var caption: CGFloat { manager.scaledSize(Size.caption) }
        var footnote: CGFloat { manager.scaledSize(Size.footnote) }
        var subheadline: CGFloat { manager.scaledSize(Size.subheadline) }
        var body: CGFloat { manager.scaledSize(Size.body) }
        var headline: CGFloat { manager.scaledSize(Size.headline) }
        var callout: CGFloat { manager.scaledSize(Size.callout) }
        var title3: CGFloat { manager.scaledSize(Size.title3) }
        var title2: CGFloat { manager.scaledSize(Size.title2) }
        var title1: CGFloat { manager.scaledSize(Size.title1) }
        var largeTitle: CGFloat { manager.scaledSize(Size.largeTitle) }
    }
}

// MARK: - View Modifiers

struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScaleManager) private var fontScaleManager
    
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: Font.TextStyle?
    
    func body(content: Content) -> some View {
        content
            .font(fontScaleManager.scaledFont(size: size, weight: weight, relativeTo: textStyle))
    }
}

struct ScaledTextStyleModifier: ViewModifier {
    @Environment(\.fontScaleManager) private var fontScaleManager
    
    let textStyle: Font.TextStyle
    let weight: Font.Weight
    
    func body(content: Content) -> some View {
        content
            .font(fontScaleManager.scaledFont(size: 17, weight: weight, relativeTo: textStyle))
    }
}

// MARK: - Environment Key

private struct FontScaleManagerKey: EnvironmentKey {
    static let defaultValue = FontScaleManager()
}

extension EnvironmentValues {
    var fontScaleManager: FontScaleManager {
        get { self[FontScaleManagerKey.self] }
        set { self[FontScaleManagerKey.self] = newValue }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply scaled font based on user preferences
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, relativeTo textStyle: Font.TextStyle? = nil) -> some View {
        self.modifier(ScaledFontModifier(size: size, weight: weight, textStyle: textStyle))
    }
    
    /// Apply scaled text style based on user preferences
    func scaledTextStyle(_ textStyle: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        self.modifier(ScaledTextStyleModifier(textStyle: textStyle, weight: weight))
    }
    
    /// Provide font scale manager to the environment
    func fontScaleManager(_ manager: FontScaleManager) -> some View {
        self.environment(\.fontScaleManager, manager)
    }
}
