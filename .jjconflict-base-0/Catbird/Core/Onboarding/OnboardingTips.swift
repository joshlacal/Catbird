import SwiftUI
import TipKit

// MARK: - Settings Access Tip

/// Tip for finding settings through the avatar button
struct SettingsAccessTip: Tip {
    var title: Text {
        Text("Your Settings")
    }
    
    var message: Text? {
        Text("Tap your avatar to access app settings, account options, and preferences.")
    }
    
    var image: Image? {
        Image(systemName: "person.circle")
    }
    
    var options: [any Option] {
        [
            Tips.MaxDisplayCount(2)
        ]
    }
}
