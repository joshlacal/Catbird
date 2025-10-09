import SwiftUI

#if targetEnvironment(macCatalyst)
extension View {
    /// Apply plain button style for Mac Catalyst to remove gray borders
    func catalystPlainButtons() -> some View {
        self.buttonStyle(.plain)
    }
}
#else
extension View {
    func catalystPlainButtons() -> some View { self }
}
#endif
