//
//  OpenEntityIntents.swift
//  Catbird
//
//  Open intents for the entities Catbird indexes in Spotlight. When someone taps
//  an indexed post or profile in Spotlight, the system runs the matching intent,
//  which opens Catbird to that post or profile.
//

import AppIntents
import Petrel

@available(iOS 18.0, *)
struct OpenPostIntent: OpenIntent {
  static var title: LocalizedStringResource = "Open Post"
  static var description = IntentDescription("Open a Bluesky post in Catbird.")

  @Parameter(title: "Post")
  var target: PostEntity

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let accountDID = AppStateManager.shared.lifecycle.userDID else {
      throw IntentError.notSignedIn
    }
    let uri = try ATProtocolURI(uriString: target.id)
    let coordinator = SceneRouteCoordinator.shared
    coordinator.submit(SceneRouteRequest(accountDID: accountDID,
      command: .navigate(.post(uri), tabIndex: 0),
      preferredSceneID: coordinator.preferredSceneIDForExternalEvent()))
    return .result()
  }
}

@available(iOS 18.0, *)
struct OpenProfileIntent: OpenIntent {
  static var title: LocalizedStringResource = "Open Profile"
  static var description = IntentDescription("Open a Bluesky profile in Catbird.")

  @Parameter(title: "Profile")
  var target: ProfileEntity

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let accountDID = AppStateManager.shared.lifecycle.userDID else {
      throw IntentError.notSignedIn
    }
    let coordinator = SceneRouteCoordinator.shared
    coordinator.submit(SceneRouteRequest(accountDID: accountDID,
      command: .navigate(.profile(target.id), tabIndex: 0),
      preferredSceneID: coordinator.preferredSceneIDForExternalEvent()))
    return .result()
  }
}
