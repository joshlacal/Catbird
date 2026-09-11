//
//  ThreadReplyLayout.swift
//  Catbird
//

import CoreGraphics

enum ThreadReplyPresentationMetrics {
  static func maximumDepth(isEnabled: Bool) -> Int {
    isEnabled ? 5 : 3
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

    switch depth {
    case ...1: return 0
    case 2: return 12
    default: return 24
    }
  }
}

struct ThreadReplyLayoutInput: Equatable, Sendable {
  let id: String
  let parentID: String?
  let hasUnloadedReplies: Bool
  let depth: Int

  init(id: String, parentID: String?, hasUnloadedReplies: Bool, depth: Int = 2) {
    self.id = id
    self.parentID = parentID
    self.hasUnloadedReplies = hasUnloadedReplies
    self.depth = depth
  }
}

struct ThreadReplyLayoutItem: Identifiable, Equatable, Sendable {
  let id: String
  let connectsToNext: Bool
  let hasAdditionalReplies: Bool
}

struct ThreadReplyLayout: Equatable, Sendable {
  let connectsRootToFirst: Bool
  let rootHasAdditionalReplies: Bool
  let items: [ThreadReplyLayoutItem]
}

enum ThreadReplyLayoutBuilder {
  static func build(
    rootID: String,
    nestedItems: [ThreadReplyLayoutInput],
    maximumDepth: Int,
    rootHasUnloadedReplies: Bool = false
  ) -> ThreadReplyLayout {
    // V2 is depth-first; tombstones have no record containing their parent URI.
    // Recover those edges from depth while retaining explicit record parents.
    var ancestors: [Int: String] = [1: rootID]
    var parentIDs: [String: String] = [:]
    for item in nestedItems {
      if let parent = item.parentID ?? ancestors[item.depth - 1] {
        parentIDs[item.id] = parent
      }
      ancestors = ancestors.filter { $0.key < item.depth }
      ancestors[item.depth] = item.id
    }
    // Depth limits apply to each branch, never to the total number of replies.
    let visible = nestedItems.filter { $0.depth <= maximumDepth }
    let omitted = nestedItems.filter { $0.depth > maximumDepth }
    let parentsWithOmittedChildren = Set(omitted.compactMap { parentIDs[$0.id] })
    let items = visible.enumerated().map { index, item in
      let next = visible.indices.contains(index + 1) ? visible[index + 1] : nil

      return ThreadReplyLayoutItem(
        id: item.id,
        connectsToNext: next.map { parentIDs[$0.id] == item.id } ?? false,
        hasAdditionalReplies: item.hasUnloadedReplies
          || parentsWithOmittedChildren.contains(item.id)
      )
    }

    return ThreadReplyLayout(
      connectsRootToFirst: visible.first.map { parentIDs[$0.id] == rootID } ?? false,
      rootHasAdditionalReplies: rootHasUnloadedReplies || parentsWithOmittedChildren.contains(rootID),
      items: items
    )
  }
}
