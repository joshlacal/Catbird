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
        
        // Batch all theme updates to reduce main thread blocking
        Task { @MainActor in
            // Apply immediate window-level changes first (most visible)
            await applyToAllWindows()
            
            // Apply UI component themes in batches
            await applyUIComponentThemes()
            
            // Selectively invalidate color cache (only for changed theme)
            ThemeColorCache.shared.invalidateTheme(theme)
            
            // Force update navigation bars with optimized approach
            await optimizedNavigationBarUpdate()
            
            // Post notification after all updates complete
            NotificationCenter.default.post(name: NSNotification.Name("ThemeChanged"), object: nil)
        }
    }
    
    /// Apply current theme settings to all windows
    private func applyToAllWindows() async {
        await MainActor.run {
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
                
                // Set window tint color based on theme if dark mode
                Task {
                    let isDarkMode = await getCurrentEffectiveDarkMode()
                    await MainActor.run {
                        if isDarkMode && darkThemeMode == .black {
                            // Slightly brighter accent for better visibility on black
                            window.tintColor = UIColor.systemBlue.withAlphaComponent(1.0)
                        }
                    }
                }
            }
            
            logger.info("Theme applied to \(windowScene.windows.count) windows")
        }
    }
    
    /// Apply theme to navigation bars
    private func applyToNavigationBar() async {
        await MainActor.run {
            // Create new appearances to ensure clean state
            let standardAppearance = UINavigationBarAppearance()
            let scrollEdgeAppearance = UINavigationBarAppearance()
            let compactAppearance = UINavigationBarAppearance()
            
            Task {
                let isDarkMode = await getCurrentEffectiveDarkMode()
                
                await MainActor.run {
                    // Configure based on theme
                    if isDarkMode {
                        if darkThemeMode == .black {
                            // True black mode - specific configuration per appearance type
                            standardAppearance.configureWithDefaultBackground()    // standard = default
                            standardAppearance.backgroundColor = UIColor.black
                            standardAppearance.shadowColor = .clear
                            
                            scrollEdgeAppearance.configureWithTransparentBackground() // scrollEdge = transparent
                            scrollEdgeAppearance.backgroundColor = UIColor.black
                            scrollEdgeAppearance.shadowColor = .clear
                            
                            compactAppearance.configureWithOpaqueBackground()      // compact = opaque
                            compactAppearance.backgroundColor = UIColor.black
                            compactAppearance.shadowColor = .clear
                        } else {
                            // Dim mode - specific configuration per appearance type
                            let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0) // Proper gray for dim mode
                            
                            standardAppearance.configureWithDefaultBackground()    // standard = default
                            standardAppearance.backgroundColor = dimBackground
                            standardAppearance.shadowColor = .clear
                            
                            scrollEdgeAppearance.configureWithTransparentBackground() // scrollEdge = transparent
                            scrollEdgeAppearance.backgroundColor = dimBackground
                            scrollEdgeAppearance.shadowColor = .clear
                            
                            compactAppearance.configureWithOpaqueBackground()      // compact = opaque
                            compactAppearance.backgroundColor = dimBackground
                            compactAppearance.shadowColor = .clear
                        }
                    } else {
                        // Light mode - specific configuration per appearance type
                        standardAppearance.configureWithDefaultBackground()     // standard = default
                        scrollEdgeAppearance.configureWithTransparentBackground() // scrollEdge = transparent
                        compactAppearance.configureWithOpaqueBackground()      // compact = opaque
                    }
                    
                    // Apply custom fonts to all appearances
                    NavigationFontConfig.applyFonts(to: standardAppearance)
                    NavigationFontConfig.applyFonts(to: scrollEdgeAppearance)
                    NavigationFontConfig.applyFonts(to: compactAppearance)
                    
                    // Apply text color based on theme
                    let textColor = isDarkMode
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
            }
        }
    }
    
    /// Apply UI component themes in batches to reduce blocking
    private func applyUIComponentThemes() async {
        // Apply navigation bar theme first (most visible)
        await applyToNavigationBar()
        
        // Yield control briefly to prevent blocking
        await Task.yield()
        
        // Apply other component themes (tab bars now handled by SwiftUI)
        await applyToToolbar()
        
        await Task.yield()
        
        await applyToTableView()
        await applyToCollectionView()
    }
    
    /// Optimized navigation bar update that reduces redundant work
    private func optimizedNavigationBarUpdate() async {
        let now = Date()
        
        // Debounce to prevent infinite loops
        if now.timeIntervalSince(lastForceUpdateTime) < forceUpdateDebounceInterval {
            logger.debug("Skipping optimized navigation bar update due to debouncing")
            return
        }
        
        lastForceUpdateTime = now
        logger.info("Running optimized navigation bar update")
        
        // Yield control before starting heavy work
        await Task.yield()
        
        // Force apply custom fonts to all navigation bars after theme change
        // This ensures width=120 fonts are respected consistently
        NavigationFontConfig.forceApplyToAllNavigationBars()
        
        // Do the force update with minimal recursion
        await performOptimizedForceUpdate()
    }
    
    /// Perform force update with minimal recursion and better performance
    private func performOptimizedForceUpdate() async {
        // Ensure we're on the main thread for UI operations
        await MainActor.run {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            
            for window in windowScene.windows {
                // Find all navigation controllers efficiently
                let navControllers = findAllNavigationControllers(in: window.rootViewController)
                
                // Update them on main thread
                for navController in navControllers {
                    updateSingleNavigationBar(navController.navigationBar)
                }
            }
        }
    }
    
    /// Efficiently find all navigation controllers without deep recursion
    private func findAllNavigationControllers(in viewController: UIViewController?) -> [UINavigationController] {
        var navControllers: [UINavigationController] = []
        var queue: [UIViewController] = []
        
        if let vc = viewController {
            queue.append(vc)
        }
        
        while !queue.isEmpty {
            let current = queue.removeFirst()
            
            if let navController = current as? UINavigationController {
                navControllers.append(navController)
            }
            
            queue.append(contentsOf: current.children)
            
            if let presented = current.presentedViewController {
                queue.append(presented)
            }
        }
        
        return navControllers
    }
    
    /// Update a single navigation bar efficiently
    private func updateSingleNavigationBar(_ navBar: UINavigationBar) {
        // Ensure we're on the main thread for UI operations
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.updateSingleNavigationBar(navBar)
            }
            return
        }
        
        // Get current appearances async
        let standard = UINavigationBar.appearance().standardAppearance
        let scrollEdge = UINavigationBar.appearance().scrollEdgeAppearance ?? standard
        let compact = UINavigationBar.appearance().compactAppearance ?? standard
        
        // Apply to this specific navigation bar
        navBar.standardAppearance = standard
        navBar.scrollEdgeAppearance = scrollEdge
        navBar.compactAppearance = compact
        
        // Force immediate update (only on main thread)
        navBar.setNeedsLayout()
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
        Task {
            await applyToNavigationBar()
        }
        
        // Force all existing navigation bars to update (ensure main thread)
        if Thread.isMainThread {
            performLegacyForceUpdate()
        } else {
            DispatchQueue.main.async {
                self.performLegacyForceUpdate()
            }
        }
    }
    
    /// Perform the legacy force update on main thread
    private func performLegacyForceUpdate() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        
        for window in windowScene.windows {
            // Find all navigation controllers and force update their navigation bars
            updateNavigationBarsRecursively(in: window.rootViewController)
            
            // Force update all UINavigationBar instances directly
            forceUpdateAllNavigationBarInstances(in: window)
            
            // Force window to update
            window.setNeedsDisplay()
            window.layoutIfNeeded()
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
                
                // Force immediate update (main thread only)
                if Thread.isMainThread {
                    navBar.setNeedsLayout()
                    navBar.layoutIfNeeded()
                    navBar.setNeedsDisplay()
                }
                
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
            
            // Force update (main thread only)
            if Thread.isMainThread {
                navBar.setNeedsLayout()
                navBar.layoutIfNeeded()
                navBar.setNeedsDisplay()
            }
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
    
    // MARK: - SwiftUI Theme Colors
    
    /// Get the tab bar background color for current theme
    func tabBarBackgroundColor(for colorScheme: ColorScheme) -> Color {
        let effectiveScheme = effectiveColorScheme(for: colorScheme)
        
        switch (effectiveScheme, darkThemeMode) {
        case (.dark, .black):
            return Color.black
        case (.dark, .dim):
            return Color(red: 0.18, green: 0.18, blue: 0.20)
        case (.light, _):
            return Color(.systemBackground)
        default:
            return Color(.systemBackground)
        }
    }
    
    /// Get the tab bar background color for current theme (convenience property)
    var tabBarBackgroundColor: Color {
        // Default to current system color scheme if no override
        let scheme: ColorScheme = colorSchemeOverride ?? .light
        return tabBarBackgroundColor(for: scheme)
    }
    
    /// Get the current effective color scheme based on override
    var effectiveColorScheme: ColorScheme {
        colorSchemeOverride ?? .light // Default to light if no override
    }
    
    /// Get the dim background color
    var dimBackgroundColor: Color {
        Color(red: 0.18, green: 0.18, blue: 0.20)
    }
    
    // Tab bar theming now handled by SwiftUI modifiers - removed complex UITabBar.appearance() approach
    
    /// Apply theme to toolbars
    private func applyToToolbar() async {
        await MainActor.run {
            let appearance = UIToolbarAppearance()
            
            Task {
                let isDarkMode = await getCurrentEffectiveDarkMode()
                
                await MainActor.run {
                    if isDarkMode {
                        if darkThemeMode == .black {
                            appearance.backgroundColor = UIColor.black
                            appearance.shadowColor = .clear
                        } else {
                            // Dim mode
                            let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                            appearance.configureWithOpaqueBackground()
                            appearance.backgroundColor = dimBackground
                            appearance.shadowColor = .clear
                        }
                    } else {
                        appearance.configureWithTransparentBackground()
                    }
                    
                    UIToolbar.appearance().standardAppearance = appearance
                    UIToolbar.appearance().scrollEdgeAppearance = appearance
                }
            }
        }
    }
    
    /// Apply theme to table views
    private func applyToTableView() async {
        let isDarkMode = await getCurrentEffectiveDarkMode()
        await MainActor.run {
            if isDarkMode {
                UITableView.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
                UITableView.appearance().separatorColor = UIColor(Color.dynamicSeparator(self, currentScheme: .dark))
                
                UITableViewCell.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
                
                // Configure section headers
                UITableViewHeaderFooterView.appearance().tintColor = UIColor(Color.dynamicSecondaryBackground(self, currentScheme: .dark))
            }
        }
    }
    
    /// Apply theme to collection views
    private func applyToCollectionView() async {
        let isDarkMode = await getCurrentEffectiveDarkMode()
        await MainActor.run {
            if isDarkMode {
                UICollectionView.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
            }
        }
    }
    
    /// Get current effective dark mode state
    private func getCurrentEffectiveDarkMode() async -> Bool {
        switch colorSchemeOverride {
        case .light:
            return false
        case .dark:
            return true
        case nil:
            // Follow system
            return await MainActor.run {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    return window.traitCollection.userInterfaceStyle == .dark
                }
                return false
            }
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
        
        Task { @MainActor in
            let isDark = await getCurrentEffectiveDarkMode()
            self.configureNavigationAppearance(appearance, isDark: isDark)
            navigationBar.standardAppearance = appearance
            navigationBar.scrollEdgeAppearance = appearance
            navigationBar.compactAppearance = appearance
        }
    }
    
    private func configureNavigationAppearance(_ appearance: UINavigationBarAppearance, isDark: Bool) {
        if isDark {
            if darkThemeMode == .black {
                // True black mode
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = .clear
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = .clear
            }
        } else {
            // Light mode - transparent to avoid hairlines
            appearance.configureWithTransparentBackground()
        }
        
        // Apply fonts
        NavigationFontConfig.applyFonts(to: appearance)
        
        // Apply text color
        let textColor = isDark 
            ? UIColor(Color.dynamicText(self, style: .primary, currentScheme: .dark))
            : UIColor.label
        
        var titleAttrs = appearance.titleTextAttributes
        titleAttrs[.foregroundColor] = textColor
        appearance.titleTextAttributes = titleAttrs
        
        var largeTitleAttrs = appearance.largeTitleTextAttributes
        largeTitleAttrs[.foregroundColor] = textColor
        appearance.largeTitleTextAttributes = largeTitleAttrs
    }
    
    /// Apply theme to a specific toolbar instance
    func applyTheme(to toolbar: UIToolbar) {
        let appearance = UIToolbarAppearance()
        
        Task { @MainActor in
            let isDark = await getCurrentEffectiveDarkMode()
            self.configureToolbarAppearance(appearance, isDark: isDark)
            toolbar.standardAppearance = appearance
            toolbar.scrollEdgeAppearance = appearance
        }
    }
    
    private func configureToolbarAppearance(_ appearance: UIToolbarAppearance, isDark: Bool) {
        if isDark {
            if darkThemeMode == .black {
                appearance.backgroundColor = UIColor.black
                appearance.shadowColor = .clear
            } else {
                // Dim mode
                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
                appearance.configureWithOpaqueBackground()
                appearance.backgroundColor = dimBackground
                appearance.shadowColor = .clear
            }
        } else {
            appearance.configureWithTransparentBackground()
        }
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
