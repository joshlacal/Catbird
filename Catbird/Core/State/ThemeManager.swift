import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import OSLog

/// Manages theme application throughout the app
@Observable final class ThemeManager {
    private let logger = Logger(subsystem: "blue.catbird", category: "ThemeManager")
    private let fontManager: FontManager
    
    // MARK: - Properties
    
    /// Current color scheme override (nil means follow system)
    var colorSchemeOverride: ColorScheme?
    
    /// Current dark theme mode (dim or black)
    var darkThemeMode: DarkThemeMode = .dim
    
    // MARK: - Caching Properties
    
    /// Cache current theme settings to avoid redundant applications
    private var currentTheme: String = ""
    private var currentDarkThemeMode: String = ""

    /// Debounce force navigation bar updates to prevent infinite loops
    private var lastForceUpdateTime: Date = Date.distantPast
    private let forceUpdateDebounceInterval: TimeInterval = 0.1 // 100ms

    /// Theme application debouncing
    private var themeApplyTask: Task<Void, Never>?
    private let themeApplyDebounceInterval: TimeInterval = 0.1 // 100ms
    
    // MARK: - Theme Definitions
    
    enum DarkThemeMode {
        case dim     // Standard dark mode with grays
        case black   // True black with proper hierarchy
    }
    
    // MARK: - Initialization
    
    init(fontManager: FontManager) {
        self.fontManager = fontManager
    }
    
    // MARK: - Methods
    
    /// Apply theme based on current settings
    /// - Parameters:
    ///   - theme: user selected theme (light/dark/system)
    ///   - darkThemeMode: dim/black preference
    ///   - forceImmediateNavigationTypography: when true, navigation title fonts are applied right away to avoid the initial width flicker before the debounced pass runs
    func applyTheme(theme: String, darkThemeMode: String, forceImmediateNavigationTypography: Bool = false) {
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

        // Invalidate font cache when theme changes (fonts may need regeneration)
        NavigationFontConfig.invalidateCache()

        // Cancel any pending theme application
        themeApplyTask?.cancel()

        if forceImmediateNavigationTypography {
            // Apply navigation typography immediately to avoid first-frame flashes before the debounced task runs
            Task { @MainActor in
                await applyToNavigationBar()
                NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
            }
        }

        // Debounce theme application to coalesce rapid changes
        themeApplyTask = Task { @MainActor in
            // Wait for debounce interval
            try? await Task.sleep(nanoseconds: UInt64(themeApplyDebounceInterval * 1_000_000_000))

            // Check if cancelled
            guard !Task.isCancelled else { return }

            // Batch all theme updates to reduce main thread blocking
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
        #if os(iOS)
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
                
                // Set window tint color based on theme
                Task {
                    let isDarkMode = await getCurrentEffectiveDarkMode()
                    await MainActor.run {
                        if isDarkMode && darkThemeMode == .black {
                            // Slightly brighter accent for better visibility on black
                            window.tintColor = UIColor.systemBlue.withAlphaComponent(1.0)
                        } else {
                            // Reset to system default for all other cases
                            window.tintColor = nil
                        }
                    }
                }
            }
            
            logger.info("Theme applied to \(windowScene.windows.count) windows")
        }
        #elseif os(macOS)
        await MainActor.run {
            // macOS window appearance handling
            for window in NSApplication.shared.windows {
                if let override = colorSchemeOverride {
                    window.appearance = override == .dark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
                } else {
                    window.appearance = nil  // Use system appearance
                }
            }
            logger.info("Theme applied to \(NSApplication.shared.windows.count) windows")
        }
        #endif
    }
    
    /// Apply typography theming to navigation bars (colors handled by system)
    private func applyToNavigationBar() async {
        #if os(iOS)
        await MainActor.run {
            // Create base appearances with system defaults (no custom colors)
            let standardAppearance = UINavigationBarAppearance()
            let scrollEdgeAppearance = UINavigationBarAppearance()
            let compactAppearance = UINavigationBarAppearance()
            
            // Configure with system defaults - no custom colors
            standardAppearance.configureWithDefaultBackground()
            scrollEdgeAppearance.configureWithDefaultBackground()  // Proper for large titles
            compactAppearance.configureWithOpaqueBackground()
            
            // Apply custom typography to all appearances
            NavigationFontConfig.applyFonts(to: standardAppearance, fontManager: fontManager)
            NavigationFontConfig.applyFonts(to: scrollEdgeAppearance, fontManager: fontManager)
            NavigationFontConfig.applyFonts(to: compactAppearance, fontManager: fontManager)
            
            // Set the appearances (now with typography but system colors)
            UINavigationBar.appearance().standardAppearance = standardAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = scrollEdgeAppearance
            UINavigationBar.appearance().compactAppearance = compactAppearance
            
            logger.info("Applied typography theming to navigation bars (system colors preserved)")
        }
        #endif
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
        #if os(iOS)
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
        NavigationFontConfig.forceApplyToAllNavigationBars(fontManager: fontManager)
        
        // Do the force update with minimal recursion
        await performOptimizedForceUpdate()
        #endif
    }
    
    /// Perform force update with minimal recursion and better performance
    private func performOptimizedForceUpdate() async {
        #if os(iOS)
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
        #endif
    }
    
    /// Efficiently find all navigation controllers without deep recursion
    #if os(iOS)
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
    #endif
    
    /// Update a single navigation bar efficiently
    #if os(iOS)
    @MainActor
    private func updateSingleNavigationBar(_ navBar: UINavigationBar) {
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
    #endif
    
    /// Force update all navigation bars typography (colors handled by system)
    func forceUpdateNavigationBars() {
        #if os(iOS)
        let now = Date()
        
        // Debounce to prevent infinite loops
        if now.timeIntervalSince(lastForceUpdateTime) < forceUpdateDebounceInterval {
            logger.debug("Skipping force navigation bar update due to debouncing")
            return
        }
        
        lastForceUpdateTime = now
        logger.info("Force updating navigation bar typography")
        
        // Re-apply navigation bar typography theme (not colors)
        Task {
            await applyToNavigationBar()
        }
        
        // Force all existing navigation bars to update typography
        Task { @MainActor in
            self.performLegacyForceUpdate()
        }
        #endif
    }
    
    /// Perform the legacy force update on main thread
    private func performLegacyForceUpdate() {
        #if os(iOS)
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
        #endif
    }
#if os(iOS)

    /// Aggressively find and update all UINavigationBar typography
    private func forceUpdateAllNavigationBarInstances(in window: UIWindow) {
        func findNavigationBars(in view: UIView) {
            if let navBar = view as? UINavigationBar {
                // Get current appearances (now only contain typography, not color overrides)
                let standard = UINavigationBar.appearance().standardAppearance
                let scrollEdge = UINavigationBar.appearance().scrollEdgeAppearance ?? standard
                let compact = UINavigationBar.appearance().compactAppearance ?? standard
                
                // Force apply typography to this specific navigation bar
                navBar.standardAppearance = standard
                navBar.scrollEdgeAppearance = scrollEdge
                navBar.compactAppearance = compact
                
                // Force immediate update (main thread only)
                if Thread.isMainThread {
                    navBar.setNeedsLayout()
                    navBar.layoutIfNeeded()
                    navBar.setNeedsDisplay()
                }
                
                logger.debug("Force updated navigation bar typography: \(navBar)")
            }
            
            // Recursively check all subviews
            for subview in view.subviews {
                findNavigationBars(in: subview)
            }
        }
        
        findNavigationBars(in: window)
    }
#endif // os(iOS)

    /// Recursively update navigation bars in view controller hierarchy
    #if os(iOS)
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
    #endif
    
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
            return Color.systemBackground
        default:
            return Color.systemBackground
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
        #if os(iOS)
        await MainActor.run {
            let appearance = UIToolbarAppearance()
            
            Task {
                let isDarkMode = await getCurrentEffectiveDarkMode()
                
                await MainActor.run {
//                    if isDarkMode {
//                        if darkThemeMode == .black {
//                            appearance.backgroundColor = UIColor.black
//                            appearance.shadowColor = .clear
//                        } else {
//                            // Dim mode
//                            let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
//                            appearance.configureWithOpaqueBackground()
//                            appearance.backgroundColor = dimBackground
//                            appearance.shadowColor = .clear
//                        }
//                    } else {
                        appearance.configureWithTransparentBackground()
//                    }
                    
                    UIToolbar.appearance().standardAppearance = appearance
                    UIToolbar.appearance().scrollEdgeAppearance = appearance
                }
            }
        }
        #endif
    }
    
    /// Apply theme to table views
    private func applyToTableView() async {
        #if os(iOS)
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
        #endif
    }
    
    /// Apply theme to collection views
    private func applyToCollectionView() async {
        #if os(iOS)
        let isDarkMode = await getCurrentEffectiveDarkMode()
        await MainActor.run {
            if isDarkMode {
                UICollectionView.appearance().backgroundColor = UIColor(Color.dynamicBackground(self, currentScheme: .dark))
            }
        }
        #endif
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
            #if os(iOS)
            return await MainActor.run {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first {
                    return window.traitCollection.userInterfaceStyle == .dark
                }
                return false
            }
            #elseif os(macOS)
            return await MainActor.run {
                if let window = NSApplication.shared.mainWindow {
                    return window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                }
                return false
            }
            #else
            return false
            #endif
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
    
    #if os(iOS)
    /// Apply typography theming to a specific navigation bar instance
    /// This is useful for UIKit views embedded in SwiftUI (only applies fonts, not colors)
    func applyTheme(to navigationBar: UINavigationBar) {
        // Only apply typography - let SwiftUI handle colors for proper translucency
        NavigationFontConfig.applyFonts(to: navigationBar, fontManager: fontManager)
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
    #endif
    
    #if os(iOS)
    private func configureToolbarAppearance(_ appearance: UIToolbarAppearance, isDark: Bool) {
//        if isDark {
//            if darkThemeMode == .black {
//                appearance.backgroundColor = UIColor.black
//                appearance.shadowColor = .clear
//            } else {
//                // Dim mode
//                let dimBackground = UIColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
//                appearance.configureWithOpaqueBackground()
//                appearance.backgroundColor = dimBackground
//                appearance.shadowColor = .clear
//            }
//        } else {
            appearance.configureWithDefaultBackground()
//        }
    }
    #endif
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
