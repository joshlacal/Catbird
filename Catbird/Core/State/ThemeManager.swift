import SwiftUI
import UIKit
import OSLog

/// Manages theme application throughout the app
@Observable final class ThemeManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "ThemeManager")
    
    // MARK: - Properties
    
    /// Current color scheme override (nil means follow system)
    var colorSchemeOverride: ColorScheme? = nil
    
    /// Current dark theme mode (dim or black)
    var darkThemeMode: DarkThemeMode = .dim
    
    // MARK: - Caching Properties
    
    /// Cache current theme settings to avoid redundant applications
    private var currentTheme: String = ""
    private var currentDarkThemeMode: String = ""
    
    /// Debounce force navigation bar updates to prevent infinite loops
    private var lastForceUpdateTime: Date = Date.distantPast
    private let forceUpdateDebounceInterval: TimeInterval = 0.1 // 100ms
    
    // MARK: - Theme Definitions
    
    enum DarkThemeMode {
        case dim     // Standard dark mode with grays
        case black   // True black with proper hierarchy
    }
    
    // MARK: - Methods
    
    /// Apply theme based on current settings
    func applyTheme(theme: String, darkThemeMode: String) {
        // Skip if settings haven't changed
        if theme == currentTheme && darkThemeMode == currentDarkThemeMode {
            return
        }
        
        logger.info("Applying theme: \(theme), dark mode: \(darkThemeMode)")
        
        // Update cache
        currentTheme = theme
        currentDarkThemeMode = darkThemeMode
        
        // Update dark theme mode
        self.darkThemeMode = (darkThemeMode == "black") ? .black : .dim
        
        // Update color scheme override
        switch theme {
        case "light":
            colorSchemeOverride = .light
        case "dark":
            colorSchemeOverride = .dark
        case "system":
            colorSchemeOverride = nil
        default:
            colorSchemeOverride = nil
        }
        
        // Apply to all windows
        applyToAllWindows()
        
        // Apply to UI components
        applyToNavigationBar()
        applyToTabBar()
        applyToToolbar()
        applyToTableView()
        applyToCollectionView()
        
        // Invalidate color cache when theme changes
        ThemeColorCache.shared.invalidate()
        
        // Force update navigation bars to ensure they use the correct colors
        // Note: We do this BEFORE posting notification to prevent infinite loops
        forceUpdateNavigationBars()
        
        // Post notification for any components that need manual updates
        // This should only be used for lightweight UI updates, not for triggering more force updates
        NotificationCenter.default.post(name: NSNotification.Name("ThemeChanged"), object: nil)
    }
    
    /// Apply current theme settings to all windows
    private func applyToAllWindows() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            logger.warning("No window scene found")
            return
        }
        
        for window in windowScene.windows {
            // Apply color scheme override
            if let override = colorSchemeOverride {
                window.overrideUserInterfaceStyle = override == .dark ? .dark : .light
            } else {
                window.overrideUserInterfaceStyle = .unspecified
            }
            
            // Set window tint color based on theme
            if getCurrentEffectiveDarkMode() && darkThemeMode == .black {
                // Slightly brighter accent for better visibility on black
                window.tintColor = UIColor.systemBlue.withAlphaComponent(1.0)
            }
        }
        
        logger.info("Theme applied to \(windowScene.windows.count) windows")
    }
    
    /// Apply theme to navigation bars
    private func applyToNavigationBar() {
        // Create new appearances to ensure clean state
        let standardAppearance = UINavigationBarAppearance()
        let scrollEdgeAppearance = UINavigationBarAppearance()
        let compactAppearance = UINavigationBarAppearance()
        
        // Configure based on theme
        if getCurrentEffectiveDarkMode() {
            if darkThemeMode == .black {
                // True black mode
                standardAppearance.configureWithOpaqueBackground()
                standardAppearance.backgroundColor = UIColor.black
                standardAppearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
                
                scrollEdgeAppearance.configureWithTransparentBackground()
                scrollEdgeAppearance.backgroundColor = UIColor.black
                scrollEdgeAppearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
                
                compactAppearance.configureWithOpaqueBackground()
                compactAppearance.backgroundColor = UIColor.black
                compactAppearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
            } else {
                // Dim mode - use configureWithOpaqueBackground for full control
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0) // Proper gray for dim mode
                let dimSeparator = UIColor(white: 0.45, alpha: 0.6)
                
                standardAppearance.configureWithOpaqueBackground()
                standardAppearance.backgroundColor = dimBackground
                standardAppearance.shadowColor = dimSeparator
                
                scrollEdgeAppearance.configureWithOpaqueBackground()
                scrollEdgeAppearance.backgroundColor = dimBackground
                scrollEdgeAppearance.shadowColor = .clear // Remove shadow for cleaner look
                
                compactAppearance.configureWithOpaqueBackground()
                compactAppearance.backgroundColor = dimBackground
                compactAppearance.shadowColor = dimSeparator
            }
        } else {
            // Light mode
            standardAppearance.configureWithDefaultBackground()
            scrollEdgeAppearance.configureWithTransparentBackground()
            compactAppearance.configureWithDefaultBackground()
        }
        
        // Apply custom fonts to all appearances
        NavigationFontConfig.applyFonts(to: standardAppearance)
        NavigationFontConfig.applyFonts(to: scrollEdgeAppearance)
        NavigationFontConfig.applyFonts(to: compactAppearance)
        
        // Apply text color based on theme
        let textColor = getCurrentEffectiveDarkMode() 
            ? UIColor(Color.dynamicText(self, style: .primary, currentScheme: .dark))
            : UIColor.label
        
        [standardAppearance, scrollEdgeAppearance, compactAppearance].forEach { appearance in
            // Update colors while preserving fonts
            var titleAttrs = appearance.titleTextAttributes
            titleAttrs[.foregroundColor] = textColor
            appearance.titleTextAttributes = titleAttrs
            
            var largeTitleAttrs = appearance.largeTitleTextAttributes
            largeTitleAttrs[.foregroundColor] = textColor
            appearance.largeTitleTextAttributes = largeTitleAttrs
        }
        
        // Apply the appearances
        UINavigationBar.appearance().standardAppearance = standardAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
        UINavigationBar.appearance().compactAppearance = compactAppearance
    }
    
    /// Force update all navigation bars in the app
    func forceUpdateNavigationBars() {
        let now = Date()
        
        // Debounce to prevent infinite loops
        if now.timeIntervalSince(lastForceUpdateTime) < forceUpdateDebounceInterval {
            logger.debug("Skipping force navigation bar update due to debouncing")
            return
        }
        
        lastForceUpdateTime = now
        logger.info("Force updating all navigation bars")
        
        // Re-apply navigation bar theme
        applyToNavigationBar()
        
        // Force all existing navigation bars to update
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            
            for window in windowScene.windows {
                // Find all navigation controllers and force update their navigation bars
                self.updateNavigationBarsRecursively(in: window.rootViewController)
                
                // Force update all UINavigationBar instances directly
                self.forceUpdateAllNavigationBarInstances(in: window)
                
                // Force window to update
                window.setNeedsDisplay()
                window.layoutIfNeeded()
            }
        }
    }
    
    /// Aggressively find and update all UINavigationBar instances
    private func forceUpdateAllNavigationBarInstances(in window: UIWindow) {
        func findNavigationBars(in view: UIView) {
            if let navBar = view as? UINavigationBar {
                // Get current appearances
                let standard = UINavigationBar.appearance().standardAppearance
                let scrollEdge = UINavigationBar.appearance().scrollEdgeAppearance ?? standard
                let compact = UINavigationBar.appearance().compactAppearance ?? standard
                
                // Force apply to this specific navigation bar
                navBar.standardAppearance = standard
                navBar.scrollEdgeAppearance = scrollEdge
                navBar.compactAppearance = compact
                
                // Force immediate update
                navBar.setNeedsLayout()
                navBar.layoutIfNeeded()
                navBar.setNeedsDisplay()
                
                logger.debug("Force updated navigation bar: \(navBar)")
            }
            
            // Recursively check all subviews
            for subview in view.subviews {
                findNavigationBars(in: subview)
            }
        }
        
        findNavigationBars(in: window)
    }
    
    /// Recursively update navigation bars in view controller hierarchy
    private func updateNavigationBarsRecursively(in viewController: UIViewController?) {
        guard let vc = viewController else { return }
        
        if let navController = vc as? UINavigationController {
            // Force the navigation bar to update its appearance
            let navBar = navController.navigationBar
            
            // Get current appearances
            let standard = UINavigationBar.appearance().standardAppearance
            let scrollEdge = UINavigationBar.appearance().scrollEdgeAppearance ?? standard
            let compact = UINavigationBar.appearance().compactAppearance ?? standard
            
            // Apply to this specific navigation bar
            navBar.standardAppearance = standard
            navBar.scrollEdgeAppearance = scrollEdge
            navBar.compactAppearance = compact
            
            // Force update
            navBar.setNeedsLayout()
            navBar.layoutIfNeeded()
            navBar.setNeedsDisplay()
        }
        
        // Check children
        for child in vc.children {
            updateNavigationBarsRecursively(in: child)
        }
        
        // Check presented view controller
        if let presented = vc.presentedViewController {
            updateNavigationBarsRecursively(in: presented)
        }
    }
    
    /// Apply theme to tab bars
    private func applyToTabBar() {
        let appearance = UITabBarAppearance()
        
        if getCurrentEffectiveDarkMode() {
            if darkThemeMode == .black {
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
                
                // Configure item appearance
                appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color.dynamicText(self, style: .secondary, currentScheme: .dark))
                appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                    .foregroundColor: UIColor(Color.dynamicText(self, style: .secondary, currentScheme: .dark))
                ]
                
                appearance.stackedLayoutAppearance.selected.iconColor = UIColor.systemBlue
                appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                    .foregroundColor: UIColor.systemBlue
                ]
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = UIColor(white: 0.45, alpha: 0.6)
                
                // Configure item appearance for dim mode
                appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color.dynamicText(self, style: .secondary, currentScheme: .dark))
                appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                    .foregroundColor: UIColor(Color.dynamicText(self, style: .secondary, currentScheme: .dark))
                ]
                
                appearance.stackedLayoutAppearance.selected.iconColor = UIColor.systemBlue
                appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                    .foregroundColor: UIColor.systemBlue
                ]
            }
        } else {
            appearance.configureWithDefaultBackground()
        }
        
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    /// Apply theme to toolbars
    private func applyToToolbar() {
        let appearance = UIToolbarAppearance()
        
        if getCurrentEffectiveDarkMode() {
            if darkThemeMode == .black {
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = UIColor(white: 0.45, alpha: 0.6)
            }
        } else {
            appearance.configureWithDefaultBackground()
        }
        
        UIToolbar.appearance().standardAppearance = appearance
        UIToolbar.appearance().scrollEdgeAppearance = appearance
    }
    
    /// Apply theme to table views
    private func applyToTableView() {
        if getCurrentEffectiveDarkMode() {
            UITableView.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
            UITableView.appearance().separatorColor = UIColor(Color.dynamicSeparator(self, currentScheme: .dark))
            
            UITableViewCell.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
            
            // Configure section headers
            UITableViewHeaderFooterView.appearance().tintColor = UIColor(Color.dynamicSecondaryBackground(self, currentScheme: .dark))
        }
    }
    
    /// Apply theme to collection views
    private func applyToCollectionView() {
        if getCurrentEffectiveDarkMode() {
            UICollectionView.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
        }
    }
    
    /// Get current effective dark mode state
    private func getCurrentEffectiveDarkMode() -> Bool {
        switch colorSchemeOverride {
        case .light:
            return false
        case .dark:
            return true
        case nil:
            // Follow system
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let window = windowScene.windows.first {
                return window.traitCollection.userInterfaceStyle == .dark
            }
            return false
        @unknown default:
            return false
        }
    }
    
    /// Get the effective color scheme based on current settings
    func effectiveColorScheme(for systemScheme: ColorScheme) -> ColorScheme {
        if let override = colorSchemeOverride {
            return override
        }
        return systemScheme
    }
    
    /// Check if we're currently in dark mode
    func isDarkMode(for systemScheme: ColorScheme) -> Bool {
        return effectiveColorScheme(for: systemScheme) == .dark
    }
    
    /// Check if we're using true black mode
    var isUsingTrueBlack: Bool {
        darkThemeMode == .black
    }
    
    // MARK: - UIKit Bridge Methods
    
    /// Apply theme to a specific navigation bar instance
    /// This is useful for UIKit views embedded in SwiftUI
    func applyTheme(to navigationBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance()
        
        if getCurrentEffectiveDarkMode() {
            if darkThemeMode == .black {
                // True black mode
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = UIColor(white: 0.45, alpha: 0.6)
            }
        } else {
            // Light mode
            appearance.configureWithDefaultBackground()
        }
        
        // Apply fonts
        NavigationFontConfig.applyFonts(to: appearance)
        
        // Apply text color
        let textColor = getCurrentEffectiveDarkMode() 
            ? UIColor(Color.dynamicText(self, style: .primary, currentScheme: .dark))
            : UIColor.label
        
        var titleAttrs = appearance.titleTextAttributes
        titleAttrs[.foregroundColor] = textColor
        appearance.titleTextAttributes = titleAttrs
        
        var largeTitleAttrs = appearance.largeTitleTextAttributes
        largeTitleAttrs[.foregroundColor] = textColor
        appearance.largeTitleTextAttributes = largeTitleAttrs
        
        // Apply to the specific navigation bar
        navigationBar.standardAppearance = appearance
        navigationBar.scrollEdgeAppearance = appearance
        navigationBar.compactAppearance = appearance
    }
    
    /// Apply theme to a specific toolbar instance
    func applyTheme(to toolbar: UIToolbar) {
        let appearance = UIToolbarAppearance()
        
        if getCurrentEffectiveDarkMode() {
            if darkThemeMode == .black {
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = UIColor(white: 0.15, alpha: 0.3)
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = UIColor(white: 0.45, alpha: 0.6)
            }
        } else {
            appearance.configureWithDefaultBackground()
        }
        
        toolbar.standardAppearance = appearance
        toolbar.scrollEdgeAppearance = appearance
    }
}

// MARK: - View Modifiers

struct ThemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var systemColorScheme
    let themeManager: ThemeManager
    
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(themeManager.colorSchemeOverride)
            .environment(\.themeManager, themeManager)
    }
}

extension View {
    /// Apply theme settings from ThemeManager
    func applyTheme(_ themeManager: ThemeManager) -> some View {
        self.modifier(ThemeModifier(themeManager: themeManager))
    }
}

// MARK: - Environment Values

private struct ThemeManagerKey: EnvironmentKey {
    static let defaultValue: ThemeManager? = nil
}

extension EnvironmentValues {
    var themeManager: ThemeManager? {
        get { self[ThemeManagerKey.self] }
        set { self[ThemeManagerKey.self] = newValue }
    }
}

// MARK: - Transition Support

struct ThemeTransitionModifier: ViewModifier {
    let themeManager: ThemeManager
    let appSettings: AppSettings
    
    func body(content: Content) -> some View {
        content
            .motionAwareAnimation(.easeInOut(duration: 0.3), value: themeManager.darkThemeMode, appSettings: appSettings)
            .motionAwareAnimation(.easeInOut(duration: 0.3), value: themeManager.colorSchemeOverride, appSettings: appSettings)
    }
}

extension View {
    /// Add smooth transitions when theme changes
    func themeTransition(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.modifier(ThemeTransitionModifier(themeManager: themeManager, appSettings: appSettings))
    }
}