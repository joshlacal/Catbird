import SwiftUI

struct NetworkStatusIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        if !appState.networkMonitor.isConnected {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.white)
                    .font(.system(size: 14, weight: .medium))
                
                Text("No Internet Connection")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.red)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct PersistentNetworkStatusIndicator: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            NetworkStatusIndicator()
                .animation(.easeInOut(duration: 0.3), value: appState.networkMonitor.isConnected)
            
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
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text(appState.networkMonitor.connectionType.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .background(Color(.systemGray6))
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