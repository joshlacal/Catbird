import SwiftUI

/// A customized divider for search results
struct EnhancedDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 56)
    }
}

#Preview {
    VStack {
        Text("Item 1")
            .padding()
        EnhancedDivider()
        Text("Item 2")
            .padding()
    }
}
