import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Bundle Extension for Language Support

extension Bundle {
    fileprivate static var languageKey = "AppleLanguages"
    
    static func setLanguage(_ language: String) {
        defer {
            // Force the app to use the new language
            object_setClass(Bundle.main, LanguageBundle.self)
        }
        
        if language == "system" {
            // Reset to system default
            UserDefaults.standard.removeObject(forKey: languageKey)
        } else {
            // Set the custom language
            UserDefaults.standard.set([language], forKey: languageKey)
        }
        UserDefaults.standard.synchronize()
    }
    
    static var currentLanguage: String {
        return UserDefaults.standard.stringArray(forKey: languageKey)?.first ?? "system"
    }
}

// MARK: - Private Language Bundle

private class LanguageBundle: Bundle, @unchecked Sendable {
    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        if let path = Bundle.main.path(forResource: currentLanguageCode, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
        return super.localizedString(forKey: key, value: value, table: tableName)
    }
    
    private var currentLanguageCode: String {
        let languages = UserDefaults.standard.stringArray(forKey: Bundle.languageKey) ?? []
        return languages.first ?? Locale.current.language.languageCode?.identifier ?? "en"
    }
}


/// The interface language belongs to the device, independently of account reading preferences.
struct InterfaceLanguagePreferences {
    var defaults: UserDefaults = AppSettingsModel.sharedDefaults()
    var apply: @MainActor (String) -> Void = { AppLanguageManager.shared.applyLanguage($0) }

    var selectedLanguage: String {
        defaults.string(forKey: "appLanguage") ?? Bundle.currentLanguage
    }

    @MainActor func select(_ language: String) {
        defaults.set(language, forKey: "appLanguage")
        apply(language)
    }

    static func availableLanguages(in bundle: Bundle = .main) -> [String] {
        let codes = bundle.localizations + [bundle.developmentLocalization].compactMap { $0 }
        return Set(codes.filter { $0 != "Base" && !$0.isEmpty }).sorted()
    }
}

// MARK: - App Language Manager

@MainActor
class AppLanguageManager {
    static let shared = AppLanguageManager()
    
    private init() {}
    
    func applyLanguage(_ languageCode: String) {
        Bundle.setLanguage(languageCode)
        
        // Post notification for views to update
        NotificationCenter.default.post(
            name: NSNotification.Name("AppLanguageDidChange"),
            object: nil,
            userInfo: ["language": languageCode]
        )
        
        #if os(iOS)
        // For immediate effect, you might need to recreate the UI
        // This is typically done by resetting the root view controller
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first {
            // Store the current root view controller
            let currentRoot = window.rootViewController
            
            // Create a snapshot for smooth transition
            if let snapshot = window.snapshotView(afterScreenUpdates: true) {
                window.addSubview(snapshot)
                
                // Recreate the root view controller
                // This forces all views to reload with the new language
                window.rootViewController = currentRoot
                
                // Animate the transition
                if UIAccessibility.isReduceMotionEnabled || (AppStateManager.shared.lifecycle.appState?.appSettings.effectiveReduceMotion ?? false) {
                    snapshot.removeFromSuperview()
                } else {
                    UIView.animate(withDuration: 0.3, animations: {
                        snapshot.alpha = 0
                    }) { _ in
                        snapshot.removeFromSuperview()
                    }
                }
            }
        }
        #elseif os(macOS)
        // On macOS, language changes typically require app restart
        // Post notification for any views that want to update immediately
        #endif
    }
}
