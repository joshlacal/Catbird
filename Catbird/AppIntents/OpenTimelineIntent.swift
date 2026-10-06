import AppIntents

@available(iOS 18.0, *)
struct OpenTimelineIntent: AppIntent {
  static var title: LocalizedStringResource = "Open Timeline"
  static var description = IntentDescription("Open Catbird to your Bluesky timeline.")
  static let openAppWhenRun: Bool = true

  @MainActor
  func perform() async throws -> some IntentResult {
    let coordinator = SceneRouteCoordinator.shared
    let preferredSceneID = coordinator.preferredSceneIDForExternalEvent()
    if let accountDID = AppStateManager.shared.lifecycle.userDID {
      coordinator.submit(SceneRouteRequest(accountDID: accountDID,
        command: .showTab(0, resetPath: true), preferredSceneID: preferredSceneID))
    }
    return .result()
  }
}
