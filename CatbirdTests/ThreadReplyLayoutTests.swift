//
//  ThreadReplyLayoutTests.swift
//  CatbirdTests
//

import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird
@Suite("Thread reply layout")
struct ThreadReplyLayoutTests {
  @Test("Threaded replies progressively reduce avatar size and cap indentation")
  func threadedReplyPresentationMetrics() {
    #expect(ThreadReplyPresentationMetrics.maximumDepth(isEnabled: false) == 3)
    #expect(ThreadReplyPresentationMetrics.maximumDepth(isEnabled: true) == 5)

    #expect(ThreadReplyPresentationMetrics.avatarScale(forDepth: 1, isEnabled: true) == .regular)
    #expect(ThreadReplyPresentationMetrics.avatarScale(forDepth: 2, isEnabled: true) == .compact)
    #expect(ThreadReplyPresentationMetrics.avatarScale(forDepth: 3, isEnabled: true) == .mini)
    #expect(ThreadReplyPresentationMetrics.avatarScale(forDepth: 8, isEnabled: false) == .regular)

    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 1, isEnabled: true) == 0)
    // Indentation visibly increases per level up to the depth ceiling.
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 2, isEnabled: true) == 18)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 3, isEnabled: true) == 36)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 4, isEnabled: true) == 54)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 5, isEnabled: true) == 72)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 8, isEnabled: true) == 72)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 8, isEnabled: false) == 0)
  }

  @Test("Post avatar scales preserve the regular layout and compact depth cues")
  func postAvatarScaleMetrics() {
    #expect(PostAvatarScale.regular.avatarSize == 48)
    #expect(PostAvatarScale.compact.avatarSize == 32)
    #expect(PostAvatarScale.mini.avatarSize == 24)
    #expect(PostAvatarScale.regular.containerWidth == 54)
    #expect(PostAvatarScale.compact.containerWidth == 38)
    #expect(PostAvatarScale.mini.containerWidth == 30)
  }

  @Test("Sibling replies do not connect to each other")
  func siblingRepliesDoNotConnect() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "natalie",
      nestedItems: [
        .init(id: "gee", parentID: "natalie", hasUnloadedReplies: false),
        .init(id: "josh", parentID: "natalie", hasUnloadedReplies: false)
      ],
      maximumDepth: 3
    )

    #expect(layout.connectsRootToFirst)
    #expect(layout.items.map(\.id) == ["gee", "josh"])
    #expect(layout.items.map(\.connectsToNext) == [false, false])
  }

  @Test("A direct child keeps the thread connector")
  func directChildKeepsThreadConnector() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [
        .init(id: "child", parentID: "root", hasUnloadedReplies: false),
        .init(id: "grandchild", parentID: "child", hasUnloadedReplies: false, depth: 3)
      ],
      maximumDepth: 3
    )

    #expect(layout.connectsRootToFirst)
    #expect(layout.items.map(\.connectsToNext) == [true, false])
  }

  @Test("An omitted child keeps the continuation affordance")
  func omittedChildKeepsContinuationAffordance() throws {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [
        .init(id: "visible", parentID: "root", hasUnloadedReplies: false),
        .init(id: "omitted", parentID: "visible", hasUnloadedReplies: false, depth: 3)
      ],
      maximumDepth: 2
    )

    let visible = try #require(layout.items.first)
    #expect(!visible.connectsToNext)
    #expect(visible.hasAdditionalReplies)
  }

  @Test("Depth limits preserve siblings after a collapsed deep branch")
  func depthLimitPreservesSiblingBranches() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [
        .init(id: "a", parentID: "root", hasUnloadedReplies: false, depth: 2),
        .init(id: "b", parentID: "a", hasUnloadedReplies: false, depth: 3),
        .init(id: "deep", parentID: "b", hasUnloadedReplies: false, depth: 4),
        .init(id: "siblingOfB", parentID: "a", hasUnloadedReplies: false, depth: 3),
        .init(id: "siblingOfA", parentID: "root", hasUnloadedReplies: false, depth: 2)
      ],
      maximumDepth: 3
    )
    #expect(layout.items.map(\.id) == ["a", "b", "siblingOfB", "siblingOfA"])
    #expect(layout.items.map(\.connectsToNext) == [true, false, false, false])
    #expect(layout.items.map(\.hasAdditionalReplies) == [false, true, false, false])
  }

  @Test("Tombstones retain their depth-derived parent and continuation")
  func tombstoneContinuation() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [
        .init(id: "blocked", parentID: nil, hasUnloadedReplies: false, depth: 2),
        .init(id: "missing", parentID: nil, hasUnloadedReplies: false, depth: 3)
      ],
      maximumDepth: 2,
      rootHasUnloadedReplies: true
    )
    #expect(layout.connectsRootToFirst)
    #expect(layout.rootHasAdditionalReplies)
    #expect(layout.items.first?.hasAdditionalReplies == true)
  }

  @Test("Collapsing every child retains a root continuation")
  func rootContinuation() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [.init(id: "child", parentID: "root", hasUnloadedReplies: false)],
      maximumDepth: 1
    )
    #expect(layout.items.isEmpty)
    #expect(layout.rootHasAdditionalReplies)
  }

  @MainActor
  @Test("ReplyCell updates contentConfiguration on reconfiguration and resets on prepareForReuse")
  func replyCellReconfigurationAndReuse() async throws {
    guard #available(iOS 18.0, *) else { return }
    let cell = ReplyCell(frame: .zero)
    #expect(cell.contentConfiguration == nil)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)

    let postView = CircleTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:testuser/app.bsky.feed.post/reply1"),
      authorDID: try DID(didString: "did:plc:testuser"),
      text: "Optimistic reply"
    )
    let threadItem = AppBskyUnspeccedDefs.ThreadItemPost(
      post: postView,
      moreParents: false,
      moreReplies: 0,
      opThread: false,
      opThreadPostIndex: nil,
      opThreadPostCount: nil,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    let replyWrapper = ReplyWrapper(
      id: postView.uri.uriString(),
      threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: postView.uri,
        depth: 1,
        value: .appBskyUnspeccedDefsThreadItemPost(threadItem)
      ),
      depth: 1,
      isFromOP: false,
      isOpThread: false,
      hasReplies: false
    )

    let binding = Binding.constant(NavigationPath())

    cell.configure(
      replyWrapper: replyWrapper,
      nestedReplies: [],
      opAuthorID: "did:plc:opauthor",
      appState: appState,
      path: binding
    )

    #expect(cell.contentConfiguration != nil)

    let sentinel = UIListContentConfiguration.cell()
    cell.contentConfiguration = sentinel
    // Reconfigure with updated/confirmed data
    let confirmedPostView = CircleTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:testuser/app.bsky.feed.post/reply1"),
      authorDID: try DID(didString: "did:plc:testuser"),
      text: "Confirmed reply"
    )
    let confirmedThreadItem = AppBskyUnspeccedDefs.ThreadItemPost(
      post: confirmedPostView,
      moreParents: false,
      moreReplies: 0,
      opThread: false,
      opThreadPostIndex: nil,
      opThreadPostCount: nil,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    let confirmedWrapper = ReplyWrapper(
      id: confirmedPostView.uri.uriString(),
      threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: confirmedPostView.uri,
        depth: 1,
        value: .appBskyUnspeccedDefsThreadItemPost(confirmedThreadItem)
      ),
      depth: 1,
      isFromOP: false,
      isOpThread: false,
      hasReplies: false
    )

    cell.configure(
      replyWrapper: confirmedWrapper,
      nestedReplies: [],
      opAuthorID: "did:plc:opauthor",
      appState: appState,
      path: binding
    )

    #expect(cell.contentConfiguration != nil)
    #expect(!(cell.contentConfiguration is UIListContentConfiguration))
    // Verify prepareForReuse clears configuration
    cell.prepareForReuse()
    #expect(cell.contentConfiguration == nil)
  }
  @Test("Flat mode follows one continuation chain and collapses other branches into the root count")
  func flatModeFollowsContinuationChain() {
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: "root",
      nestedItems: [
        .init(id: "a", parentID: "root", hasUnloadedReplies: false, depth: 2),
        .init(id: "b", parentID: "a", hasUnloadedReplies: false, depth: 3),
        .init(id: "deep", parentID: "b", hasUnloadedReplies: false, depth: 4),
        .init(id: "siblingOfB", parentID: "a", hasUnloadedReplies: false, depth: 3),
        .init(id: "siblingOfA", parentID: "root", hasUnloadedReplies: false, depth: 2)
      ],
      maximumDepth: 3,
      selection: .chain
    )

    // Flat mode shows root -> a -> b (max depth 3 = root + 2 items)
    #expect(layout.items.map(\.id) == ["a", "b"])
    #expect(layout.connectsRootToFirst)
    #expect(layout.items.map(\.connectsToNext) == [true, false])
    // Sibling branches plus the depth-4 item collapse into the root count (5 total - 2 shown = 3)
    #expect(layout.rootHasAdditionalReplies)
    #expect(layout.rootAdditionalReplyCount == 3)
  }

  @Test("Shared geometry aligns the connector with the avatar centre")
  func sharedGeometryAlignment() {
    let scale = PostAvatarScale.regular
    let centerX = ThreadReplyGeometry.avatarCenterX(for: scale)
    // Container is avatarSize + 6, avatar is centered -> center is containerWidth / 2.
    #expect(centerX == scale.containerWidth / 2)
    #expect(centerX == 27)
  }
}
