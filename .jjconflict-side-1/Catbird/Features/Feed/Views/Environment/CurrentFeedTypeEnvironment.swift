import SwiftUI

private struct CurrentFeedTypeKey: EnvironmentKey {
    static let defaultValue: FetchType? = nil
}

extension EnvironmentValues {
    var currentFeedType: FetchType? {
        get { self[CurrentFeedTypeKey.self] }
        set { self[CurrentFeedTypeKey.self] = newValue }
    }
}

