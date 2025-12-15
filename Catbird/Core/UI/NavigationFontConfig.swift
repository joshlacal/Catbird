#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import CoreText
import SwiftUI

/// Centralized navigation font configuration to ensure consistency across the app
enum NavigationFontConfig {
    #if os(iOS)

    // MARK: - Font Cache

    /// Cached title font to avoid expensive Core Text operations
    private static var cachedTitleFont: UIFont?
    /// Cached large title font to avoid expensive Core Text operations
    private static var cachedLargeTitleFont: UIFont?

    /// Cache validation properties
    private static var lastFontDesign: Font.Design?
    private static var lastFontSize: CGFloat?
    private static var lastDynamicTypeEnabled: Bool?
    private static var lastMaxContentSizeCategory: String?

    /// Invalidate font cache when font settings change
    static func invalidateCache() {
        cachedTitleFont = nil
        cachedLargeTitleFont = nil
        lastFontDesign = nil
        lastFontSize = nil
        lastDynamicTypeEnabled = nil
        lastMaxContentSizeCategory = nil
    }

    /// Check if cache is valid for current FontManager settings
    private static func isCacheValid(for fontManager: FontManager) -> Bool {
        return lastFontDesign == fontManager.fontDesign &&
               lastFontSize == fontManager.sizeScale &&
               lastDynamicTypeEnabled == fontManager.dynamicTypeEnabled &&
               lastMaxContentSizeCategory == fontManager.maxContentSizeCategory.rawValue
    }

    /// Update cache validation properties
    private static func updateCacheValidation(for fontManager: FontManager) {
        lastFontDesign = fontManager.fontDesign
        lastFontSize = fontManager.sizeScale
        lastDynamicTypeEnabled = fontManager.dynamicTypeEnabled
        lastMaxContentSizeCategory = fontManager.maxContentSizeCategory.rawValue
    }

    /// Creates the custom large title font with Core Text variations and FontManager integration
    static func createLargeTitleFont(fontManager: FontManager) -> UIFont {
        // Check cache validity first to avoid expensive Core Text operations
        if isCacheValid(for: fontManager), let cached = cachedLargeTitleFont {
            return cached
        }

        let baseLargeTitleSize: CGFloat = 28
        let scaledSize = fontManager.scaledSize(baseLargeTitleSize)

        // Define the OpenType variation axes as hex integers (4-char codes)
        let wdthAxisID: Int = 0x7764_7468  // 'wdth' in hex
        let wghtAxisID: Int = 0x7767_6874  // 'wght' in hex
        let opszAxisID: Int = 0x6F70_737A  // 'opsz' in hex

        // Convert FontManager's font design to numeric weight
        let baseWeight: CGFloat = 700.0 // Bold for large titles
        let adjustedWeight = adjustWeightForFontStyle(baseWeight, fontManager: fontManager)

        // Create variations dictionary for large title
        let largeTitleVariations: [Int: Any] = [
            wdthAxisID: 120,  // Width: 120% (expanded)
            wghtAxisID: adjustedWeight,  // Weight: Adjusted based on FontManager
            opszAxisID: Double(scaledSize)  // Optical size matching scaled point size
        ]

        // Start with the system font using FontManager's design
        let baseFont = createBaseFontWithDesign(size: scaledSize, design: fontManager.fontDesign)
        let largeTitleFontDesc = baseFont.fontDescriptor

        // Apply the variations to the font descriptor
        let largeTitleDescriptor = largeTitleFontDesc.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: largeTitleVariations
        ])

        // Create the font with the modified descriptor
        let customUIFont = UIFont(descriptor: largeTitleDescriptor, size: 0)

        // Scale for accessibility if FontManager has Dynamic Type enabled
        let finalFont: UIFont
        if fontManager.dynamicTypeEnabled {
            let metrics = UIFontMetrics(forTextStyle: .largeTitle)
            let maxPointSize = UIFont.preferredFont(
                forTextStyle: .largeTitle,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: fontManager.maxContentSizeCategory.uiContentSizeCategory)
            ).pointSize
            finalFont = metrics.scaledFont(for: customUIFont, maximumPointSize: maxPointSize)
        } else {
            finalFont = customUIFont
        }

        // Update cache
        cachedLargeTitleFont = finalFont
        updateCacheValidation(for: fontManager)

        return finalFont
    }
    
    /// Creates the custom title font with Core Text variations and FontManager integration
    static func createTitleFont(fontManager: FontManager) -> UIFont {
        // Check cache validity first to avoid expensive Core Text operations
        if isCacheValid(for: fontManager), let cached = cachedTitleFont {
            return cached
        }

        let baseTitleSize: CGFloat = 17
        let scaledSize = fontManager.scaledSize(baseTitleSize)

        // Define the OpenType variation axes as hex integers (4-char codes)
        let wdthAxisID: Int = 0x7764_7468  // 'wdth' in hex
        let wghtAxisID: Int = 0x7767_6874  // 'wght' in hex
        let opszAxisID: Int = 0x6F70_737A  // 'opsz' in hex

        // Convert FontManager's font design to numeric weight
        let baseWeight: CGFloat = 600.0 // Semibold for titles
        let adjustedWeight = adjustWeightForFontStyle(baseWeight, fontManager: fontManager)

        // Create variations dictionary for title
        let titleVariations: [Int: Any] = [
            wdthAxisID: 120,  // Width: 120% (expanded)
            wghtAxisID: adjustedWeight,  // Weight: Adjusted based on FontManager
            opszAxisID: Double(scaledSize)  // Optical size matching scaled point size
        ]

        let titleFontDesc = createBaseFontWithDesign(size: scaledSize, design: fontManager.fontDesign).fontDescriptor
        let titleDescriptor = titleFontDesc.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: titleVariations
        ])

        let customTitleFont = UIFont(descriptor: titleDescriptor, size: 0)

        // Scale for accessibility if FontManager has Dynamic Type enabled
        let finalFont: UIFont
        if fontManager.dynamicTypeEnabled {
            let metrics = UIFontMetrics(forTextStyle: .headline)
            let maxPointSize = UIFont.preferredFont(
                forTextStyle: .headline,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: fontManager.maxContentSizeCategory.uiContentSizeCategory)
            ).pointSize
            finalFont = metrics.scaledFont(for: customTitleFont, maximumPointSize: maxPointSize)
        } else {
            finalFont = customTitleFont
        }

        // Update cache
        cachedTitleFont = finalFont
        updateCacheValidation(for: fontManager)

        return finalFont
    }
    
    /// Creates the custom large title font with Core Text variations (legacy method for backward compatibility)
    static func createLargeTitleFont() -> UIFont {
        // Use default FontManager instance for backward compatibility
        return createLargeTitleFont(fontManager: FontManager())
    }
    
    /// Creates the custom title font with Core Text variations (legacy method for backward compatibility)
    static func createTitleFont() -> UIFont {
        // Use default FontManager instance for backward compatibility
        return createTitleFont(fontManager: FontManager())
    }
    
    // MARK: - Helper Methods
    
    /// Create a base font with the specified design
    private static func createBaseFontWithDesign(size: CGFloat, design: Font.Design) -> UIFont {
        let uiDesign: UIFontDescriptor.SystemDesign
        switch design {
        case .serif: uiDesign = .serif
        case .rounded: uiDesign = .rounded
        case .monospaced: uiDesign = .monospaced
        default: uiDesign = .default
        }
        
        let baseFont = UIFont.systemFont(ofSize: size)
        if let descriptor = baseFont.fontDescriptor.withDesign(uiDesign) {
            return UIFont(descriptor: descriptor, size: size)
        } else {
            return baseFont
        }
    }
    
    /// Adjust weight based on font style preference (serif fonts typically need slightly lighter weights)
    private static func adjustWeightForFontStyle(_ baseWeight: CGFloat, fontManager: FontManager) -> CGFloat {
        switch fontManager.fontDesign {
        case .serif:
            // Serif fonts often look heavier, so reduce weight slightly
            return max(baseWeight - 100, 400) // Reduce by 100, but never go below regular (400)
        case .rounded:
            // Rounded fonts can handle slightly more weight
            return min(baseWeight + 50, 900) // Increase by 50, but never exceed black (900)
        case .monospaced:
            // Monospaced fonts work well with standard weights
            return baseWeight
        default:
            return baseWeight
        }
    }
    
    /// Apply custom fonts to a navigation bar appearance with FontManager integration
    static func applyFonts(to appearance: UINavigationBarAppearance, fontManager: FontManager) {
        // Get the custom fonts with FontManager integration
        let titleFont = createTitleFont(fontManager: fontManager)
        let largeTitleFont = createLargeTitleFont(fontManager: fontManager)
        
        // Update title attributes while preserving other attributes
        var titleAttrs = appearance.titleTextAttributes
        titleAttrs[.font] = titleFont
        appearance.titleTextAttributes = titleAttrs
        
        // Update large title attributes while preserving other attributes
        var largeTitleAttrs = appearance.largeTitleTextAttributes
        largeTitleAttrs[.font] = largeTitleFont
        appearance.largeTitleTextAttributes = largeTitleAttrs
    }
    
    /// Apply custom fonts to a navigation bar appearance (legacy method for backward compatibility)
    static func applyFonts(to appearance: UINavigationBarAppearance) {
        // Use default FontManager instance for backward compatibility
        applyFonts(to: appearance, fontManager: FontManager())
    }
    
    /// Force apply fonts to all current navigation bars in the app with FontManager integration
    /// Call this after theme changes to ensure fonts are respected
    static func forceApplyToAllNavigationBars(fontManager: FontManager) {
        // Ensure we're on the main thread for all UI operations
        if Thread.isMainThread {
            performFontUpdate(fontManager: fontManager)
        } else {
            DispatchQueue.main.async {
                performFontUpdate(fontManager: fontManager)
            }
        }
    }
    
    /// Force apply fonts to all current navigation bars in the app (legacy method for backward compatibility)
    /// Call this after theme changes to ensure fonts are respected
    static func forceApplyToAllNavigationBars() {
        // Use default FontManager instance for backward compatibility
        forceApplyToAllNavigationBars(fontManager: FontManager())
    }
    
    /// Perform the actual font update (must be called on main thread)
    private static func performFontUpdate(fontManager: FontManager) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        
        for window in windowScene.windows {
            forceUpdateNavigationBarsRecursively(in: window.rootViewController, fontManager: fontManager)
        }
    }
    
    /// Perform the actual font update (must be called on main thread) - legacy method
    private static func performFontUpdate() {
        performFontUpdate(fontManager: FontManager())
    }
    
    /// Apply fonts to a specific navigation bar instance (for UIKit views) with FontManager integration
    static func applyFonts(to navigationBar: UINavigationBar, fontManager: FontManager) {
        // Apply fonts to all appearances of this specific navigation bar
        applyFonts(to: navigationBar.standardAppearance, fontManager: fontManager)
        
        if let scrollEdge = navigationBar.scrollEdgeAppearance {
            applyFonts(to: scrollEdge, fontManager: fontManager)
        } else {
            // Create and apply scrollEdge appearance if it doesn't exist
            let scrollEdgeAppearance = UINavigationBarAppearance()
            scrollEdgeAppearance.configureWithDefaultBackground()
            applyFonts(to: scrollEdgeAppearance, fontManager: fontManager)
            navigationBar.scrollEdgeAppearance = scrollEdgeAppearance
        }
        
        if let compact = navigationBar.compactAppearance {
            applyFonts(to: compact, fontManager: fontManager)
        } else {
            // Create and apply compact appearance if it doesn't exist
            let compactAppearance = UINavigationBarAppearance()
            compactAppearance.configureWithDefaultBackground()
            applyFonts(to: compactAppearance, fontManager: fontManager)
            navigationBar.compactAppearance = compactAppearance
        }
        
        // Force the navigation bar to update
        navigationBar.setNeedsLayout()
    }
    
    /// Apply fonts to a specific navigation bar instance (for UIKit views) - legacy method
    static func applyFonts(to navigationBar: UINavigationBar) {
        // Use default FontManager instance for backward compatibility
        applyFonts(to: navigationBar, fontManager: FontManager())
    }
    
    /// Recursively find and update navigation bars with custom fonts
    private static func forceUpdateNavigationBarsRecursively(in viewController: UIViewController?, fontManager: FontManager) {
        guard let vc = viewController else { return }
        
        if let navController = vc as? UINavigationController {
            let navBar = navController.navigationBar
            
            // Use the new method to apply fonts with FontManager integration
            applyFonts(to: navBar, fontManager: fontManager)
        }
        
        // Check children
        for child in vc.children {
            forceUpdateNavigationBarsRecursively(in: child, fontManager: fontManager)
        }
        
        // Check presented view controller
        if let presented = vc.presentedViewController {
            forceUpdateNavigationBarsRecursively(in: presented, fontManager: fontManager)
        }
    }
    
    /// Recursively find and update navigation bars with custom fonts - legacy method
    private static func forceUpdateNavigationBarsRecursively(in viewController: UIViewController?) {
        forceUpdateNavigationBarsRecursively(in: viewController, fontManager: FontManager())
    }
    
    #else
    // macOS stubs - navigation bar customization not available
    static func createLargeTitleFont(fontManager: FontManager) -> NSFont {
        return NSFont.systemFont(ofSize: 28, weight: NSFont.Weight.bold)
    }

    static func createTitleFont(fontManager: FontManager) -> NSFont {
        return NSFont.systemFont(ofSize: 17, weight: NSFont.Weight.semibold)
    }

    static func createLargeTitleFont() -> NSFont {
        return createLargeTitleFont(fontManager: FontManager())
    }

    static func createTitleFont() -> NSFont {
        return createTitleFont(fontManager: FontManager())
    }

    /// No-op on macOS (no font caching needed for navigation bars)
    static func invalidateCache() {
        // No-op on macOS
    }

    static func forceApplyToAllNavigationBars(fontManager: FontManager) {
        // No-op on macOS
    }

    static func forceApplyToAllNavigationBars() {
        // No-op on macOS
    }
    #endif
}

// MARK: - SwiftUI Integration

#if os(iOS)
/// ViewModifier that ensures navigation titles use the correct Core Text fonts with FontManager integration
struct NavigationFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Force apply fonts when view appears
                NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
            }
            .onChange(of: UIApplication.shared.connectedScenes.count) { 
                // Reapply fonts if scene configuration changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.fontStyle) {
                // Invalidate cache and reapply fonts when font style changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.fontSize) {
                // Invalidate cache and reapply fonts when font size changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.dynamicTypeEnabled) {
                // Invalidate cache and reapply fonts when Dynamic Type setting changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
    }
}

/// ViewModifier that forces font application for deep navigation contexts with FontManager integration
struct DeepNavigationFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Apply fonts with a delay to ensure navigation context is established
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: UIApplication.shared.connectedScenes.count) { _ in
                // Reapply fonts if scene configuration changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.fontStyle) { _ in
                // Invalidate cache and reapply fonts when font style changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.fontSize) { _ in
                // Invalidate cache and reapply fonts when font size changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
            .onChange(of: fontManager.dynamicTypeEnabled) { _ in
                // Invalidate cache and reapply fonts when Dynamic Type setting changes
                NavigationFontConfig.invalidateCache()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
                }
            }
    }
}

extension View {
    /// Ensures this view's navigation title uses the correct Core Text fonts with width=120
    func ensureNavigationFonts() -> some View {
        self.modifier(NavigationFontModifier())
    }
    
    /// Ensures fonts are applied for deep navigation contexts (UIKit views, threads, profiles)
    func ensureDeepNavigationFonts() -> some View {
        self.modifier(DeepNavigationFontModifier())
    }
}

#else

// macOS stubs for SwiftUI modifiers
extension View {
    /// No-op on macOS
    func ensureNavigationFonts() -> some View {
        self
    }
    
    /// No-op on macOS
    func ensureDeepNavigationFonts() -> some View {
        self
    }
}

#endif

