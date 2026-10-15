#if os(iOS)
import Foundation
import Petrel
import Testing
import UIKit
@testable import Catbird

/// The options menu built outside `PostView`, as native rows build it: from a context the
/// caller owns rather than from a SwiftUI view's state.
@MainActor
@Suite("Post options menu builder")
struct PostOptionsMenuBuilderTests {
  private func sectionTitles(viewer: String, feedInteractionTarget: FeedInteractionTarget?) async throws -> [[String]] {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: viewer, client: client)
    let post = try FeedRowTestPosts.cachedPost().feedViewPost.post
    let context = PostOptionsMenuContext(
      postState: PostState(postBox: EquatableBox(post), currentUserDid: viewer),
      contextMenuViewModel: PostContextMenuViewModel(appState: appState, post: post),
      viewModel: PostViewModel(post: post, appState: appState),
      appState: appState, feedInteractionTarget: feedInteractionTarget, visibilityContext: .public)
    return PostOptionsMenuBuilder.elements(post: post, context: context).map { section in
      (section as? UIMenu)?.children.map(\.title) ?? []
    }
  }

  private var copilotSections: [[String]] {
    CopilotAvailability.isAvailable ? [["Ask Catbird"]] : []
  }

  @Test("Another author's post offers list, feedback and moderation actions")
  func otherAuthorsPost() async throws {
    let target = FeedInteractionTarget(
      feedURI: "at://did:plc:generator/app.bsky.feed.generator/fixture", generatorDID: "did:plc:generator")
    let sections = try await sectionTitles(viewer: "did:plc:viewer", feedInteractionTarget: target)
    #expect(sections == copilotSections + [
      ["Add Author to List"],
      ["Bookmark"],
      ["Show More Like This", "Show Less Like This"],
      ["Mute User", "Block User", "Mute Thread", "Hide Post", "Report Post"]
    ])
  }

  @Test("The viewer's own post offers pinning, interaction settings, labels and deletion")
  func ownPost() async throws {
    let sections = try await sectionTitles(viewer: "did:plc:fixture", feedInteractionTarget: nil)
    #expect(sections == copilotSections + [
      ["Bookmark"],
      ["Mute Thread", "Pin to Profile", "Edit Interaction Settings", "View Labels", "Delete Post"]
    ])
  }
}
#endif
