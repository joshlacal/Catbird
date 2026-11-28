import SwiftUI

extension EnvironmentValues {
    private struct AdultContentEnabledKey: EnvironmentKey {
        static let defaultValue = false
    }

    var adultContentEnabled: Bool {
        get { self[AdultContentEnabledKey.self] }
        set { self[AdultContentEnabledKey.self] = newValue }
    }
}

private struct AppStateThemeEnvironmentModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let themeManager: ThemeManager

    func body(content: Content) -> some View {
        let resolvedTheme = themeManager.resolvedTheme(
            for: colorScheme,
            contrast: colorSchemeContrast
        )
        content
            .environment(\.themeManager, themeManager)
            .environment(\.catbirdTheme, resolvedTheme)
    }
}

extension View {
    func applyAppStateEnvironment(_ appState: AppState) -> some View {
        self
            .environment(appState)
            .environment(\.appSettings, appState.appSettings)
            .environment(\.moderationPolicy, appState.moderationPolicy)
            .environment(\.adultContentEnabled, appState.moderationPolicy.adultContentEnabled)
            .modifier(AppStateThemeEnvironmentModifier(themeManager: appState.themeManager))
    }
}
