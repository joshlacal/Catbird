import SwiftUI

struct NetworkStatusIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        if !appState.networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.white)
                    .appFont(size: 14)
                
                Text("No Internet Connection")
                    .appFont(size: 14)
                    .foregroundColor(.white)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.red)
            .motionAwareTransition(.move(edge: .top).combined(with: .opacity), appSettings: appState.appSettings)
        }
    }
}

struct PersistentNetworkStatusIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            NetworkStatusIndicator()
                .motionAwareAnimation(.easeInOut(duration: 0.3), value: appState.networkMonitor.isConnected, appSettings: appState.appSettings)
            
            Spacer()
        }
    }
}

struct NetworkStatusBar: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        if !appState.networkMonitor.isConnected {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                
                Text("Offline")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(appState.networkMonitor.connectionType.displayName)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color.systemGray6)
        }
    }
}

// MARK: - View Modifier

struct WithNetworkStatus: ViewModifier {
    func body(content: Content) -> some View {
        ZStack(alignment: .top) {
            content
            PersistentNetworkStatusIndicator()
        }
    }
}

extension View {
    func withNetworkStatus() -> some View {
        modifier(WithNetworkStatus())
    }
}
