//
//  ThreadReplyLayoutTests.swift
//  CatbirdTests
//

import Testing
@testable import Catbird

@Suite("Thread reply layout")
struct ThreadReplyLayoutTests {
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
