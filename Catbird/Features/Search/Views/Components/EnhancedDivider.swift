import SwiftUI

/// A customized divider for search results
struct EnhancedDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 56)
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    VStack {
        Text("Item 1")
            .padding()
        EnhancedDivider()
        Text("Item 2")
            .padding()
    }
}
