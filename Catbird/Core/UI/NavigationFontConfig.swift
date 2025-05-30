import UIKit
import CoreText

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
}
