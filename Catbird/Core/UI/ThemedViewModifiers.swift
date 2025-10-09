import SwiftUI

// MARK: - Glass Intensity

enum GlassIntensity: Int {
    case subtle = 0
    case medium = 1
    case strong = 2
    
    var elevationLevel: ColorElevation {
        switch self {
        case .subtle: return .low
        case .medium: return .medium
        case .strong: return .high
        }
    }
}

// MARK: - Themed Background Modifiers

extension View {
    
    // MARK: - Primary Background
    
    /// Apply primary background color based on theme
    func themedPrimaryBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        ZStack {
            Color.clear
            self
        }
        .background { 
            ThemedContrastAwareBackground(
                themeManager: themeManager,
                appSettings: appSettings
            ) { colorScheme, increaseContrast in
                Color.dynamicBackground(themeManager, currentScheme: colorScheme)
            }
            .ignoresSafeArea(.all)
        }
        .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Secondary Background
    
    /// Apply secondary background color based on theme
    func themedSecondaryBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        ZStack {
            Color.clear
            self
        }
        .background { 
            ThemedContrastAwareBackground(
                themeManager: themeManager,
                appSettings: appSettings
            ) { colorScheme, increaseContrast in
                Color.dynamicSecondaryBackground(themeManager, currentScheme: colorScheme)
            }
            .ignoresSafeArea(.all)
        }
        .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Tertiary Background
    
    /// Apply tertiary background color based on theme
    func themedTertiaryBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        ZStack {
            Color.clear
            self
        }
        .background { 
            ThemedBackground(themeManager: themeManager) { colorScheme in
                Color.dynamicTertiaryBackground(themeManager, currentScheme: colorScheme)
            }
            .ignoresSafeArea(.all)
        }
        .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Elevated Background
    
    /// Apply elevated background color based on theme (for cards and modals)
    func themedElevatedBackground(_ themeManager: ThemeManager, elevation: ColorElevation = .low, appSettings: AppSettings) -> some View {
        ZStack {
            Color.clear
            self
        }
        .background { 
            ThemedElevatedBackground(themeManager: themeManager, elevation: elevation)
        }
        .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Grouped Background
    
    /// Apply grouped background color based on theme (for list backgrounds)
    func themedGroupedBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        ZStack {
            Color.clear
            self
        }
        .background { 
            ThemedBackground(themeManager: themeManager) { colorScheme in
                Color.dynamicGroupedBackground(themeManager, currentScheme: colorScheme)
            }
            .ignoresSafeArea(.all)
        }
        .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Glass Effects
    
    /// Apply a glass-like card effect based on theme
    func themedSolariumCard(
        intensity: GlassIntensity = .medium,
        themeManager: ThemeManager,
        appSettings: AppSettings
    ) -> some View {
        self
            .background(glassBackground(intensity: intensity, themeManager: themeManager))
            .overlay(glassBorder(intensity: intensity, themeManager: themeManager, appSettings: appSettings))
            .cornerRadius(12)
            .background(glassShadow(intensity: intensity, themeManager: themeManager))
            .themeTransition(themeManager, appSettings: appSettings)
    }
    
    /// Apply a glass-like button effect based on theme
    func themedSolariumButton(
        intensity: GlassIntensity = .medium,
        themeManager: ThemeManager,
        appSettings: AppSettings
    ) -> some View {
        self
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(glassBackground(intensity: intensity, themeManager: themeManager))
            .overlay(glassBorder(intensity: intensity, themeManager: themeManager, appSettings: appSettings).cornerRadius(8))
            .cornerRadius(8)
            .themeTransition(themeManager, appSettings: appSettings)
    }
    
    // MARK: - Private Helper Methods
    
    @ViewBuilder
    private func glassBackground(intensity: GlassIntensity, themeManager: ThemeManager) -> some View {
        ThemedGlassBackground(themeManager: themeManager, intensity: intensity)
    }
    
    private func glassBorder(intensity: GlassIntensity, themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        ThemedBorderView(themeManager: themeManager, isProminent: intensity == .strong, appSettings: appSettings)
    }
    
    private func glassShadow(intensity: GlassIntensity, themeManager: ThemeManager) -> some View {
        ThemedShadowView(themeManager: themeManager)
    }
    
    private func glassBlurRadius(intensity: GlassIntensity) -> CGFloat {
        switch intensity {
        case .subtle:
            return 4
        case .medium:
            return 6
        case .strong:
            return 8
        }
    }
}

// MARK: - Text Modifiers

extension View {
    /// Apply themed text color with automatic accessibility support
    func themedText(_ themeManager: ThemeManager, style: TextStyle = .primary, appSettings: AppSettings) -> some View {
        ThemedAccessibleTextView(content: self, themeManager: themeManager, style: style, appSettings: appSettings)
            .themeTransition(themeManager, appSettings: appSettings)
    }
}

// MARK: - Separator Modifiers

extension View {
    /// Add a themed separator
    func themedDivider(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        Divider()
            .background {
                ThemedContrastAwareBackground(
                    themeManager: themeManager,
                    appSettings: appSettings
                ) { colorScheme, increaseContrast in
                    Color.dynamicSeparator(themeManager, currentScheme: colorScheme, increaseContrast: increaseContrast)
                }
            }
            .themeTransition(themeManager, appSettings: appSettings)
    }
}

// MARK: - List Row Modifiers

extension View {
    /// Apply themed list row background
    func themedListRowBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.listRowBackground(
            ThemedBackground(themeManager: themeManager) { colorScheme in
                Color.dynamicBackground(themeManager, currentScheme: colorScheme)
            }
            .ignoresSafeArea(.all)
            .themeTransition(themeManager, appSettings: appSettings)
        )
    }
}

// MARK: - Sheet Modifiers

extension View {
    /// Apply themed sheet background
    func themedSheetBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self
            .background {
                ThemedBackground(themeManager: themeManager) { colorScheme in
                    Color.elevatedBackground(themeManager, elevation: .modal, currentScheme: colorScheme)
                }
                .ignoresSafeArea(.all)
            }
            .themeTransition(themeManager, appSettings: appSettings)
    }
}

// MARK: - Accessibility Support

extension View {
    /// Apply adaptive contrast for accessibility
    func adaptiveContrast(_ themeManager: ThemeManager) -> some View {
        self.modifier(AdaptiveContrastModifier(themeManager: themeManager))
    }
    
    /// Apply contrast-aware background with app state
    func contrastAwareBackground(appState: AppState?, defaultColor: Color = .clear) -> some View {
        self.modifier(ContrastAwareBackgroundModifier(appState: appState, defaultColor: defaultColor))
    }
}

struct ContrastAwareBackgroundModifier: ViewModifier {
    let appState: AppState?
    let defaultColor: Color
    
    func body(content: Content) -> some View {
        content.background(Color.adaptiveBackground(appState: appState, defaultColor: defaultColor))
    }
}

struct AccessibleButtonStyle: ButtonStyle {
    let appState: AppState?
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.adaptiveForeground(appState: appState, defaultColor: .accentColor))
            .background(Color.adaptiveBackground(appState: appState, defaultColor: .accentColor.opacity(0.1)))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.adaptiveBorder(appState: appState), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .accessibleAnimation(.easeInOut(duration: 0.2), value: configuration.isPressed, appState: appState)
    }
}

struct AdaptiveContrastModifier: ViewModifier {
    let themeManager: ThemeManager
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    
    func body(content: Content) -> some View {
        content
            .if(themeManager.isUsingTrueBlack && differentiateWithoutColor) { view in
                view.overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
            }
            .if(reduceTransparency) { view in
                view.background {
                    ThemedBackground(themeManager: themeManager) { colorScheme in
                        Color.dynamicBackground(themeManager, currentScheme: colorScheme)
                    }
                }
            }
    }
}

// MARK: - Navigation Bar Modifiers

extension View {
    /// Apply themed navigation bar appearance
    func themedNavigationBar(_ themeManager: ThemeManager) -> some View {
        self.modifier(ThemedNavigationBarModifier(themeManager: themeManager))
    }
}

struct ThemedNavigationBarModifier: ViewModifier {
    let themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    
    func body(content: Content) -> some View {
        let isDarkMode = themeManager.isDarkMode(for: colorScheme)
        let isBlackMode = themeManager.isUsingTrueBlack
        
        content
            .onAppear {
                applyNavigationBarTheme()
            }
            .onChange(of: colorScheme) {
                applyNavigationBarTheme()
            }
            .onChange(of: themeManager.darkThemeMode) {
                applyNavigationBarTheme()
            }
            .onChange(of: themeManager.colorSchemeOverride) {
                applyNavigationBarTheme()
            }
            // Apply toolbar background based on theme using SwiftUI approach
//            .toolbarBackground(
//                isDarkMode ? (isBlackMode ? Color.black : themeManager.dimBackgroundColor) : Color(.systemBackground),
//                for: .navigationBar
//            )
//            .toolbarBackground(
//                isDarkMode ? (isBlackMode ? Color.black : themeManager.dimBackgroundColor) : Color(.systemBackground),
//                for: .tabBar
//            )
//            .toolbarBackgroundVisibility(.visible, for: .tabBar)
//            .toolbarColorScheme(themeManager.effectiveColorScheme(for: colorScheme), for: .navigationBar)
//            .toolbarColorScheme(themeManager.effectiveColorScheme(for: colorScheme), for: .tabBar)
            // Ensure tab bar icons use the correct tint color
            .tint(isDarkMode && isBlackMode ? Color.blue.opacity(0.9) : nil)
    }
    
    private func applyNavigationBarTheme() {
        // Navigation bar theme is already applied by ThemeManager.applyTheme()
        // No need to call forceUpdateNavigationBars() here to avoid infinite loops
        // The toolbar modifiers above handle the appearance for this specific view
    }
}

// MARK: - Helper Extensions

// MARK: - Helper Views for Theme Access

struct ThemedBackground: View {
    let themeManager: ThemeManager
    let colorProvider: (ColorScheme) -> Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        colorProvider(colorScheme)
    }
}

struct ThemedContrastAwareBackground: View {
    let themeManager: ThemeManager
    let appSettings: AppSettings
    let colorProvider: (ColorScheme, Bool) -> Color
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        colorProvider(colorScheme, appSettings.increaseContrast)
    }
}

struct ThemedElevatedBackground: View {
    let themeManager: ThemeManager
    let elevation: ColorElevation
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Color.elevatedBackground(themeManager, elevation: elevation, currentScheme: colorScheme)
            .overlay(
                // Add subtle elevation effect in dark modes
                Group {
                    if themeManager.isDarkMode(for: colorScheme) && !themeManager.isUsingTrueBlack {
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.05),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                }
            )
    }
}

struct ThemedGlassBackground: View {
    let themeManager: ThemeManager
    let intensity: GlassIntensity
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        if themeManager.isUsingTrueBlack && themeManager.isDarkMode(for: colorScheme) {
            // True black mode: Use solid backgrounds with hierarchy
            ZStack {
                Color.elevatedBackground(themeManager, elevation: intensity.elevationLevel, currentScheme: colorScheme)
                
                // Add subtle inner glow for depth
                if intensity != .subtle {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color(white: 0.2, opacity: 0.1),
                                    Color(white: 0.1, opacity: 0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.plusLighter)
                }
            }
        } else {
            // Dim mode: Use translucent backgrounds with blur
            ZStack {
                // Base blur material with proper background
                switch intensity {
                case .subtle:
                    Rectangle()
                        .fill(.ultraThinMaterial)
                case .medium:
                    Rectangle()
                        .fill(.thinMaterial)
                case .strong:
                    Rectangle()
                        .fill(.regularMaterial)
                }
                
                // Overlay tint
                Color.glassOverlay(themeManager, intensity: intensity, currentScheme: colorScheme)
            }
        }
    }
}

struct ThemedAccessibleTextView<Content: View>: View {
    let content: Content
    let themeManager: ThemeManager
    let style: TextStyle
    let appSettings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    
    var body: some View {
        let baseColor = Color.dynamicText(themeManager, style: style, currentScheme: colorScheme)
        let accessibleColor = appState.appSettings.increaseContrast ? 
            Color.adaptiveForeground(appState: appState, defaultColor: baseColor) : baseColor
            
        content.foregroundColor(accessibleColor)
    }
}

// Keep the old view for backwards compatibility
struct ThemedTextView<Content: View>: View {
    let content: Content
    let themeManager: ThemeManager
    let style: TextStyle
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        content
            .foregroundColor(Color.dynamicText(themeManager, style: style, currentScheme: colorScheme))
    }
}

struct ThemedBorderView: View {
    let themeManager: ThemeManager
    let isProminent: Bool
    let appSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme
    
    init(themeManager: ThemeManager, isProminent: Bool, appSettings: AppSettings? = nil) {
        self.themeManager = themeManager
        self.isProminent = isProminent
        self.appSettings = appSettings
    }
    
    var body: some View {
        let increaseContrast = appSettings?.increaseContrast ?? false
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                Color.dynamicBorder(
                    themeManager, 
                    isProminent: isProminent, 
                    currentScheme: colorScheme, 
                    increaseContrast: increaseContrast
                ), 
                lineWidth: increaseContrast ? 2 : 1
            )
    }
}

struct ThemedShadowView: View {
    let themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        Color.clear
            .shadow(
                color: Color.dynamicShadow(themeManager, currentScheme: colorScheme),
                radius: 6,
                x: 0,
                y: 2
            )
    }
}

// MARK: - Material Extensions for Dim Mode

extension Material {
    /// Get appropriate material for dim mode backgrounds
    static func dimModeBackground(elevation: Int = 0) -> Material {
        switch elevation {
        case 0:
            return .ultraThinMaterial
        case 1:
            return .thinMaterial
        case 2:
            return .regularMaterial
        default:
            return .thickMaterial
        }
    }
}
