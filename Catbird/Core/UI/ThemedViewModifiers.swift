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
        self.background {
            ThemedContrastAwareBackground(
                themeManager: themeManager,
                appSettings: appSettings
            ) { colorScheme, increaseContrast in
                CatbirdThemeColors.resolve(
                    themeManager: themeManager,
                    colorScheme: colorScheme,
                    contrast: increaseContrast ? .increased : .standard
                ).surface(.canvas)
            }
            .ignoresSafeArea(.all)
        }
    }
    
    // MARK: - Secondary Background
    
    /// Apply secondary background color based on theme
    func themedSecondaryBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.background {
            ThemedContrastAwareBackground(
                themeManager: themeManager,
                appSettings: appSettings
            ) { colorScheme, increaseContrast in
                CatbirdThemeColors.resolve(
                    themeManager: themeManager,
                    colorScheme: colorScheme,
                    contrast: increaseContrast ? .increased : .standard
                ).surface(.card)
            }
            .ignoresSafeArea(.all)
        }
    }
    
    // MARK: - Tertiary Background
    
    /// Apply tertiary background color based on theme
    func themedTertiaryBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.background {
            ThemedBackground(themeManager: themeManager) { colorScheme in
                CatbirdThemeColors.resolve(
                    themeManager: themeManager,
                    colorScheme: colorScheme
                ).surface(.elevated)
            }
            .ignoresSafeArea(.all)
        }
    }
    
    // MARK: - Elevated Background
    
    /// Apply elevated background color based on theme (for cards and modals)
    func themedElevatedBackground(_ themeManager: ThemeManager, elevation: ColorElevation = .low, appSettings: AppSettings) -> some View {
        self.background {
            ThemedElevatedBackground(themeManager: themeManager, elevation: elevation)
        }
    }
    
    // MARK: - Grouped Background
    
    /// Apply grouped background color based on theme (for list backgrounds)
    func themedGroupedBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.background {
            ThemedBackground(themeManager: themeManager) { colorScheme in
                CatbirdThemeColors.resolve(
                    themeManager: themeManager,
                    colorScheme: colorScheme
                ).surface(.grouped)
            }
            .ignoresSafeArea(.all)
        }
    }
}

// MARK: - Text Modifiers

extension View {
    /// Apply themed text color with automatic accessibility support
    func themedText(_ themeManager: ThemeManager, style: TextStyle = .primary, appSettings: AppSettings? = nil) -> some View {
        self.modifier(ThemedTextModifier(themeManager: themeManager, style: style, appSettings: appSettings))
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
                    CatbirdThemeColors.resolve(
                        themeManager: themeManager,
                        colorScheme: colorScheme,
                        contrast: increaseContrast ? .increased : .standard
                    ).border(.subtle)
                }
            }
    }
}

// MARK: - List Row Modifiers

extension View {
    /// Apply themed list row background
    func themedListRowBackground(_ themeManager: ThemeManager, appSettings: AppSettings) -> some View {
        self.listRowBackground(
            ThemedBackground(themeManager: themeManager) { colorScheme in
                CatbirdThemeColors.resolve(
                    themeManager: themeManager,
                    colorScheme: colorScheme
                ).surface(.canvas)
            }
            .ignoresSafeArea(.all)
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
                    CatbirdThemeColors.resolve(
                        themeManager: themeManager,
                        colorScheme: colorScheme
                    ).surface(.elevated)
                }
                .ignoresSafeArea(.all)
            }
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

struct AdaptiveContrastModifier: ViewModifier {
    let themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    
    func body(content: Content) -> some View {
        let theme = CatbirdThemeColors.resolve(themeManager: themeManager, colorScheme: colorScheme)
        content
            .if(theme.isTrueBlack && differentiateWithoutColor) { view in
                view.overlay(
                    Radius.sm.shape
                        .strokeBorder(theme.border(.prominent), lineWidth: 1)
                )
            }
            .if(reduceTransparency) { view in
                view.background {
                    theme.surface(.canvas)
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
    }
    
    private func applyNavigationBarTheme() {
        // Navigation bar typography and accent tint are owned by ThemeManager.applyTheme().
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
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    
    var body: some View {
        colorProvider(colorScheme, accessibilityContrast == .increased || appSettings.effectiveIncreaseContrast)
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
                        Rectangle()
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
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var glassStyle: CatbirdGlassStyle {
        switch intensity {
        case .subtle: return .clear
        case .medium, .strong: return .regular
        }
    }

    var body: some View {
        let resolvedTheme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: colorScheme,
            contrast: colorSchemeContrast
        )
        Color.clear
            .catbirdGlass(glassStyle, in: Rectangle())
            .environment(\.catbirdTheme, resolvedTheme)
    }
}

struct ThemedTextModifier: ViewModifier {
    let themeManager: ThemeManager
    let style: TextStyle
    let appSettings: AppSettings?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    
    init(themeManager: ThemeManager, style: TextStyle = .primary, appSettings: AppSettings? = nil) {
        self.themeManager = themeManager
        self.style = style
        self.appSettings = appSettings
    }
    
    func body(content: Content) -> some View {
        let increaseContrast = accessibilityContrast == .increased || (appSettings?.effectiveIncreaseContrast ?? false)
        let theme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: colorScheme,
            contrast: increaseContrast ? .increased : .standard
        )
        let role: CatbirdTextRoleColor = {
            switch style {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return .tertiary
            case .disabled: return .disabled
            }
        }()
        content.foregroundStyle(theme.text(role))
    }
}

struct ThemedAccessibleTextView<Content: View>: View {
    let content: Content
    let themeManager: ThemeManager
    let style: TextStyle
    let appSettings: AppSettings?
    
    init(content: Content, themeManager: ThemeManager, style: TextStyle = .primary, appSettings: AppSettings? = nil) {
        self.content = content
        self.themeManager = themeManager
        self.style = style
        self.appSettings = appSettings
    }
    
    var body: some View {
        content.modifier(ThemedTextModifier(themeManager: themeManager, style: style, appSettings: appSettings))
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
    @Environment(\.colorSchemeContrast) private var accessibilityContrast
    
    init(themeManager: ThemeManager, isProminent: Bool, appSettings: AppSettings? = nil) {
        self.themeManager = themeManager
        self.isProminent = isProminent
        self.appSettings = appSettings
    }
    
    var body: some View {
        let increaseContrast = accessibilityContrast == .increased || (appSettings?.effectiveIncreaseContrast ?? false)
        let theme = CatbirdThemeColors.resolve(
            themeManager: themeManager,
            colorScheme: colorScheme,
            contrast: increaseContrast ? .increased : .standard
        )
        Radius.md.shape
            .strokeBorder(
                theme.border(isProminent ? .prominent : .subtle),
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

#Preview("Themed Background") {
  let fontManager = FontManager()
  let themeManager = ThemeManager(fontManager: fontManager)
  VStack(spacing: 20) {
    ThemedBackground(
      themeManager: themeManager,
      colorProvider: { scheme in
        CatbirdThemeColors.resolve(themeManager: themeManager, colorScheme: scheme).accentChrome
      }
    )
    .frame(height: 100)
    .overlay(Text(verbatim: "Themed Background"))

    ThemedGlassBackground(
      themeManager: themeManager,
      intensity: .medium
    )
    .frame(height: 100)
    .overlay(Text(verbatim: "Glass Background"))
  }
  .padding()
}
