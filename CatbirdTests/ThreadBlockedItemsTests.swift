//
//  ThreadBlockedItemsTests.swift
//  CatbirdTests
//
//  Verifies the thread row pipeline keeps blocked / not-found items as
//  tombstone rows in place, with their subtrees intact, instead of silently
//  dropping them.
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
      opThreadPostIndex: nil,
      opThreadPostCount: nil,
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

  private func rows(
    _ items: [AppBskyUnspeccedGetPostThreadV2.ThreadItem],
    mode: ThreadLayoutMode
  ) -> [ThreadRow] {
    ThreadRowBuilder.build(
      items: items.map(ThreadRowBuilder.Item.init),
      mode: mode,
      maxIndentLevels: ThreadReplyGeometry.compactMaxIndentLevels
    )
  }

  // MARK: Tests

  @Test("A blocked depth-1 reply is a tombstone row whose subtree stays connected", arguments: [
    ThreadLayoutMode.linear, .tree
  ])
  func blockedChainRootKeepsSubtree(mode: ThreadLayoutMode) throws {
    let anchor = try postItem(did: opDID, rkey: "main", depth: 0)
    let blocked = try blockedItem(did: blockedDID, rkey: "blocked1", depth: 1)
    let child = try postItem(did: opDID, rkey: "child1", depth: 2)

    let result = rows([anchor, blocked, child], mode: mode)

    #expect(result.map(\.id) == [anchor, blocked, child].map { $0.uri.uriString() })
    let blockedRow = result[1]
    #expect(blockedRow.kind == .tombstone(.blocked))
    #expect(blockedRow.startsBranch)
    #expect(blockedRow.lineOut)

    // The child has no record parent to read (fixtures carry no reply ref),
    // so its parent is recovered from depth.
    let childRow = result[2]
    #expect(childRow.kind == .reply)
    #expect(childRow.parentID == blocked.uri.uriString())
    #expect(childRow.lineIn)
  }

  @Test("A pure-post thread pins the OP continuation and links its child")
  func purePostThread() throws {
    let anchor = try postItem(did: opDID, rkey: "main", depth: 0)
    let other = try postItem(did: "did:plc:replier", rkey: "other", depth: 1)
    let top = try postItem(did: opDID, rkey: "top", depth: 1, opThread: true)
    let child = try postItem(did: "did:plc:replier", rkey: "child", depth: 2)

    let result = rows([anchor, other, top, child], mode: .linear)

    #expect(result.map(\.id) == [anchor, top, child, other].map { $0.uri.uriString() })
    #expect(result.allSatisfy { $0.kind != .tombstone(.blocked) })
    #expect(result[2].lineIn)
    #expect(result[1].lineOut)
    #expect(result[3].startsBranch)
    #expect(!result[3].lineIn)
  }

  @Test("A blocked leaf reply is its own unconnected branch")
  func blockedLeafPreserved() throws {
    let anchor = try postItem(did: opDID, rkey: "main", depth: 0)
    let post1 = try postItem(did: opDID, rkey: "p1", depth: 1)
    let blockedLeaf = try blockedItem(did: blockedDID, rkey: "b1", depth: 1)

    let result = rows([anchor, post1, blockedLeaf], mode: .tree)

    #expect(result.map(\.id) == [anchor, post1, blockedLeaf].map { $0.uri.uriString() })
    let blockedRow = try #require(result.last)
    #expect(blockedRow.kind == .tombstone(.blocked))
    #expect(blockedRow.startsBranch)
    #expect(!blockedRow.lineIn && !blockedRow.lineOut)
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
