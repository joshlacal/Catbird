//
//  ThreadReplyLayout.swift
//  Catbird
//

import CoreGraphics
import SwiftUI

/// Geometry shared by avatar placement and thread-connector drawing.
///
/// The avatar column (`AuthorAvatarColumn`), the main-post column and the
/// connector overlay in `ReplyView` all read these values, so a connector can
/// never drift away from the avatar it is supposed to run through.
enum ThreadReplyGeometry {
  /// Stroke width of every thread connector.
  static let lineWidth: CGFloat = 2

  /// Gap between an avatar's edge and the end of a connector.
  static let connectorGap: CGFloat = 3

  /// Corner radius where a vertical connector turns into a child avatar.
  static let elbowRadius: CGFloat = 8

  /// Leading offset added per nesting level in nested (threaded) mode.
  static let indentStep: CGFloat = DesignTokens.Spacing.xl

  /// Deepest level that still receives an indent; deeper levels reuse the last.
  static let maximumIndentDepth = 5

  /// Height reserved above an avatar so a connector can continue upward.
  static let connectorTopInset: CGFloat = DesignTokens.Spacing.xs

  /// Colour of every thread connector.
  static let connectorColor = Color.systemGray4

  /// Horizontal centre of an avatar inside its column.
  static func avatarCenterX(for scale: PostAvatarScale) -> CGFloat {
    scale.containerWidth / 2
  }

  /// Leading inset that corresponds to `depth` in nested mode (depth 1 = flush).
  static func indentation(forDepth depth: Int) -> CGFloat {
    CGFloat(min(max(depth - 1, 0), maximumIndentDepth - 1)) * indentStep
  }

  /// Appends the connector that links `parentAvatar` to `childAvatar`.
  ///
  /// - Child directly under (or overlapping) the parent's centre line: the line
  ///   drops straight from the parent avatar's bottom edge to the child
  ///   avatar's top edge.
  /// - Indented child: the line runs down the parent avatar's centre line and
  ///   elbows into the child avatar's near edge at the child's vertical centre.
  static func appendConnector(
    to path: inout Path,
    parentAvatar: CGRect,
    childAvatar: CGRect
  ) {
    let startX = parentAvatar.midX
    let startY = parentAvatar.maxY + connectorGap

    if childAvatar.minX <= startX, startX <= childAvatar.maxX {
      path.move(to: CGPoint(x: startX, y: startY))
      path.addLine(to: CGPoint(x: startX, y: childAvatar.minY - connectorGap))
      return
    }

    let edgeX = startX < childAvatar.minX ? childAvatar.minX : childAvatar.maxX
    let elbowY = childAvatar.midY
    path.move(to: CGPoint(x: startX, y: startY))
    path.addLine(to: CGPoint(x: startX, y: elbowY - elbowRadius))
    path.addQuadCurve(
      to: CGPoint(x: edgeX, y: elbowY),
      control: CGPoint(x: startX, y: elbowY)
    )
  }
}

/// Presentation metrics that depend on the selected thread layout mode.
enum ThreadReplyPresentationMetrics {
  /// Maximum reply depth rendered inline before the chain is deferred to a
  /// "continue thread" row. Flat (chain) mode shows the focused post's single
  /// best continuation chain; nested mode shows the whole tree.
  static func maximumDepth(isEnabled: Bool) -> Int {
    isEnabled ? ThreadReplyGeometry.maximumIndentDepth : 3
  }

  static func avatarScale(forDepth depth: Int, isEnabled: Bool) -> PostAvatarScale {
    guard isEnabled else { return .regular }

    switch depth {
    case ...1: return .regular
    case 2: return .compact
    default: return .mini
    }
  }

  static func leadingIndent(forDepth depth: Int, isEnabled: Bool) -> CGFloat {
    guard isEnabled else { return 0 }
    return ThreadReplyGeometry.indentation(forDepth: depth)
  }
}

/// How the builder picks the replies it renders.
enum ThreadReplySelection: Equatable, Sendable {
  /// Flat mode: follow one continuation chain from the root, collapsing every
  /// other branch behind a "show more replies" row.
  case chain
  /// Nested mode: every reply within the depth limit.
  case tree
}

struct ThreadReplyLayoutInput: Equatable, Sendable {
  let id: String
  let parentID: String?
  let hasUnloadedReplies: Bool
  /// Replies the API reports but has not returned, when the count is known.
  let unloadedReplyCount: Int
  let depth: Int

  init(
    id: String,
    parentID: String?,
    hasUnloadedReplies: Bool,
    unloadedReplyCount: Int = 0,
    depth: Int = 2
  ) {
    self.id = id
    self.parentID = parentID
    self.hasUnloadedReplies = hasUnloadedReplies
    self.unloadedReplyCount = unloadedReplyCount
    self.depth = depth
  }
}

struct ThreadReplyLayoutItem: Identifiable, Equatable, Sendable {
  let id: String
  let depth: Int
  let connectsToNext: Bool
  let hasAdditionalReplies: Bool
  /// Number of hidden replies behind the continuation row, when known.
  let additionalReplyCount: Int
}

struct ThreadReplyLayout: Equatable, Sendable {
  let connectsRootToFirst: Bool
  let rootHasAdditionalReplies: Bool
  let rootAdditionalReplyCount: Int
  let items: [ThreadReplyLayoutItem]
}

enum ThreadReplyLayoutBuilder {
  static func build(
    rootID: String,
    nestedItems: [ThreadReplyLayoutInput],
    maximumDepth: Int,
    rootHasUnloadedReplies: Bool = false,
    rootUnloadedReplyCount: Int = 0,
    selection: ThreadReplySelection = .tree
  ) -> ThreadReplyLayout {
    // V2 is depth-first; tombstones have no record containing their parent URI.
    // Recover those edges from depth while retaining explicit record parents.
    let parentIDs = parentEdges(rootID: rootID, items: nestedItems)

    switch selection {
    case .tree:
      let visibleItems = nestedItems.filter { $0.depth <= maximumDepth }
      let visible = Set(visibleItems.map(\.id)).union([rootID])

      // Attribute every hidden reply to its nearest visible ancestor so each
      // row can say how many replies it collapses.
      var collapsedCounts: [String: Int] = [:]
      for item in nestedItems where !visible.contains(item.id) {
        var ancestor = parentIDs[item.id]
        while let current = ancestor, !visible.contains(current) {
          ancestor = parentIDs[current]
        }
        guard let owner = ancestor else { continue }
        collapsedCounts[owner, default: 0] += 1
      }

      let items = visibleItems.enumerated().map { index, item in
        let next = visibleItems.indices.contains(index + 1) ? visibleItems[index + 1] : nil
        let collapsed = collapsedCounts[item.id] ?? 0
        return ThreadReplyLayoutItem(
          id: item.id,
          depth: item.depth,
          connectsToNext: next.map { parentIDs[$0.id] == item.id } ?? false,
          hasAdditionalReplies: item.hasUnloadedReplies || collapsed > 0,
          additionalReplyCount: collapsed + item.unloadedReplyCount
        )
      }
      let rootCollapsed = (collapsedCounts[rootID] ?? 0) + rootUnloadedReplyCount
      return ThreadReplyLayout(
        connectsRootToFirst: visibleItems.first.map { parentIDs[$0.id] == rootID } ?? false,
        rootHasAdditionalReplies: rootHasUnloadedReplies || rootCollapsed > 0,
        rootAdditionalReplyCount: rootCollapsed,
        items: items
      )

    case .chain:
      // Follow one continuation chain: at each level take the first child in
      // API order (the API ranks replies best-first).
      var chain: [ThreadReplyLayoutInput] = []
      var current = rootID
      while chain.count < maximumDepth - 1,
        let next = nestedItems.first(where: { parentIDs[$0.id] == current }),
        next.depth <= maximumDepth {
        chain.append(next)
        current = next.id
      }

      // A continuation row mid-chain would sit under the connector, so every
      // hidden branch collapses into the single row at the end of the block.
      let items = chain.enumerated().map { index, item in
        ThreadReplyLayoutItem(
          id: item.id,
          depth: item.depth,
          connectsToNext: index < chain.count - 1,
          hasAdditionalReplies: false,
          additionalReplyCount: 0
        )
      }
      let hiddenCount = nestedItems.count - chain.count
      let unloadedCount = chain.reduce(rootUnloadedReplyCount) { $0 + $1.unloadedReplyCount }
      let hasUnloaded = rootHasUnloadedReplies || chain.contains { $0.hasUnloadedReplies }
      return ThreadReplyLayout(
        connectsRootToFirst: !chain.isEmpty,
        rootHasAdditionalReplies: hasUnloaded || hiddenCount > 0,
        rootAdditionalReplyCount: hiddenCount + unloadedCount,
        items: items
      )
    }
  }

  /// Explicit record parents, falling back to the depth stack for tombstones.
  private static func parentEdges(
    rootID: String,
    items: [ThreadReplyLayoutInput]
  ) -> [String: String] {
    var ancestors: [Int: String] = [1: rootID]
    var parentIDs: [String: String] = [:]
    for item in items {
      let depthParent = item.depth > 0 ? ancestors[item.depth - 1] : nil
      if let parent = item.parentID ?? depthParent {
        parentIDs[item.id] = parent
      }
      ancestors = ancestors.filter { $0.key < item.depth }
      ancestors[item.depth] = item.id
    }
    return parentIDs
  }
}
