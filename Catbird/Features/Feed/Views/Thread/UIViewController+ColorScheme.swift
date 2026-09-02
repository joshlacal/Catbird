#if os(iOS)
import SwiftUI
import UIKit

// MARK: - UIKit Color Scheme Helper
extension UIViewController {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
        if let activeState = AppStateManager.shared.lifecycle.appState {
            return activeState.themeManager.effectiveColorScheme(for: systemScheme)
        }
        return systemScheme
    }
}

extension UIView {
    func getCurrentColorScheme() -> ColorScheme {
        let systemScheme: ColorScheme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        // Use ThemeManager's effective color scheme to account for manual overrides
        if let activeState = AppStateManager.shared.lifecycle.appState {
            return activeState.themeManager.effectiveColorScheme(for: systemScheme)
        }
        return systemScheme
    }
}
#endif
