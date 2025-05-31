import UIKit
import CoreText
import SwiftUI

/// Centralized navigation font configuration to ensure consistency across the app
enum NavigationFontConfig {
    
    /// Creates the custom large title font with Core Text variations
    static func createLargeTitleFont() -> UIFont {
        let largeTitleSize: CGFloat = 28
        
        // Define the OpenType variation axes as hex integers (4-char codes)
        let wdthAxisID: Int = 0x7764_7468  // 'wdth' in hex
        let wghtAxisID: Int = 0x7767_6874  // 'wght' in hex
        let opszAxisID: Int = 0x6F70_737A  // 'opsz' in hex
        
        // Create variations dictionary for large title
        let largeTitleVariations: [Int: Any] = [
            wdthAxisID: 120,  // Width: 120% (expanded)
            wghtAxisID: 700.0,  // Weight: Bold (700)
            opszAxisID: Double(largeTitleSize)  // Optical size matching point size
        ]
        
        // Start with the system font
        let baseFont = UIFont.systemFont(ofSize: largeTitleSize)
        let largeTitleFontDesc = baseFont.fontDescriptor
        
        // Apply the variations to the font descriptor
        let largeTitleDescriptor = largeTitleFontDesc.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: largeTitleVariations
        ])
        
        // Create the font with the modified descriptor
        let customUIFont = UIFont(descriptor: largeTitleDescriptor, size: 0)
        
        // Scale for accessibility
        return UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: customUIFont)
    }
    
    /// Creates the custom title font with Core Text variations
    static func createTitleFont() -> UIFont {
        let titleSize: CGFloat = 17
        
        // Define the OpenType variation axes as hex integers (4-char codes)
        let wdthAxisID: Int = 0x7764_7468  // 'wdth' in hex
        let wghtAxisID: Int = 0x7767_6874  // 'wght' in hex
        let opszAxisID: Int = 0x6F70_737A  // 'opsz' in hex
        
        // Create variations dictionary for title
        let titleVariations: [Int: Any] = [
            wdthAxisID: 120,  // Width: 120% (expanded)
            wghtAxisID: 600.0,  // Weight: Semibold (600)
            opszAxisID: Double(titleSize)  // Optical size matching title point size
        ]
        
        let titleFontDesc = UIFont.systemFont(ofSize: titleSize).fontDescriptor
        let titleDescriptor = titleFontDesc.addingAttributes([
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: titleVariations
        ])
        
        let customTitleFont = UIFont(descriptor: titleDescriptor, size: 0)
        
        // Scale for accessibility
        return UIFontMetrics(forTextStyle: .headline).scaledFont(for: customTitleFont)
    }
    
    /// Apply custom fonts to a navigation bar appearance
    static func applyFonts(to appearance: UINavigationBarAppearance) {
        // Get the custom fonts
        let titleFont = createTitleFont()
        let largeTitleFont = createLargeTitleFont()
        
        // Update title attributes while preserving other attributes
        var titleAttrs = appearance.titleTextAttributes
        titleAttrs[.font] = titleFont
        appearance.titleTextAttributes = titleAttrs
        
        // Update large title attributes while preserving other attributes
        var largeTitleAttrs = appearance.largeTitleTextAttributes
        largeTitleAttrs[.font] = largeTitleFont
        appearance.largeTitleTextAttributes = largeTitleAttrs
    }
    
    /// Force apply fonts to all current navigation bars in the app
    /// Call this after theme changes to ensure fonts are respected
    static func forceApplyToAllNavigationBars() {
        // Ensure we're on the main thread for all UI operations
        if Thread.isMainThread {
            performFontUpdate()
        } else {
            DispatchQueue.main.async {
                performFontUpdate()
            }
        }
    }
    
    /// Perform the actual font update (must be called on main thread)
    private static func performFontUpdate() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        
        for window in windowScene.windows {
            forceUpdateNavigationBarsRecursively(in: window.rootViewController)
        }
    }
    
    /// Apply fonts to a specific navigation bar instance (for UIKit views)
    static func applyFonts(to navigationBar: UINavigationBar) {
        // Apply fonts to all appearances of this specific navigation bar
        applyFonts(to: navigationBar.standardAppearance)
        
        if let scrollEdge = navigationBar.scrollEdgeAppearance {
            applyFonts(to: scrollEdge)
        } else {
            // Create and apply scrollEdge appearance if it doesn't exist
            let scrollEdgeAppearance = UINavigationBarAppearance()
            scrollEdgeAppearance.configureWithTransparentBackground()
            applyFonts(to: scrollEdgeAppearance)
            navigationBar.scrollEdgeAppearance = scrollEdgeAppearance
        }
        
        if let compact = navigationBar.compactAppearance {
            applyFonts(to: compact)
        } else {
            // Create and apply compact appearance if it doesn't exist
            let compactAppearance = UINavigationBarAppearance()
            compactAppearance.configureWithOpaqueBackground()
            applyFonts(to: compactAppearance)
            navigationBar.compactAppearance = compactAppearance
        }
        
        // Force the navigation bar to update
        navigationBar.setNeedsLayout()
    }
    
    /// Recursively find and update navigation bars with custom fonts
    private static func forceUpdateNavigationBarsRecursively(in viewController: UIViewController?) {
        guard let vc = viewController else { return }
        
        if let navController = vc as? UINavigationController {
            let navBar = navController.navigationBar
            
            // Use the new method to apply fonts
            applyFonts(to: navBar)
        }
        
        // Check children
        for child in vc.children {
            forceUpdateNavigationBarsRecursively(in: child)
        }
        
        // Check presented view controller
        if let presented = vc.presentedViewController {
            forceUpdateNavigationBarsRecursively(in: presented)
        }
    }
}

// MARK: - SwiftUI Integration

/// ViewModifier that ensures navigation titles use the correct Core Text fonts
struct NavigationFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Force apply fonts when view appears
                NavigationFontConfig.forceApplyToAllNavigationBars()
            }
            .onChange(of: UIApplication.shared.connectedScenes.count) { _ in
                // Reapply fonts if scene configuration changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars()
                }
            }
    }
}

/// ViewModifier that forces font application for deep navigation contexts
struct DeepNavigationFontModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                // Apply fonts with a delay to ensure navigation context is established
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    NavigationFontConfig.forceApplyToAllNavigationBars()
                }
            }
            .onChange(of: UIApplication.shared.connectedScenes.count) { _ in
                // Reapply fonts if scene configuration changes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NavigationFontConfig.forceApplyToAllNavigationBars()
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
