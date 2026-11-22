import AppIntents

@available(iOS 18.0, *)
struct OpenTimelineIntent: AppIntent {
  static var title: LocalizedStringResource = LocalizedStringResource(
    "Open Timeline",
    comment: "App Intent title for opening Catbird's home timeline."
  )
  static var description = IntentDescription(
    LocalizedStringResource(
      "Open Catbird to your Bluesky timeline.",
      comment: "App Intent description for Open Timeline."
    )
  )
  // iOS 18–25 read openAppWhenRun; iOS 26+ reads supportedModes, which replaces it.
  static let openAppWhenRun: Bool = true

  @available(iOS 26.0, macOS 26.0, *)
  static var supportedModes: IntentModes { .foreground }

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
