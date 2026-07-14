//
//  ThreadReplyLayoutTests.swift
//  CatbirdTests
//

import Testing
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
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 2, isEnabled: true) == 12)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 3, isEnabled: true) == 24)
    #expect(ThreadReplyPresentationMetrics.leadingIndent(forDepth: 8, isEnabled: true) == 24)
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
      visibleLimit: 2
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
        .init(id: "grandchild", parentID: "child", hasUnloadedReplies: false)
      ],
      visibleLimit: 2
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
        .init(id: "omitted", parentID: "visible", hasUnloadedReplies: false)
      ],
      visibleLimit: 1
    )

    let visible = try #require(layout.items.first)
    #expect(!visible.connectsToNext)
    #expect(visible.hasAdditionalReplies)
  }
}
