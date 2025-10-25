import Foundation

@available(iOS 26.0, macOS 26.0, *)
extension AppState {
  /// Shared ModelActor for serialized SwiftData writes
  nonisolated var appModelStore: AppModelStore? {
    get { _appModelStoreStorage }
    set { _appModelStoreStorage = newValue }
  }
}

@available(iOS 26.0, macOS 26.0, *)
fileprivate var _appModelStoreStorage: AppModelStore?
