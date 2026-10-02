import Foundation

extension AppState {
  /// Type-erased setter to avoid availability annotations leaking across call sites
  @MainActor
  func setModelStore(_ store: Any) {
    if #available(iOS 26.0, macOS 26.0, *) {
      if let typed = store as? AppModelStore {
        self._setModelStore_iOS26(typed)
      }
    }
  }

  @available(iOS 26.0, macOS 26.0, *)
  @MainActor
  private func _setModelStore_iOS26(_ store: AppModelStore) {
    self.appModelStore = store
  }
}
