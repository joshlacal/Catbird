//
//  ThreadReplyLayoutTests.swift
//  CatbirdTests
//

import AppIntents
import Petrel
import SwiftUI
import Testing
import UIKit
@testable import Catbird

@Suite("Thread reply layout")
struct ThreadReplyLayoutTests {
  // MARK: Fixtures

  private static func uri(_ name: String) -> ATProtocolURI {
    try! ATProtocolURI(uriString: "at://did:plc:thread/app.bsky.feed.post/\(name)")
  }

  private static func id(_ name: String) -> String {
    uri(name).uriString()
  }

  private func post(
    _ name: String,
    depth: Int,
    parent: String?,
    op: Bool = false,
    moreReplies: Int = 0,
    moreParents: Bool = false
  ) -> ThreadRowBuilder.Item {
    ThreadRowBuilder.Item(
      uri: Self.uri(name),
      depth: depth,
      content: .post(
        recordParentID: parent.map(Self.id),
        isOpThread: op,
        moreReplies: moreReplies,
        moreParents: moreParents
      )
    )
  }

  private func blocked(_ name: String, depth: Int) -> ThreadRowBuilder.Item {
    ThreadRowBuilder.Item(uri: Self.uri(name), depth: depth, content: .tombstone(.blocked))
  }

  private var anchor: ThreadRowBuilder.Item {
    post("anchor", depth: 0, parent: nil)
  }

  private func build(
    _ items: [ThreadRowBuilder.Item],
    other: [ThreadRowBuilder.Item] = [],
    mode: ThreadLayoutMode,
    maxIndentLevels: Int = ThreadReplyGeometry.compactMaxIndentLevels,
    prompt: Bool = false
  ) -> [ThreadRow] {
    ThreadRowBuilder.build(
      items: items,
      otherItems: other,
      mode: mode,
      maxIndentLevels: maxIndentLevels,
      showsOtherRepliesPrompt: prompt
    )
  }

  private func row(_ name: String, in rows: [ThreadRow]) throws -> ThreadRow {
    try #require(rows.first { $0.id == Self.id(name) })
  }

  // MARK: Tree

  @Test("Tree: every sibling connects to the parent rail, which ends at the last sibling")
  func treeSiblingsShareParentRail() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 2, parent: "a"),
        post("d", depth: 2, parent: "a")
      ],
      mode: .tree
    )

    let a = try row("a", in: rows)
    #expect(a.lineOut)
    #expect(!a.lineIn)
    #expect(a.startsBranch)

    for name in ["b", "c", "d"] {
      let sibling = try row(name, in: rows)
      #expect(sibling.lineIn)
      #expect(sibling.indentLevel == 1)
      #expect(sibling.parentID == Self.id("a"))
    }
    #expect(try row("b", in: rows).continuingRails == [true])
    #expect(try row("c", in: rows).continuingRails == [true])
    #expect(try row("d", in: rows).continuingRails == [false])
    #expect(try row("d", in: rows).isLastSibling)
    #expect(!(try row("b", in: rows).isLastSibling))
  }

  @Test("Tree: a parent rail runs through a child's descendants until the next sibling")
  func treeRailRunsThroughDescendants() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("b1", depth: 3, parent: "b"),
        post("b2", depth: 3, parent: "b"),
        post("c", depth: 2, parent: "a")
      ],
      mode: .tree
    )

    #expect(rows.map(\.id) == ["anchor", "a", "b", "b1", "b2", "c"].map(Self.id))
    #expect(try row("b", in: rows).lineOut)
    #expect(try row("b1", in: rows).continuingRails == [true, true])
    #expect(try row("b2", in: rows).continuingRails == [true, false])
    #expect(try row("c", in: rows).continuingRails == [false])
    #expect(try row("b2", in: rows).indentLevel == 2)
  }

  @Test("Tree: unloaded replies become a read-more row that ends the parent rail")
  func treeMoreRepliesReadMore() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor", moreReplies: 2),
        post("b", depth: 2, parent: "a")
      ],
      mode: .tree
    )

    #expect(rows.count == 4)
    #expect(try row("b", in: rows).continuingRails == [true])
    #expect(!(try row("b", in: rows).isLastSibling))
    let readMore = try #require(rows.last)
    #expect(readMore.kind == .readMore(count: 2, target: Self.uri("a")))
    #expect(readMore.indentLevel == 1)
    #expect(readMore.continuingRails == [false])
    #expect(readMore.lineIn)
    #expect(readMore.parentID == Self.id("a"))
  }

  @Test("Tree: the indent cap collapses deeper replies into one read-more row")
  func treeDepthCap() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 3, parent: "b"),
        post("d", depth: 4, parent: "c", moreReplies: 1),
        post("sibling", depth: 1, parent: "anchor")
      ],
      mode: .tree,
      maxIndentLevels: 2
    )

    #expect(rows.map(\.id) == [
      Self.id("anchor"), Self.id("a"), Self.id("b"), Self.id("c"),
      ThreadRowBuilder.readMoreID(after: Self.id("c")), Self.id("sibling")
    ])
    #expect(rows.allSatisfy { $0.kind == .readMore(count: 2, target: Self.uri("c")) || $0.indentLevel <= 2 })
    let c = try row("c", in: rows)
    #expect(c.lineOut)
    #expect(c.continuingRails == [false, false])
    let readMore = rows[4]
    #expect(readMore.kind == .readMore(count: 2, target: Self.uri("c")))
    #expect(readMore.indentLevel == 3)
    #expect(try row("sibling", in: rows).startsBranch)
  }

  @Test("Tree: tombstones keep their depth-derived subtree connected")
  func treeTombstoneSubtree() throws {
    let rows = build(
      [
        anchor,
        blocked("blocked", depth: 1),
        post("child", depth: 2, parent: "blocked"),
        blocked("missing", depth: 3)
      ],
      mode: .tree
    )

    #expect(try row("blocked", in: rows).kind == .tombstone(.blocked))
    #expect(try row("blocked", in: rows).lineOut)
    #expect(try row("child", in: rows).parentID == Self.id("blocked"))
    let missing = try row("missing", in: rows)
    #expect(missing.parentID == Self.id("child"))
    #expect(missing.indentLevel == 2)
    #expect(missing.lineIn)
  }

  // MARK: Linear

  @Test("Linear: a branch shows at most three posts, then a connected read-more row")
  func linearBranchCap() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 3, parent: "b"),
        post("d", depth: 4, parent: "c"),
        post("e", depth: 5, parent: "d", moreReplies: 4)
      ],
      mode: .linear
    )

    #expect(rows.map(\.id) == [
      Self.id("anchor"), Self.id("a"), Self.id("b"), Self.id("c"),
      ThreadRowBuilder.readMoreID(after: Self.id("c"))
    ])
    #expect(rows.allSatisfy { $0.indentLevel == 0 && $0.continuingRails.isEmpty })
    #expect(try row("a", in: rows).startsBranch)
    #expect(!(try row("a", in: rows).lineIn))
    #expect(try row("b", in: rows).lineIn && (try row("b", in: rows).lineOut))
    #expect(try row("c", in: rows).lineOut)
    let readMore = rows[4]
    // d and e are loaded but hidden; e reports four more beneath it.
    #expect(readMore.kind == .readMore(count: 6, target: Self.uri("c")))
    #expect(readMore.lineIn)
  }

  @Test("Linear: the OP's continuation is pinned first and never truncated")
  func linearOPContinuationPinned() throws {
    let rows = build(
      [
        anchor,
        post("other", depth: 1, parent: "anchor"),
        post("op1", depth: 1, parent: "anchor", op: true),
        post("op2", depth: 2, parent: "op1", op: true),
        post("op3", depth: 3, parent: "op2", op: true),
        post("op4", depth: 4, parent: "op3", op: true),
        post("reply", depth: 5, parent: "op4")
      ],
      mode: .linear
    )

    #expect(rows.map(\.id) == ["anchor", "op1", "op2", "op3", "op4", "reply", "other"].map(Self.id))
    #expect(!rows.contains { if case .readMore = $0.kind { true } else { false } })
    #expect(try row("reply", in: rows).lineIn)
    #expect(try row("other", in: rows).startsBranch)
  }

  @Test("Linear: unloaded replies on the last post become a read-more row")
  func linearUnloadedReplies() throws {
    let rows = build(
      [anchor, post("a", depth: 1, parent: "anchor", moreReplies: 3)],
      mode: .linear
    )

    #expect(try row("a", in: rows).lineOut)
    #expect(rows.last?.kind == .readMore(count: 3, target: Self.uri("a")))
  }

  @Test("Linear: hidden siblings open their parent and do not draw a line into it")
  func linearHiddenSiblingsTargetParent() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 2, parent: "a"),
        post("d", depth: 2, parent: "a")
      ],
      mode: .linear
    )

    #expect(try row("b", in: rows).lineIn)
    // c follows its sibling, not its parent, so no line enters it.
    #expect(!(try row("c", in: rows).lineIn))
    #expect(!(try row("c", in: rows).lineOut))
    let readMore = try #require(rows.last)
    #expect(readMore.kind == .readMore(count: 1, target: Self.uri("a")))
    #expect(!readMore.lineIn)
  }

  @Test("Linear: the read-more count covers only replies its target reveals")
  func linearReadMoreCountsTargetSubtree() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 3, parent: "b"),
        post("c1", depth: 4, parent: "c", moreReplies: 2),
        post("sibling", depth: 2, parent: "a", moreReplies: 5)
      ],
      mode: .linear
    )

    let readMore = try #require(rows.last)
    // c1 and its two unloaded replies; the hidden sibling of b lives outside c's thread.
    #expect(readMore.kind == .readMore(count: 3, target: Self.uri("c")))
    #expect(readMore.lineIn)
  }

  // MARK: Ancestors

  @Test("Ancestors chain into the anchor, with read-more-up above unloaded parents")
  func ancestorChain() throws {
    let rows = build(
      [
        post("p1", depth: -2, parent: nil, moreParents: true),
        post("p2", depth: -1, parent: "p1"),
        post("anchor", depth: 0, parent: "p2")
      ],
      mode: .tree
    )

    #expect(rows.map(\.kind) == [.readMoreUp, .ancestor, .ancestor, .anchor])
    #expect(rows[0].lineOut)
    #expect(rows[1].lineIn && rows[1].lineOut)
    #expect(rows[2].lineIn && rows[2].lineOut)
    #expect(rows[3].lineIn)
    #expect(rows.allSatisfy { !$0.usesTreeGeometry })
  }

  @Test("A tombstone ancestor breaks the ancestor line")
  func tombstoneAncestorBreaksLine() throws {
    let rows = build(
      [
        post("p1", depth: -2, parent: nil),
        blocked("p2", depth: -1),
        post("anchor", depth: 0, parent: "p2")
      ],
      mode: .linear
    )

    #expect(rows.map(\.kind) == [.ancestor, .tombstone(.blocked), .anchor])
    #expect(!rows[0].lineOut)
    #expect(!rows[1].lineIn && !rows[1].lineOut)
    #expect(!rows[2].lineIn)
  }

  // MARK: Other replies and optimistic inserts

  @Test("Other replies follow the main replies, or a prompt stands in for them")
  func otherReplies() throws {
    let main: [ThreadRowBuilder.Item] = [anchor, post("a", depth: 1, parent: "anchor")]

    let prompted = build(main, mode: .linear, prompt: true)
    #expect(prompted.last?.kind == .showOtherReplies)
    #expect(prompted.last?.startsBranch == true)

    let loaded = build(
      main,
      other: [post("a", depth: 1, parent: "anchor"), post("hidden", depth: 1, parent: "anchor")],
      mode: .linear,
      prompt: true
    )
    #expect(loaded.map(\.id) == ["anchor", "a", "hidden"].map(Self.id))
  }

  @Test("Optimistic replies land after their parent's loaded subtree")
  func optimisticInsertion() throws {
    let items: [ThreadRowBuilder.Item] = [
      post("p", depth: -1, parent: nil),
      post("anchor", depth: 0, parent: "p"),
      post("a", depth: 1, parent: "anchor"),
      post("b", depth: 2, parent: "a"),
      post("c", depth: 1, parent: "anchor")
    ]
    let merged = ThreadRowBuilder.inserting(
      [
        post("new", depth: 1, parent: "a"),
        post("top", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("toAncestor", depth: 1, parent: "p"),
        post("orphan", depth: 1, parent: "unknown")
      ],
      into: items
    )

    #expect(merged.map(\.id) == ["p", "anchor", "a", "b", "new", "c", "top"].map(Self.id))
    #expect(merged.first { $0.id == Self.id("new") }?.depth == 2)

    let rows = build(merged, mode: .tree)
    let new = try row("new", in: rows)
    #expect(new.parentID == Self.id("a"))
    #expect(new.isLastSibling)
    #expect(try row("b", in: rows).continuingRails == [true])
  }

  // MARK: Geometry

  @Test("Tree rails sit under 28pt avatars and elbows end short of the child avatar")
  func treeGeometry() throws {
    #expect(ThreadReplyGeometry.railX(level: 0) == 26)
    #expect(ThreadReplyGeometry.railX(level: 1) == 54)
    #expect(ThreadReplyGeometry.linearLineX == 36)
    #expect(PostAvatarScale.tree.avatarSize == 28)
    #expect(PostAvatarScale.tree.containerWidth == 34)
    #expect(PostAvatarScale.regular.avatarSize == 48)
    #expect(PostAvatarScale.regular.containerWidth == 54)

    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a"),
        post("c", depth: 3, parent: "b")
      ],
      mode: .tree
    )
    let a = ThreadRowMetrics(row: try row("a", in: rows))
    let c = ThreadRowMetrics(row: try row("c", in: rows))

    // The depth-1 avatar is centred on the rail its children hang from.
    #expect(a.markerLeading + a.markerSize / 2 == a.outgoingLineX)
    #expect(a.outgoingLineX == ThreadReplyGeometry.railX(level: 0))
    // Each level moves the avatar a full avatar width.
    #expect(c.markerLeading == CGFloat(12 + 2 * 28))
    #expect(c.contentLeading == c.markerLeading - 6)
    #expect(c.incomingLineX == ThreadReplyGeometry.railX(level: 1))
    #expect(c.incomingLineBends)
    #expect(c.markerTop == ThreadReplyGeometry.connectedTopSpacing + 3)
  }

  @Test("Linear lines run straight through the 48pt avatars")
  func linearGeometry() throws {
    let rows = build(
      [
        anchor,
        post("a", depth: 1, parent: "anchor"),
        post("b", depth: 2, parent: "a", moreReplies: 1)
      ],
      mode: .linear
    )
    let b = ThreadRowMetrics(row: try row("b", in: rows))
    #expect(b.markerSize == 48)
    #expect(b.markerLeading + b.markerSize / 2 == ThreadReplyGeometry.linearLineX)
    #expect(!b.incomingLineBends)
    #expect(b.outgoingLineStartY(rowHeight: 200) == b.markerTop + 48 + 3)

    let readMore = ThreadRowMetrics(row: try #require(rows.last))
    #expect(readMore.incomingLineBends)
    #expect(readMore.markerLeading == CGFloat(12 + 48 + 9))
  }

  @Test("Each layout mode fetches its own reply shape and rows remember their mode")
  func modeParameters() throws {
    #expect(ThreadLayoutMode.linear.fetchBranchingFactor == 1)
    #expect(ThreadLayoutMode.linear.fetchDepth == 10)
    #expect(ThreadLayoutMode.tree.fetchBranchingFactor == nil)
    #expect(ThreadLayoutMode.tree.fetchDepth == 6)
    #expect(ThreadLayoutMode(threadedReplies: true) == .tree)
    #expect(ThreadLayoutMode(threadedReplies: false) == .linear)
    #expect(ThreadReplyGeometry.maxIndentLevels(isRegularWidth: false) == 5)
    #expect(ThreadReplyGeometry.maxIndentLevels(isRegularWidth: true) == 8)

    let items = [anchor, post("a", depth: 1, parent: "anchor")]
    let linear = try row("a", in: build(items, mode: .linear))
    let tree = try row("a", in: build(items, mode: .tree))
    #expect(linear != tree)
  }

  // MARK: Prefilled anchor

  /// A post as a feed hands it to the thread, replying to `parent` when given.
  private func tappedPost(_ name: String, parent: String?) throws -> AppBskyFeedDefs.PostView {
    let reply = parent.map { parentName in
      let ref = ComAtprotoRepoStrongRef(uri: Self.uri(parentName), cid: CID.fromDAGCBOR(Data("\(parentName)-cid".utf8)))
      return AppBskyFeedPost.ReplyRef(root: ref, parent: ref)
    }
    let record = AppBskyFeedPost(
      text: name,
      entities: nil,
      facets: nil,
      reply: reply,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    return PublicPostTestFixtures.makePostView(
      uri: Self.uri(name),
      authorDID: try DID(didString: "did:plc:thread"),
      text: name,
      record: .knownType(record)
    )
  }

  @Test(
    "A prefilled anchor row equals the loaded anchor row, so the anchor keeps its cell",
    arguments: [ThreadLayoutMode.linear, .tree]
  )
  func prefilledAnchorMatchesLoadedAnchor(mode: ThreadLayoutMode) throws {
    let topLevel = try tappedPost("anchor", parent: nil)
    let loadedTopLevel = try row("anchor", in: build([anchor, post("a", depth: 1, parent: "anchor")], mode: mode))
    #expect(ThreadRowBuilder.prefilledAnchorRow(for: topLevel, mode: mode) == loadedTopLevel)
    #expect(!loadedTopLevel.lineIn)

    let reply = try tappedPost("anchor", parent: "p")
    let loadedReply = try row(
      "anchor",
      in: build([post("p", depth: -1, parent: nil), post("anchor", depth: 0, parent: "p")], mode: mode)
    )
    #expect(ThreadRowBuilder.prefilledAnchorRow(for: reply, mode: mode) == loadedReply)
    #expect(loadedReply.lineIn)
  }

  @Test("A parent that loads as a tombstone gives the anchor a different row")
  func prefilledAnchorDiffersWhenTheParentIsATombstone() throws {
    let reply = try tappedPost("anchor", parent: "p")
    let loaded = try row("anchor", in: build([blocked("p", depth: -1), post("anchor", depth: 0, parent: "p")], mode: .linear))
    #expect(ThreadRowBuilder.prefilledAnchorRow(for: reply, mode: .linear) != loaded)
  }

  /// The tapped post again as the thread returns it: same post, fresher counts.
  private func threadCopy(of post: AppBskyFeedDefs.PostView, likes: Int) -> AppBskyFeedDefs.PostView {
    AppBskyFeedDefs.PostView(
      uri: post.uri,
      cid: post.cid,
      author: post.author,
      record: post.record,
      embed: post.embed,
      bookmarkCount: post.bookmarkCount,
      replyCount: 2,
      repostCount: post.repostCount,
      likeCount: likes,
      quoteCount: post.quoteCount,
      indexedAt: post.indexedAt,
      viewer: post.viewer,
      labels: post.labels,
      threadgate: post.threadgate,
      debug: post.debug
    )
  }

  @MainActor
  @Test("The anchor cell takes the thread's copy of the post and its post number in place")
  func mainPostCellUpdatesInPlaceForANewCopyOfThePost() async throws {
    guard #available(iOS 18.0, *) else { return }
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let scene = SceneNavigationContext(appState: appState, sceneID: UUID())
    let tapped = try tappedPost("anchor", parent: nil)
    let loaded = threadCopy(of: tapped, likes: 7)

    func identity(_ post: AppBskyFeedDefs.PostView, index: Int? = nil, count: Int? = nil) -> String {
      MainPostCell.configurationIdentity(
        post: post, sceneContext: scene, opThreadPostIndex: index, opThreadPostCount: count, showsLineFromParent: false)
    }
    #expect(identity(tapped) == identity(tapped))
    #expect(identity(loaded) != identity(tapped))
    #expect(identity(tapped, index: 1, count: 3) != identity(tapped))

    let cell = MainPostCell(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
    cell.configure(post: tapped, appState: appState, sceneContext: scene, path: .constant(NavigationPath()))
    let tappedIdentity = try #require(cell.configuredIdentity)
    cell.layoutIfNeeded()
    let initialHostingView = descendants(of: cell).first { String(describing: type(of: $0)).contains("Hosting") }
    #expect(initialHostingView != nil)

    cell.configure(
      post: loaded, appState: appState, sceneContext: scene, path: .constant(NavigationPath()),
      opThreadPostIndex: 1, opThreadPostCount: 3)
    #expect(cell.configuredIdentity != tappedIdentity)
    cell.layoutIfNeeded()
    let updatedHostingView = descendants(of: cell).first { String(describing: type(of: $0)).contains("Hosting") }
    #expect(updatedHostingView === initialHostingView)
  }

  @MainActor
  @Test("The anchor view compares the whole post, so a fresher copy re-renders it")
  func anchorViewComparesTheWholePost() async throws {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let tapped = try tappedPost("anchor", parent: nil)

    func view(_ post: AppBskyFeedDefs.PostView) -> ThreadViewMainPostView {
      ThreadViewMainPostView(post: post, showLine: false, path: .constant(NavigationPath()), appState: appState)
    }
    #expect(view(tapped) == view(tapped))
    #expect(view(threadCopy(of: tapped, likes: 7)) != view(tapped))
  }

  // MARK: Cell

  @MainActor
  @Test("ThreadRowCell sets a hosting configuration and preserves it on reuse")
  func threadRowCellConfigurationAndReuse() async throws {
    guard #available(iOS 18.0, *) else { return }
    let cell = ThreadRowCell(frame: .zero)
    #expect(cell.contentConfiguration == nil)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let postView = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:testuser/app.bsky.feed.post/reply1"),
      authorDID: try DID(didString: "did:plc:testuser"),
      text: "Optimistic reply"
    )
    let threadItem = AppBskyUnspeccedGetPostThreadV2.ThreadItem(optimisticReply: postView, depth: 1)
    let replyRow = try #require(
      build([ThreadRowBuilder.Item(threadItem)], mode: .tree).first
    )

    cell.configure(
      row: replyRow,
      threadItem: threadItem,
      parentAuthor: nil,
      appState: appState,
      sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()),
      path: .constant(NavigationPath())
    )
    #expect(cell.contentConfiguration != nil)
    #expect(!(cell.contentConfiguration is UIListContentConfiguration))
    cell.layoutIfNeeded()
    let initialHostingView = descendants(of: cell).first {
      let typeName = String(describing: type(of: $0))
      return typeName.contains("Hosting")
    }
    #expect(initialHostingView != nil)

    cell.prepareForReuse()
    // P081/P036 deliberately keep the hosting configuration on reuse to update in place
    #expect(cell.contentConfiguration != nil)

    let postView2 = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:testuser/app.bsky.feed.post/reply2"),
      authorDID: try DID(didString: "did:plc:testuser"),
      text: "Second optimistic reply"
    )
    let threadItem2 = AppBskyUnspeccedGetPostThreadV2.ThreadItem(optimisticReply: postView2, depth: 1)
    let replyRow2 = try #require(
      build([ThreadRowBuilder.Item(threadItem2)], mode: .tree).first
    )

    cell.configure(
      row: replyRow2,
      threadItem: threadItem2,
      parentAuthor: nil,
      appState: appState,
      sceneContext: SceneNavigationContext(appState: appState, sceneID: UUID()),
      path: .constant(NavigationPath())
    )
    #expect(cell.contentConfiguration != nil)
    #expect(!(cell.contentConfiguration is UIListContentConfiguration))
    cell.layoutIfNeeded()
    let reusedHostingView = descendants(of: cell).first {
      let typeName = String(describing: type(of: $0))
      return typeName.contains("Hosting")
    }
    #expect(reusedHostingView === initialHostingView)
#if compiler(>=6.4)
    if #available(anyAppleOS 26.0, *) {
      let expectedURI = AppEntityAnnotationIdentifiers.postURI(replyRow2.id)
      #expect(cell.appEntityIdentifier == expectedURI.map { EntityIdentifier(for: PostEntity.self, identifier: $0) })
    }
#endif
  }

  @MainActor
  @Test("A thread row's content identity changes with the row or scene, not on a same-row reconfigure")
  func threadRowContentIdentity() async throws {
    guard #available(iOS 18.0, *) else { return }
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let scene = SceneNavigationContext(appState: appState, sceneID: UUID())
    let otherScene = SceneNavigationContext(appState: appState, sceneID: UUID())
    let rows = build([anchor, post("a", depth: 1, parent: "anchor"), post("b", depth: 1, parent: "anchor")], mode: .tree)
    let first = try row("a", in: rows)
    let second = try row("b", in: rows)

    #expect(ThreadRowCell.contentIdentity(row: first, sceneContext: scene) == ThreadRowCell.contentIdentity(row: first, sceneContext: scene))
    #expect(ThreadRowCell.contentIdentity(row: first, sceneContext: scene) != ThreadRowCell.contentIdentity(row: second, sceneContext: scene))
    #expect(ThreadRowCell.contentIdentity(row: first, sceneContext: scene) != ThreadRowCell.contentIdentity(row: first, sceneContext: otherScene))
  }

  @MainActor
  @Test("A reused ThreadRowCell lays out its new reply at once, not the reply it showed before")
  func reusedThreadRowCellLaysOutTheNewReplyAtOnce() async throws {
    guard #available(iOS 18.0, *) else { return }
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let scene = SceneNavigationContext(appState: appState, sceneID: UUID())

    func reply(_ rkey: String, _ text: String) throws -> (row: ThreadRow, item: AppBskyUnspeccedGetPostThreadV2.ThreadItem) {
      let postView = PublicPostTestFixtures.makePostView(
        uri: try ATProtocolURI(uriString: "at://did:plc:testuser/app.bsky.feed.post/\(rkey)"),
        authorDID: try DID(didString: "did:plc:testuser"),
        text: text
      )
      let item = AppBskyUnspeccedGetPostThreadV2.ThreadItem(optimisticReply: postView, depth: 1)
      return (try #require(build([ThreadRowBuilder.Item(item)], mode: .tree).first), item)
    }
    func show(_ reply: (row: ThreadRow, item: AppBskyUnspeccedGetPostThreadV2.ThreadItem), in cell: ThreadRowCell) {
      cell.configure(
        row: reply.row, threadItem: reply.item, parentAuthor: nil, appState: appState,
        sceneContext: scene, path: .constant(NavigationPath()))
    }
    // No await between configuring and measuring, so PostView's async post swap can't run first.
    func height(of cell: ThreadRowCell) -> CGFloat {
      cell.contentView.systemLayoutSizeFitting(
        CGSize(width: 390, height: 0),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      ).height
    }

    let short = try reply("reuse-short", "One line.")
    let long = try reply(
      "reuse-long",
      String(repeating: "A reply long enough to wrap across many lines of the thread. ", count: 10)
    )

    let fresh = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
    show(long, in: fresh)
    let longHeight = height(of: fresh)

    let reused = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 390, height: 100))
    show(short, in: reused)
    let shortHeight = height(of: reused)
    #expect(longHeight > shortHeight + 40, "fixture: the long reply must be much taller (\(longHeight) vs \(shortHeight))")

    reused.prepareForReuse()
    show(long, in: reused)
    let reusedHeight = height(of: reused)
    #expect(abs(reusedHeight - longHeight) < 1, "reused cell measured \(reusedHeight), fresh cell \(longHeight), previous row \(shortHeight)")
  }

  private func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }
}
