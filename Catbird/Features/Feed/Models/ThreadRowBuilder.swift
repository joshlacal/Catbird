//
//  ThreadRowBuilder.swift
//  Catbird
//

import Petrel

// MARK: - Builder

/// Turns a flat, depth-first `getPostThreadV2` response into display rows.
///
/// The traversal follows social-app's `sortAndAnnotateThreadItems`: parents
/// come from the reply record (falling back to the depth stack for
/// tombstones), OP self-thread branches are pinned first, and the rail of a
/// parent keeps running through its descendants until its last child, where
/// it ends in that child's elbow.
enum ThreadRowBuilder {
  struct Item: Equatable, Sendable {
    enum Content: Equatable, Sendable {
      case post(recordParentID: String?, isOpThread: Bool, moreReplies: Int, moreParents: Bool)
      case tombstone(ThreadRow.TombstoneReason)
    }

    let id: String
    let uri: ATProtocolURI
    let depth: Int
    let content: Content

    init(uri: ATProtocolURI, depth: Int, content: Content) {
      self.id = uri.uriString()
      self.uri = uri
      self.depth = depth
      self.content = content
    }

    var isPost: Bool {
      if case .post = content { return true }
      return false
    }

    var recordParentID: String? {
      if case .post(let parent, _, _, _) = content { return parent }
      return nil
    }

    var isOpThread: Bool {
      if case .post(_, let isOpThread, _, _) = content { return isOpThread }
      return false
    }

    var moreReplies: Int {
      if case .post(_, _, let moreReplies, _) = content { return max(0, moreReplies) }
      return 0
    }

    var moreParents: Bool {
      if case .post(_, _, _, let moreParents) = content { return moreParents }
      return false
    }

    var tombstoneReason: ThreadRow.TombstoneReason? {
      if case .tombstone(let reason) = content { return reason }
      return nil
    }
  }

  static let readMoreUpID = "thread-row|read-more-up"
  static let showOtherRepliesID = "thread-row|show-other-replies"

  static func readMoreID(after id: String) -> String {
    "thread-row|read-more|\(id)"
  }

  /// - Parameters:
  ///   - items: The thread in API order: ancestors, anchor, then replies.
  ///   - otherItems: Replies loaded on request after the main replies.
  ///   - showsOtherRepliesPrompt: Append a `.showOtherReplies` row when
  ///     `otherItems` is empty.
  static func build(
    items: [Item],
    otherItems: [Item] = [],
    mode: ThreadLayoutMode,
    maxIndentLevels: Int,
    showsOtherRepliesPrompt: Bool = false
  ) -> [ThreadRow] {
    var seen = Set<String>()
    let unique = items.filter { seen.insert($0.id).inserted }
    let uniqueOther = otherItems.filter { $0.depth > 0 && seen.insert($0.id).inserted }

    let ancestors = unique.enumerated()
      .filter { $0.element.depth < 0 }
      .sorted { ($0.element.depth, $0.offset) < ($1.element.depth, $1.offset) }
      .map(\.element)
    let anchor = unique.first { $0.depth == 0 }
    let replies = unique.filter { $0.depth > 0 }

    var rows = ancestorRows(ancestors: ancestors, anchor: anchor, mode: mode)

    let emitter = BranchEmitter(mode: mode, maxIndentLevels: max(1, maxIndentLevels))
    rows += emitter.rows(for: Forest(items: replies, anchorID: anchor?.id))

    if !uniqueOther.isEmpty {
      rows += emitter.rows(for: Forest(items: uniqueOther, anchorID: anchor?.id))
    } else if showsOtherRepliesPrompt {
      rows.append(
        ThreadRow(
          id: showOtherRepliesID,
          kind: .showOtherReplies,
          depth: 1,
          parentID: anchor?.id,
          indentLevel: 0,
          continuingRails: [],
          lineIn: false,
          lineOut: false,
          isLastSibling: true,
          startsBranch: true,
          mode: mode
        ))
    }

    return rows
  }

  /// Places optimistic replies after the last loaded descendant of their
  /// parent. Replies already present, and replies whose parent is not the
  /// anchor or a loaded reply, are left out.
  static func inserting(_ pending: [Item], into items: [Item]) -> [Item] {
    var result = items
    for reply in pending where !result.contains(where: { $0.id == reply.id }) {
      guard let parentID = reply.recordParentID,
        let parentIndex = result.firstIndex(where: { $0.id == parentID }),
        result[parentIndex].depth >= 0
      else { continue }

      let parentDepth = result[parentIndex].depth
      var insertionIndex = parentIndex + 1
      while insertionIndex < result.count, result[insertionIndex].depth > parentDepth {
        insertionIndex += 1
      }
      result.insert(
        Item(uri: reply.uri, depth: parentDepth + 1, content: reply.content),
        at: insertionIndex
      )
    }
    return result
  }

  // MARK: Ancestors

  private static func ancestorRows(
    ancestors: [Item],
    anchor: Item?,
    mode: ThreadLayoutMode
  ) -> [ThreadRow] {
    var rows: [ThreadRow] = []
    let hasReadMoreUp = ancestors.first?.moreParents ?? false

    if hasReadMoreUp, let first = ancestors.first {
      rows.append(
        ThreadRow(
          id: readMoreUpID,
          kind: .readMoreUp,
          depth: first.depth - 1,
          parentID: nil,
          indentLevel: 0,
          continuingRails: [],
          lineIn: false,
          lineOut: true,
          isLastSibling: true,
          startsBranch: false,
          mode: mode
        ))
    }

    for (index, ancestor) in ancestors.enumerated() {
      let previousIsPost = index == 0 ? hasReadMoreUp : ancestors[index - 1].isPost
      let next = index + 1 < ancestors.count ? ancestors[index + 1] : anchor
      rows.append(
        ThreadRow(
          id: ancestor.id,
          kind: ancestor.tombstoneReason.map(ThreadRow.Kind.tombstone) ?? .ancestor,
          depth: ancestor.depth,
          parentID: index > 0 ? ancestors[index - 1].id : nil,
          indentLevel: 0,
          continuingRails: [],
          lineIn: ancestor.isPost && previousIsPost,
          lineOut: ancestor.isPost && (next?.isPost ?? false),
          isLastSibling: true,
          startsBranch: false,
          mode: mode
        ))
    }

    if let anchor {
      rows.append(
        ThreadRow(
          id: anchor.id,
          kind: .anchor,
          depth: 0,
          parentID: ancestors.last?.id,
          indentLevel: 0,
          continuingRails: [],
          lineIn: anchor.isPost && (ancestors.last?.isPost ?? false),
          lineOut: false,
          isLastSibling: true,
          startsBranch: false,
          mode: mode
        ))
    }

    return rows
  }

  // MARK: Reply forest

  /// Replies arranged by parent, with API order kept among siblings.
  private struct Forest {
    struct Node {
      let item: Item
      let parent: Int?
      let depth: Int
      var children: [Int] = []
    }

    private(set) var nodes: [Node] = []
    private(set) var roots: [Int] = []

    init(items: [Item], anchorID: String?) {
      var indexByID: [String: Int] = [:]
      // stack[k] is the most recent node at tree depth k + 1.
      var stack: [Int] = []

      for item in items {
        var parent: Int?
        var isRoot = false

        if let recordParent = item.recordParentID {
          if recordParent == anchorID {
            isRoot = true
          } else if let index = indexByID[recordParent] {
            parent = index
          }
        }
        if parent == nil, !isRoot {
          // Tombstones carry no record; recover their parent from depth.
          if item.depth <= 1 || stack.isEmpty {
            isRoot = true
          } else {
            parent = stack[min(item.depth - 2, stack.count - 1)]
          }
        }

        let depth = parent.map { nodes[$0].depth + 1 } ?? 1
        let index = nodes.count
        nodes.append(Node(item: item, parent: parent, depth: depth))
        indexByID[item.id] = index
        if let parent {
          nodes[parent].children.append(index)
        } else {
          roots.append(index)
        }
        stack = Array(stack.prefix(depth - 1)) + [index]
      }

      // OP self-thread branches are pinned above everyone else's replies.
      let pinned = roots.filter { nodes[$0].item.isOpThread }
      let others = roots.filter { !nodes[$0].item.isOpThread }
      roots = pinned + others
    }

    func isLastSibling(_ index: Int) -> Bool {
      let siblings = nodes[index].parent.map { nodes[$0].children } ?? roots
      return siblings.last == index
    }

    /// The node's descendants in depth-first order.
    func descendants(of index: Int) -> [Int] {
      nodes[index].children.flatMap { [$0] + descendants(of: $0) }
    }
  }

  private struct BranchEmitter {
    let mode: ThreadLayoutMode
    let maxIndentLevels: Int

    func rows(for forest: Forest) -> [ThreadRow] {
      var rows: [ThreadRow] = []
      for root in forest.roots {
        switch mode {
        case .linear: appendLinearBranch(root, forest: forest, into: &rows)
        case .tree:
          appendTreeNode(
            root, level: 0, rails: [], isLast: forest.isLastSibling(root),
            forest: forest, into: &rows)
        }
      }
      return rows
    }

    // MARK: Tree

    private func appendTreeNode(
      _ index: Int,
      level: Int,
      rails: [Bool],
      isLast: Bool,
      forest: Forest,
      into rows: inout [ThreadRow]
    ) {
      let node = forest.nodes[index]
      let item = node.item
      let showsChildren = level + 1 <= maxIndentLevels

      let children = showsChildren ? node.children : []
      let readMoreCount: Int
      if showsChildren {
        readMoreCount = item.moreReplies
      } else {
        let hidden = forest.descendants(of: index)
        readMoreCount = hidden.count + item.moreReplies
          + hidden.reduce(0) { $0 + forest.nodes[$1].item.moreReplies }
      }
      let hasReadMore = readMoreCount > 0

      rows.append(
        ThreadRow(
          id: item.id,
          kind: item.tombstoneReason.map(ThreadRow.Kind.tombstone) ?? .reply,
          depth: level + 1,
          parentID: node.parent.map { forest.nodes[$0].item.id },
          indentLevel: level,
          continuingRails: rails,
          lineIn: level > 0,
          lineOut: !children.isEmpty || hasReadMore,
          isLastSibling: isLast,
          startsBranch: level == 0,
          mode: .tree
        ))

      for (position, child) in children.enumerated() {
        let childIsLast = position == children.count - 1 && !hasReadMore
        appendTreeNode(
          child, level: level + 1, rails: rails + [!childIsLast], isLast: childIsLast,
          forest: forest, into: &rows)
      }

      if hasReadMore {
        rows.append(
          ThreadRow(
            id: ThreadRowBuilder.readMoreID(after: item.id),
            kind: .readMore(count: readMoreCount, target: item.uri),
            depth: level + 2,
            parentID: item.id,
            indentLevel: level + 1,
            continuingRails: rails + [false],
            lineIn: true,
            lineOut: false,
            isLastSibling: true,
            startsBranch: false,
            mode: .tree
          ))
      }
    }

    // MARK: Linear

    private func appendLinearBranch(_ root: Int, forest: Forest, into rows: inout [ThreadRow]) {
      let branch = [root] + forest.descendants(of: root)

      // The OP's own continuation is never truncated; everyone else's
      // replies share the per-branch budget.
      var visible: [Int] = []
      var budget = ThreadReplyGeometry.linearBranchPostLimit
      for index in branch {
        if forest.nodes[index].item.isOpThread {
          visible.append(index)
        } else if budget > 0 {
          visible.append(index)
          budget -= 1
        } else {
          break
        }
      }
      let hidden = Array(branch.dropFirst(visible.count))

      // Read more opens the post whose thread reveals what was left out, and
      // counts only the replies that post's thread shows.
      let readMoreTarget = hidden.first.flatMap { forest.nodes[$0].parent } ?? visible.last
      let readMoreCount: Int
      if let target = readMoreTarget {
        let revealed = Set(forest.descendants(of: target))
        let hiddenUnderTarget = hidden.filter { revealed.contains($0) }
        readMoreCount = hiddenUnderTarget.count + forest.nodes[target].item.moreReplies
          + hiddenUnderTarget.reduce(0) { $0 + forest.nodes[$1].item.moreReplies }
      } else {
        readMoreCount = 0
      }
      let readMoreConnects = readMoreTarget == visible.last

      for (position, index) in visible.enumerated() {
        let node = forest.nodes[index]
        let isLastVisible = position == visible.count - 1
        let nextIsChild = !isLastVisible && forest.nodes[visible[position + 1]].parent == index
        rows.append(
          ThreadRow(
            id: node.item.id,
            kind: node.item.tombstoneReason.map(ThreadRow.Kind.tombstone) ?? .reply,
            depth: node.depth,
            parentID: node.parent.map { forest.nodes[$0].item.id },
            indentLevel: 0,
            continuingRails: [],
            lineIn: position > 0 && node.parent == visible[position - 1],
            lineOut: nextIsChild || (isLastVisible && readMoreCount > 0 && readMoreConnects),
            isLastSibling: forest.isLastSibling(index),
            startsBranch: position == 0,
            mode: .linear
          ))
      }

      if readMoreCount > 0, let target = readMoreTarget, let last = visible.last {
        let targetItem = forest.nodes[target].item
        rows.append(
          ThreadRow(
            id: ThreadRowBuilder.readMoreID(after: forest.nodes[last].item.id),
            kind: .readMore(count: readMoreCount, target: targetItem.uri),
            depth: forest.nodes[target].depth + 1,
            parentID: targetItem.id,
            indentLevel: 0,
            continuingRails: [],
            lineIn: readMoreConnects,
            lineOut: false,
            isLastSibling: true,
            startsBranch: false,
            mode: .linear
          ))
      }
    }
  }
}

// MARK: - Petrel adapters

extension ThreadRowBuilder.Item {
  init(_ threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem) {
    let content: Content
    switch threadItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
      var recordParentID: String?
      if case .knownType(let record) = itemPost.post.record,
        let feedPost = record as? AppBskyFeedPost {
        recordParentID = feedPost.reply?.parent.uri.uriString()
      }
      content = .post(
        recordParentID: recordParentID,
        isOpThread: itemPost.opThread,
        moreReplies: itemPost.moreReplies,
        moreParents: itemPost.moreParents
      )
    case .appBskyUnspeccedDefsThreadItemBlocked:
      content = .tombstone(.blocked)
    case .appBskyUnspeccedDefsThreadItemNotFound:
      content = .tombstone(.notFound)
    case .appBskyUnspeccedDefsThreadItemNoUnauthenticated:
      content = .tombstone(.noUnauthenticated)
    case .unexpected:
      content = .tombstone(.unexpected)
    }
    self.init(uri: threadItem.uri, depth: threadItem.depth, content: content)
  }
}

extension AppBskyUnspeccedGetPostThreadV2.ThreadItem {
  /// Re-expresses a `getPostThreadOtherV2` item in the main thread's item
  /// type so both lists share one rendering path.
  init(otherItem: AppBskyUnspeccedGetPostThreadOtherV2.ThreadItem) {
    let value: AppBskyUnspeccedGetPostThreadV2.ThreadItemValueUnion
    switch otherItem.value {
    case .appBskyUnspeccedDefsThreadItemPost(let itemPost):
      value = .appBskyUnspeccedDefsThreadItemPost(itemPost)
    case .unexpected(let container):
      value = .unexpected(container)
    }
    self.init(uri: otherItem.uri, depth: otherItem.depth, value: value)
  }

  /// A thread item for a reply the viewer just posted, before the AppView
  /// returns it.
  init(optimisticReply post: AppBskyFeedDefs.PostView, depth: Int) {
    self.init(
      uri: post.uri,
      depth: depth,
      value: .appBskyUnspeccedDefsThreadItemPost(
        AppBskyUnspeccedDefs.ThreadItemPost(
          post: post,
          moreParents: false,
          moreReplies: 0,
          opThread: false,
          opThreadPostIndex: nil,
          opThreadPostCount: nil,
          hiddenByThreadgate: false,
          mutedByViewer: false
        ))
    )
  }

  var post: AppBskyFeedDefs.PostView? {
    guard case .appBskyUnspeccedDefsThreadItemPost(let itemPost) = value else { return nil }
    return itemPost.post
  }
}
