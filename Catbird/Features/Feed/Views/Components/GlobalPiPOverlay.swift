import SwiftUI

struct GlobalPiPOverlay: View {
    @Environment(AppState.self) private var appState
    @State private var pipManager = PiPManager.shared
    
    var body: some View {
        ZStack {
            if pipManager.isPiPActive {
                Color.clear
                    .overlay(
                        Text("PiP Video Playing")
                            .padding()
                            .background(Color.black.opacity(0.8))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .position(
                                x: pipManager.pipFrame.midX,
                                y: pipManager.pipFrame.midY
                            )
                            .zIndex(1000)
                    )
                    .allowsHitTesting(true)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: pipManager.isPiPActive)
            }
        }
    }
}

// MARK: - PiP Control Extensions

extension View {
    func withPiPSupport() -> some View {
        self.overlay(GlobalPiPOverlay())
    }
}