//
//  ThreadBlockedItemsTests.swift
//  CatbirdTests
//
//  Verifies the thread reply-grouping pipeline keeps blocked / not-found items
//  as tombstone wrappers in place, with their subtrees intact, instead of
//  silently dropping them.
//

import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Thread blocked items")
struct ThreadBlockedItemsTests {
  private let opDID = "did:plc:opauthor"
  private let blockedDID = "did:plc:blockedauthor"

  // MARK: Fixtures

  private func makeProfile(did: String) throws -> AppBskyActorDefs.ProfileViewBasic {
    AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did),
      handle: try Handle(handleString: "user.bsky.social"),
      displayName: "User",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
  }

  private func makePostView(did: String, rkey: String) throws -> AppBskyFeedDefs.PostView {
    let record = AppBskyFeedPost(
      text: "Post \(rkey)",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_000))
    )
    return AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkey)"),
      cid: CID.fromDAGCBOR(Data("post-\(rkey)".utf8)),
      author: try makeProfile(did: did),
      record: .knownType(record),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_749_000_100)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

  private func postItem(
    did: String, rkey: String, depth: Int, opThread: Bool = false, moreReplies: Int = 0
  ) throws -> AppBskyUnspeccedGetPostThreadV2.ThreadItem {
    let post = try makePostView(did: did, rkey: rkey)
    let threadItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
      post: post,
      moreParents: false,
      moreReplies: moreReplies,
      opThread: opThread,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    return AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: post.uri,
      depth: depth,
      value: .appBskyUnspeccedDefsThreadItemPost(threadItemPost)
    )
  }

  private func blockedItem(
    did: String, rkey: String, depth: Int
  ) throws -> AppBskyUnspeccedGetPostThreadV2.ThreadItem {
    let uri = try ATProtocolURI(uriString: "at://\(did)/app.bsky.feed.post/\(rkey)")
    let blocked = AppBskyUnspeccedDefs.ThreadItemBlocked(
      author: AppBskyFeedDefs.BlockedAuthor(did: try DID(didString: did), viewer: nil)
    )
    return AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: uri,
      depth: depth,
      value: .appBskyUnspeccedDefsThreadItemBlocked(blocked)
    )
  }

  // MARK: Tests

  @Test("A blocked depth-1 reply is preserved as a tombstone with its subtree intact")
  func blockedChainRootKeepsSubtree() throws {
    let mainPost = try makePostView(did: opDID, rkey: "main")
    let blocked = try blockedItem(did: blockedDID, rkey: "blocked1", depth: 1)
    let child = try postItem(did: opDID, rkey: "child1", depth: 2)

    let result = buildReplyWrappers(items: [blocked, child], mainPost: mainPost)

    // The blocked reply must remain as the single top-level chain root.
    #expect(result.topLevel.count == 1)
    let root = try #require(result.topLevel.first)
    #expect(root.id == blocked.uri.uriString())
    // It is a tombstone: no resolvable post, neutral flags.
    #expect(root.post == nil)
    #expect(root.isFromOP == false)
    #expect(root.isOpThread == false)

    // The depth-2 child lands under the blocked root, not dropped.
    let nested = try #require(result.nested[blocked.uri.uriString()])
    #expect(nested.count == 1)
    let nestedChild = try #require(nested.first)
    #expect(nestedChild.id == child.uri.uriString())
    #expect(nestedChild.post != nil)
  }

  @Test("A blocked chain root still produces non-empty nested render input")
  func blockedRootYieldsNestedRenderInput() throws {
    // Closest testable seam to the SwiftUI render layer: `ReplyView` feeds the
    // blocked root's nested wrappers through `ThreadReplyLayoutBuilder` to
    // decide what to draw. If that input is non-empty, the shared
    // `nestedRepliesSection` (invoked from every root arm) renders the subtree.
    let mainPost = try makePostView(did: opDID, rkey: "main")
    let blocked = try blockedItem(did: blockedDID, rkey: "blocked1", depth: 1)
    let child = try postItem(did: opDID, rkey: "child1", depth: 2)

    let result = buildReplyWrappers(items: [blocked, child], mainPost: mainPost)
    let rootID = blocked.uri.uriString()
    let nested = try #require(result.nested[rootID])

    // Mirror ReplyView.nestedLayout's input computation exactly.
    let layout = ThreadReplyLayoutBuilder.build(
      rootID: rootID,
      nestedItems: nested.map {
        ThreadReplyLayoutInput(id: $0.id, parentID: $0.parentURI, hasUnloadedReplies: $0.hasReplies)
      },
      visibleLimit: ThreadReplyPresentationMetrics.maximumDepth(isEnabled: true) - 1
    )

    #expect(!layout.items.isEmpty)
    #expect(layout.items.contains(where: { $0.id == child.uri.uriString() }))
  }

  @Test("A pure-post thread groups identically with no tombstones (zero-diff behavior)")
  func purePostThreadUnchanged() throws {
    let mainPost = try makePostView(did: opDID, rkey: "main")
    let top = try postItem(did: opDID, rkey: "top", depth: 1, opThread: true)
    let child = try postItem(did: "did:plc:replier", rkey: "child", depth: 2)

    let result = buildReplyWrappers(items: [top, child], mainPost: mainPost)

    #expect(result.topLevel.count == 1)
    let root = try #require(result.topLevel.first)
    #expect(root.id == top.uri.uriString())
    #expect(root.post != nil)
    #expect(root.isFromOP == true)
    #expect(root.isOpThread == true)

    let nested = try #require(result.nested[top.uri.uriString()])
    #expect(nested.map(\.id) == [child.uri.uriString()])
  }

  @Test("A blocked leaf reply is preserved as its own top-level tombstone")
  func blockedLeafPreserved() throws {
    let mainPost = try makePostView(did: opDID, rkey: "main")
    let post1 = try postItem(did: opDID, rkey: "p1", depth: 1)
    let blockedLeaf = try blockedItem(did: blockedDID, rkey: "b1", depth: 1)

    let result = buildReplyWrappers(items: [post1, blockedLeaf], mainPost: mainPost)

    #expect(result.topLevel.map(\.id) == [post1.uri.uriString(), blockedLeaf.uri.uriString()])
    let blockedWrapper = try #require(result.topLevel.last)
    #expect(blockedWrapper.post == nil)
    #expect(result.nested[blockedLeaf.uri.uriString()]?.isEmpty == true)
  }

  // MARK: Blocked anchor detection

  @Test("A blocked depth-0 anchor is detected as a typed result (not an error)")
  func detectsBlockedAnchor() throws {
    let blockedAnchor = try blockedItem(did: blockedDID, rkey: "anchor", depth: 0)
    let reply = try postItem(did: opDID, rkey: "reply1", depth: 1)

    let detected = ThreadManager.detectBlockedAnchor(in: [blockedAnchor, reply])

    let blocked = try #require(detected)
    #expect(blocked.author.did.didString() == blockedDID)
  }

  @Test("A normal (post) anchor yields no blocked-anchor result")
  func normalAnchorHasNoBlockedAnchor() throws {
    let anchor = try postItem(did: opDID, rkey: "main", depth: 0)
    let reply = try postItem(did: opDID, rkey: "reply1", depth: 1)

    #expect(ThreadManager.detectBlockedAnchor(in: [anchor, reply]) == nil)
  }

  @Test("A blocked reply (depth > 0) is not mistaken for a blocked anchor")
  func blockedReplyIsNotAnchor() throws {
    let anchor = try postItem(did: opDID, rkey: "main", depth: 0)
    let blockedReply = try blockedItem(did: blockedDID, rkey: "b1", depth: 1)

    #expect(ThreadManager.detectBlockedAnchor(in: [anchor, blockedReply]) == nil)
  }
}
