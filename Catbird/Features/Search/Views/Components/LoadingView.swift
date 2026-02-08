import SwiftUI

/// A view that displays a loading indicator with an optional message
struct LoadingWithMessageView: View {
    let message: String
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()
            
            Text(message)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    LoadingWithMessageView(message: "Loading content...")
}
