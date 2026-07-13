//
//  ThreadReplyLayout.swift
//  Catbird
//

struct ThreadReplyLayoutInput: Equatable, Sendable {
  let id: String
  let parentID: String?
  let hasUnloadedReplies: Bool
}

struct ThreadReplyLayoutItem: Identifiable, Equatable, Sendable {
  let id: String
  let connectsToNext: Bool
  let hasAdditionalReplies: Bool
}

struct ThreadReplyLayout: Equatable, Sendable {
  let connectsRootToFirst: Bool
  let items: [ThreadReplyLayoutItem]
}

enum ThreadReplyLayoutBuilder {
  static func build(
    rootID: String,
    nestedItems: [ThreadReplyLayoutInput],
    visibleLimit: Int
  ) -> ThreadReplyLayout {
    let visible = Array(nestedItems.prefix(max(0, visibleLimit)))
    let omitted = nestedItems.dropFirst(visible.count)
    let items = visible.enumerated().map { index, item in
      let next = visible.indices.contains(index + 1) ? visible[index + 1] : nil

      return ThreadReplyLayoutItem(
        id: item.id,
        connectsToNext: next?.parentID == item.id,
        hasAdditionalReplies: item.hasUnloadedReplies
          || omitted.contains(where: { $0.parentID == item.id })
      )
    }

    return ThreadReplyLayout(
      connectsRootToFirst: visible.first?.parentID == rootID,
      items: items
    )
  }
}
