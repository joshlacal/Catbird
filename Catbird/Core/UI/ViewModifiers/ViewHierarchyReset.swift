import SwiftUI

// A powerful view modifier to force view transitions and hierarchy resets
struct ViewHierarchyReset: ViewModifier {
    @State private var viewID = UUID()
    @Binding var trigger: Bool
    
    init(trigger: Binding<Bool>) {
        self._trigger = trigger
    }
    
    func body(content: Content) -> some View {
        content
            .id(viewID)
            .onChange(of: trigger) { _, newValue in
                if newValue {
                    // Force a complete view hierarchy reload by generating a new ID
                    viewID = UUID()
                    
                    // Reset the trigger back to false after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        trigger = false
                    }
                }
            }
    }
}

extension View {
    func forceReset(when trigger: Binding<Bool>) -> some View {
        modifier(ViewHierarchyReset(trigger: trigger))
    }
}
