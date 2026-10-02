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

extension View {
    func applyAppStateEnvironment(_ appState: AppState) -> some View {
        self
            .environment(appState)
            .environment(\.appSettings, appState.appSettings)
            .environment(\.adultContentEnabled, appState.isAdultContentEnabled)
    }
}
