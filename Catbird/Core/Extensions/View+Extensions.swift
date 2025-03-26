import SwiftUI

extension View {
    func globalBackgroundColor(_ color: Color) -> some View {
        self.background(color.edgesIgnoringSafeArea(.all))
    }
}

extension Color {
    static let primaryBackground = Color(uiColor: UIColor.systemBackground)
    static let secondaryBackground = Color(uiColor: UIColor.secondarySystemBackground)
}
