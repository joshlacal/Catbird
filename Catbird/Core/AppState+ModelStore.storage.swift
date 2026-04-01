import Foundation

@available(iOS 26.0, macOS 26.0, *)
extension AppState {
  /// Shared ModelActor for serialized SwiftData writes
  nonisolated var appModelStore: AppModelStore? {
    get { _appModelStoreInstance as? AppModelStore }
    set { _appModelStoreInstance = newValue }
  }
}
