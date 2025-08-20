import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog

// MARK: - Cross-Platform Content Size Category

/// Cross-platform abstraction for content size categories
/// Provides consistent font scaling across iOS and macOS
enum CrossPlatformContentSizeCategory: String, CaseIterable, Sendable {
    case extraSmall = "extraSmall"
    case small = "small"
    case medium = "medium"
    case large = "large"
    case extraLarge = "extraLarge"
    case extraExtraLarge = "extraExtraLarge"
    case extraExtraExtraLarge = "extraExtraExtraLarge"
    case accessibilityMedium = "accessibilityMedium"
    case accessibilityLarge = "accessibilityLarge"
    case accessibilityExtraLarge = "accessibilityExtraLarge"
    case accessibilityExtraExtraLarge = "accessibilityExtraExtraLarge"
    case accessibilityExtraExtraExtraLarge = "accessibilityExtraExtraExtraLarge"
    
    /// Get current system content size category
    static var current: CrossPlatformContentSizeCategory {
        #if os(iOS)
        return CrossPlatformContentSizeCategory(from: UIApplication.shared.preferredContentSizeCategory)
        #elseif os(macOS)
        // On macOS, we'll use a default medium size since there's no system Dynamic Type
        // This could be enhanced to read from user defaults or system preferences
        return .medium
        #endif
    }
    
    #if os(iOS)
    /// Convert to UIContentSizeCategory (iOS only)
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .extraSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .extraLarge
        case .extraExtraLarge: return .extraExtraLarge
        case .extraExtraExtraLarge: return .extraExtraExtraLarge
        case .accessibilityMedium: return .accessibilityMedium
        case .accessibilityLarge: return .accessibilityLarge
        case .accessibilityExtraLarge: return .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: return .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: return .accessibilityExtraExtraExtraLarge
        }
    }
    
    /// Initialize from UIContentSizeCategory (iOS only)
    init(from uiCategory: UIContentSizeCategory) {
        switch uiCategory {
        case .extraSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .extraLarge: self = .extraLarge
        case .extraExtraLarge: self = .extraExtraLarge
        case .extraExtraExtraLarge: self = .extraExtraExtraLarge
        case .accessibilityMedium: self = .accessibilityMedium
        case .accessibilityLarge: self = .accessibilityLarge
        case .accessibilityExtraLarge: self = .accessibilityExtraLarge
        case .accessibilityExtraExtraLarge: self = .accessibilityExtraExtraLarge
        case .accessibilityExtraExtraExtraLarge: self = .accessibilityExtraExtraExtraLarge
        default: self = .medium
        }
    }
    #endif
    
    /// Scale factor for this content size category
    var scaleFactor: CGFloat {
        switch self {
        case .extraSmall: return 0.82
        case .small: return 0.88
        case .medium: return 1.0
        case .large: return 1.12
        case .extraLarge: return 1.23
        case .extraExtraLarge: return 1.35
        case .extraExtraExtraLarge: return 1.47
        case .accessibilityMedium: return 1.64
        case .accessibilityLarge: return 1.95
        case .accessibilityExtraLarge: return 2.35
        case .accessibilityExtraExtraLarge: return 2.76
        case .accessibilityExtraExtraExtraLarge: return 3.12
        }
    }
    
    /// Whether this is an accessibility size
    var isAccessibilitySize: Bool {
        switch self {
        case .accessibilityMedium, .accessibilityLarge, .accessibilityExtraLarge, 
             .accessibilityExtraExtraLarge, .accessibilityExtraExtraExtraLarge:
            return true
        default:
            return false
        }
    }
}

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
    
    /// Current letter spacing setting
    var letterSpacing: String = "normal"
    
    /// Whether Dynamic Type is enabled
    var dynamicTypeEnabled: Bool = true
    
    /// Maximum Dynamic Type size to allow
    var maxDynamicTypeSize: String = "accessibility1"
    
    /// Current system content size category
    private(set) var currentContentSizeCategory: CrossPlatformContentSizeCategory = .current
    
    // MARK: - Initialization
    
    init() {
        setupDynamicTypeObserver()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Dynamic Type Observer
    
    /// Setup observer for Dynamic Type changes
    private func setupDynamicTypeObserver() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
        #elseif os(macOS)
        // macOS doesn't have system Dynamic Type, but we can still set up
        // observers for potential future enhancements or manual triggers
        logger.debug("Dynamic Type observer setup completed for macOS (no system notifications available)")
        #endif
    }
    
    @objc private func contentSizeCategoryDidChange(_ notification: Notification) {
        #if os(iOS)
        let newCategory = CrossPlatformContentSizeCategory(from: UIApplication.shared.preferredContentSizeCategory)
        if Thread.isMainThread {
            currentContentSizeCategory = newCategory
        } else {
            Task { @MainActor in
                self.currentContentSizeCategory = newCategory
            }
        }
        
        logger.info("Dynamic Type size changed to: \(newCategory.rawValue)")
        #elseif os(macOS)
        // On macOS, we could potentially update from system preferences
        // For now, keep the current category as-is
        logger.info("Content size category change notification received on macOS (no automatic update)")
        #endif
        
        // Post notification for UI updates if Dynamic Type is enabled
        if dynamicTypeEnabled {
            NotificationCenter.default.post(name: NSNotification.Name("FontChanged"), object: nil)
        }
    }
    
    // MARK: - Caching Properties
    
    /// Cache current font settings to avoid redundant applications
    private var currentFontStyle: String = ""
    private var currentFontSize: String = ""
    private var currentLineSpacing: String = ""
    private var currentLetterSpacing: String = ""
    private var currentDynamicTypeEnabled: Bool = true
    private var currentMaxDynamicTypeSize: String = ""
    
    // MARK: - Computed Properties
    
    /// Scale factor based on font size preference
    var sizeScale: CGFloat {
        switch fontSize {
        case "small":
            return 0.9
        case "default":
            return 1.0
        case "large":
            return 1.1
        case "extraLarge":
            return 1.2
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
    
    /// Letter spacing (tracking) value based on preference
    var letterSpacingValue: CGFloat {
        switch letterSpacing {
        case "tight":
            return -0.3
        case "normal":
            return 0.1
        case "loose":
            return 0.4
        default:
            return 0.1
        }
    }
    
    /// Maximum allowed content size category
    var maxContentSizeCategory: CrossPlatformContentSizeCategory {
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
        letterSpacing: String,
        dynamicTypeEnabled: Bool,
        maxDynamicTypeSize: String
    ) {
        // Skip if settings haven't changed to prevent infinite loops
        if fontStyle == currentFontStyle &&
           fontSize == currentFontSize &&
           lineSpacing == currentLineSpacing &&
           letterSpacing == currentLetterSpacing &&
           dynamicTypeEnabled == currentDynamicTypeEnabled &&
           maxDynamicTypeSize == currentMaxDynamicTypeSize {
            logger.debug("Font settings unchanged, skipping update")
            return
        }
        
        logger.info("Applying font settings - style: \(fontStyle), size: \(fontSize), spacing: \(lineSpacing), tracking: \(letterSpacing), dynamic: \(dynamicTypeEnabled), maxSize: \(maxDynamicTypeSize)")
        logger.debug("Previous settings - style: \(self.currentFontStyle), size: \(self.currentFontSize), spacing: \(self.currentLineSpacing), tracking: \(self.currentLetterSpacing), dynamic: \(self.currentDynamicTypeEnabled), maxSize: \(self.currentMaxDynamicTypeSize)")
        
        // Update cache FIRST to prevent re-entrance
        currentFontStyle = fontStyle
        currentFontSize = fontSize
        currentLineSpacing = lineSpacing
        currentLetterSpacing = letterSpacing
        currentDynamicTypeEnabled = dynamicTypeEnabled
        currentMaxDynamicTypeSize = maxDynamicTypeSize
        
        // Update actual settings immediately on main actor
        // Since FontManager is @Observable, changes should trigger UI updates
        if Thread.isMainThread {
            self.fontStyle = fontStyle
            self.fontSize = fontSize
            self.lineSpacing = lineSpacing
            self.letterSpacing = letterSpacing
            self.dynamicTypeEnabled = dynamicTypeEnabled
            self.maxDynamicTypeSize = maxDynamicTypeSize
        } else {
            Task { @MainActor in
                self.fontStyle = fontStyle
                self.fontSize = fontSize
                self.lineSpacing = lineSpacing
                self.letterSpacing = letterSpacing
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
            NotificationCenter.default.post(name: NSNotification.Name("FontChanged"), object: nil)
            logger.debug("Posted FontChanged notification synchronously")
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("FontChanged"), object: nil)
                self.logger.debug("Posted FontChanged notification asynchronously")
            }
        }
    }
    
    /// Apply font settings from AppSettings with accessibility features
    func applyAllFontSettings(from appSettings: AppSettingsModel) {
        applyFontSettings(
            fontStyle: appSettings.fontStyle,
            fontSize: appSettings.fontSize,
            lineSpacing: appSettings.lineSpacing,
            letterSpacing: appSettings.letterSpacing,
            dynamicTypeEnabled: appSettings.dynamicTypeEnabled,
            maxDynamicTypeSize: appSettings.maxDynamicTypeSize
        )
    }
    
    /// Apply Dynamic Type size constraints at the app level
    private func applyDynamicTypeConstraints() {
        guard dynamicTypeEnabled else {
            logger.debug("Dynamic Type disabled, no constraints to apply")
            return
        }
        
        let currentCategory = CrossPlatformContentSizeCategory.current
        let maxCategory = maxContentSizeCategory
        
        logger.info("Applying Dynamic Type constraints - current: \(currentCategory.rawValue), max allowed: \(maxCategory.rawValue)")
        
        // Check if current size exceeds our maximum allowed size
        if shouldLimitContentSizeCategory(current: currentCategory, maximum: maxCategory) {
            logger.info("Current Dynamic Type size (\(currentCategory.rawValue)) exceeds maximum (\(maxCategory.rawValue)), applying constraint")
            
            // Apply the constraint by setting up a custom trait collection override (iOS only)
            #if os(iOS)
            applyContentSizeCategoryOverride(maxCategory)
            #elseif os(macOS)
            // On macOS, we don't have trait collections, so we'll store the constraint
            // and use it in our font scaling calculations
            currentContentSizeCategory = maxCategory
            logger.info("Applied content size constraint on macOS by updating current category")
            #endif
        } else {
            logger.debug("Current Dynamic Type size is within allowed limits")
            #if os(iOS)
            removeContentSizeCategoryOverride()
            #elseif os(macOS)
            // On macOS, update to the actual system preference (or keep current)
            currentContentSizeCategory = currentCategory
            #endif
        }
    }
    
    /// Check if the current content size category should be limited
    private func shouldLimitContentSizeCategory(
        current: CrossPlatformContentSizeCategory,
        maximum: CrossPlatformContentSizeCategory
    ) -> Bool {
        // Define size category hierarchy for comparison
        let sizeHierarchy: [CrossPlatformContentSizeCategory] = [
            .extraSmall,
            .small,
            .medium,
            .large,
            .extraLarge,
            .extraExtraLarge,
            .extraExtraExtraLarge,
            .accessibilityMedium,
            .accessibilityLarge,
            .accessibilityExtraLarge,
            .accessibilityExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge
        ]
        
        guard let currentIndex = sizeHierarchy.firstIndex(of: current),
              let maxIndex = sizeHierarchy.firstIndex(of: maximum) else {
            // If we can't determine the order, don't limit
            logger.warning("Unable to compare content size categories")
            return false
        }
        
        return currentIndex > maxIndex
    }
    
    /// Apply content size category override to limit Dynamic Type (iOS only)
    #if os(iOS)
    private func applyContentSizeCategoryOverride(_ maxCategory: CrossPlatformContentSizeCategory) {
        // Create a custom trait collection with the maximum allowed content size category
        let customTraitCollection = UITraitCollection(preferredContentSizeCategory: maxCategory.uiContentSizeCategory)
        
        // Apply this trait collection to all windows in the app
        // This ensures that UIFont.preferredFont calls will use the limited size
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                for window in windowScene.windows {
                    // Override the trait collection for this window
                    // This affects all UIFont.preferredFont calls within this window
                    window.overrideUserInterfaceStyle = window.overrideUserInterfaceStyle // Preserve existing style override
                    
                    // Store reference to original traits for potential restoration
                    self.storeOriginalTraitCollection(for: window)
                    
                    // Apply the content size override
                    self.applyTraitCollectionOverride(to: window, with: customTraitCollection)
                }
            }
        }
        
        // Post notification that constraint has been applied
        NotificationCenter.default.post(
            name: NSNotification.Name("DynamicTypeConstraintApplied"),
            object: nil,
            userInfo: ["maxCategory": maxCategory.rawValue]
        )
    }
    #endif
    
    /// Remove content size category override to restore normal Dynamic Type behavior (iOS only)
    #if os(iOS)
    private func removeContentSizeCategoryOverride() {
        DispatchQueue.main.async {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                for window in windowScene.windows {
                    // Restore original trait collection if we stored one
                    self.restoreOriginalTraitCollection(for: window)
                }
            }
        }
        
        // Post notification that constraint has been removed
        NotificationCenter.default.post(
            name: NSNotification.Name("DynamicTypeConstraintRemoved"),
            object: nil
        )
    }
    #endif
    
    // MARK: - Trait Collection Management (iOS only)
    
    #if os(iOS)
    /// Storage for original trait collections before override
    private var originalTraitCollections: [ObjectIdentifier: UITraitCollection] = [:]
    
    /// Store the original trait collection for a window before applying override
    private func storeOriginalTraitCollection(for window: UIWindow) {
        let windowId = ObjectIdentifier(window)
        if originalTraitCollections[windowId] == nil {
            originalTraitCollections[windowId] = window.traitCollection
        }
    }
    
    /// Apply trait collection override to a specific window
    private func applyTraitCollectionOverride(to window: UIWindow, with traitCollection: UITraitCollection) {
        // Create a custom trait collection that combines existing traits with our content size override
        let combinedTraitCollection: UITraitCollection
        if #available(iOS 17.0, *) {
            combinedTraitCollection = window.traitCollection.modifyingTraits { mutableTraits in
                mutableTraits.preferredContentSizeCategory = traitCollection.preferredContentSizeCategory
            }
        } else {
            combinedTraitCollection = UITraitCollection(traitsFrom: [
                window.traitCollection,
                traitCollection
            ])
        }
        
        // Apply the override using a custom trait collection implementation
        // This is done by temporarily setting the window's trait collection
        if let rootViewController = window.rootViewController {
            rootViewController.setOverrideTraitCollection(combinedTraitCollection, forChild: rootViewController)
        }
    }
    
    /// Restore the original trait collection for a window
    private func restoreOriginalTraitCollection(for window: UIWindow) {
        let windowId = ObjectIdentifier(window)
        
        if let originalTraitCollection = originalTraitCollections[windowId] {
            // Restore the original trait collection
            if let rootViewController = window.rootViewController {
                rootViewController.setOverrideTraitCollection(nil, forChild: rootViewController)
            }
            
            // Clean up stored reference
            originalTraitCollections.removeValue(forKey: windowId)
        }
    }
    #endif
    
    /// Get scaled font size
    func scaledSize(_ baseSize: CGFloat) -> CGFloat {
        return baseSize * sizeScale
    }
    
    /// Create a scaled system font
    /// 
    /// This method combines two scaling mechanisms:
    /// 1. User font size preference (90% to 120% scale factor)
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
            // Use Dynamic Type scaling WITH our size preference
            // This properly combines app scaling with system Dynamic Type
            return Font.customDynamicFont(
                baseSize: scaledSize,
                weight: weight,
                design: fontDesign,
                relativeTo: textStyle,
                maxContentSizeCategory: maxContentSizeCategory
            )
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
    /// This hijacks the system by creating a custom UIFont that combines:
    /// 1. Dynamic Type scaling (for accessibility)
    /// 2. User's app-specific font size preference
    /// 3. User's chosen font design (serif, rounded, etc.)
    func accessibleFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle
    ) -> Font {
        // Apply user's font size preference to the base size
        let scaledBaseSize = self.scaledSize(size)
        
        if dynamicTypeEnabled {
            // HIJACK APPROACH: Create a custom UIFont that scales with Dynamic Type
            // but starts from our user-preferred base size instead of system default
            return Font.customDynamicFont(
                baseSize: scaledBaseSize,
                weight: weight,
                design: fontDesign,
                relativeTo: textStyle,
                maxContentSizeCategory: maxContentSizeCategory
            )
        } else {
            // Use only our app's font size preference (no Dynamic Type)
            return Font.system(size: scaledBaseSize, weight: weight, design: fontDesign)
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
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let role: AppTextRole
    
    func body(content: Content) -> some View {
        let baseWeight = getBaseWeight(for: role)
        let adjustedWeight = adjustFontWeight(baseWeight: baseWeight, boldText: appState.appSettings.boldText)
        
        content
            .font(fontManager.fontForTextRole(role).weight(adjustedWeight))
            .lineSpacing(fontManager.getLineSpacing(for: Typography.Size.body) * fontManager.lineSpacingMultiplier)
            .tracking(fontManager.letterSpacingValue)
    }
    
    private func getAccessibleTextColor() -> Color {
        // Apply high contrast if enabled
        if appState.appSettings.increaseContrast {
            return Color.adaptiveForeground(appState: appState, defaultColor: .primary)
        } else {
            return Color.primary
        }
    }
    
    private func getBaseWeight(for role: AppTextRole) -> Font.Weight {
        switch role {
        case .largeTitle, .title1:
            return .bold
        case .title2, .title3, .headline:
            return .semibold
        case .subheadline:
            return .medium
        case .body, .callout, .footnote:
            return .regular
        case .caption, .caption2:
            return .medium
        }
    }
    
    private func adjustFontWeight(baseWeight: Font.Weight, boldText: Bool) -> Font.Weight {
        guard boldText else { return baseWeight }
        
        // Increase font weight for accessibility
        switch baseWeight {
        case .ultraLight: return .light
        case .thin: return .regular
        case .light: return .medium
        case .regular: return .semibold
        case .medium: return .semibold
        case .semibold: return .bold
        case .bold: return .heavy
        case .heavy: return .black
        default: return .semibold
        }
    }
}

struct CustomAppFontModifier: ViewModifier {
    @Environment(\.fontManager) private var fontManager
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let size: CGFloat
    let weight: Font.Weight
    let textStyle: Font.TextStyle?
    
    func body(content: Content) -> some View {
        let adjustedWeight = adjustFontWeight(baseWeight: weight, boldText: appState.appSettings.boldText)
        
        content
            .font(fontManager.scaledFont(
                size: size,
                weight: adjustedWeight,
                relativeTo: textStyle ?? .body  // Always provide a textStyle for Dynamic Type
            ))
            .lineSpacing(fontManager.getLineSpacing(for: size))
            .tracking(fontManager.letterSpacingValue)
    }
    
    private func getAccessibleTextColor() -> Color {
        // Apply high contrast if enabled
        if appState.appSettings.increaseContrast {
            return Color.adaptiveForeground(appState: appState, defaultColor: .primary)
        } else {
            return Color.primary
        }
    }
    
    private func adjustFontWeight(baseWeight: Font.Weight, boldText: Bool) -> Font.Weight {
        guard boldText else { return baseWeight }
        
        // Increase font weight for accessibility
        switch baseWeight {
        case .ultraLight: return .light
        case .thin: return .regular
        case .light: return .medium
        case .regular: return .semibold
        case .medium: return .semibold
        case .semibold: return .bold
        case .bold: return .heavy
        case .heavy: return .black
        default: return .semibold
        }
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
        case .system(let textStyle, _, _):
            let appRole = AppTextRole.from(textStyle)
            return AnyView(self.modifier(AppFontModifier(role: appRole)))
        case .systemSize(let size, let weight, _):
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
        case .size:
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
            letterSpacing: letterSpacing, // Keep current letter spacing
            dynamicTypeEnabled: recommended.dynamicTypeEnabled,
            maxDynamicTypeSize: "accessibility3" // Allow higher accessibility sizes
        )
    }
}
