import AppIntents

@available(iOS 18.0, *)
struct OpenTimelineIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Timeline"
  static var description = IntentDescription("Open Catbird to your Bluesky timeline.")
  static let openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    if let appState = AppStateManager.shared.lifecycle.appState,
      let nav = appState.navigationManager as? AppNavigationManager
    {
      nav.tabSelection?(0)
      nav.clearPath(for: 0)
    }
    return .result()
  }
}
