import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Unified Profile Content Rendering")
@MainActor
struct UnifiedProfileContentRenderTests {
  @Test("Loaded profile content lays out without runtime metadata recursion")
  func loadedProfileContentLaysOut() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:profile-render-test", client: client)
    let viewModel = ProfileViewModel(
      client: client,
      userDID: appState.userDID,
      currentUserDID: appState.userDID
    )
    let profile = try AppBskyActorDefs.ProfileViewDetailed(
      did: DID(didString: appState.userDID),
      handle: Handle(handleString: "profile-render.test"),
      displayName: "Profile Render",
      description: nil,
      pronouns: nil,
      website: nil,
      avatar: nil,
      banner: nil,
      followersCount: 0,
      followsCount: 0,
      postsCount: 0,
      associated: nil,
      joinedViaStarterPack: nil,
      indexedAt: nil,
      createdAt: nil,
      viewer: nil,
      labels: nil,
      pinnedPost: nil,
      verification: nil,
      status: nil,
      debug: nil
    )

    let content = UnifiedProfileContentView(
      profile: profile,
      viewModel: viewModel,
      appState: appState,
      contentMaxWidth: 402,
      hasAttemptedLoadPosts: false,
      hasAttemptedLoadReplies: false,
      hasAttemptedLoadMedia: false,
      isEditingProfile: .constant(false),
      navigationPath: .constant(NavigationPath()),
      refreshAllContent: {},
      onTabChange: { _ in },
      prepareBlockConfirmation: {}
    )
    let controller = UIHostingController(rootView: content.environment(appState))
    controller.loadViewIfNeeded()
    controller.view.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
    controller.view.layoutIfNeeded()

    #expect(controller.view.bounds.size == CGSize(width: 402, height: 874))
  }
}
