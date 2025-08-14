import Foundation
import UIKit

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
                UIView.animate(withDuration: 0.3, animations: {
                    snapshot.alpha = 0
                }) { _ in
                    snapshot.removeFromSuperview()
                }
            }
        }
    }
}
