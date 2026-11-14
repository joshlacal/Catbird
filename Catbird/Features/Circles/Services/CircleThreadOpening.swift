import Foundation
import Petrel
import PetrelCatbird

/// A thread node standing in for an encrypted post that cannot be shown: its
/// state and, when waiting for a key, the owner's handle. It carries no author
/// and no text, so post actions (copy, translate, like, reply) never apply.
struct CircleThreadPlaceholder: Equatable, Sendable {
  let state: CircleEncryptedStatusRow.State
  let ownerHandle: String?
}

/// Opens the encrypted nodes of a Circle thread (`getPostThread` returns them
/// as ordinary `PostView`s whose record is a `blue.catbird.circle.post`)
/// through the account's shared `CirclePostOpener`, so threads and feeds use
/// one opener, one concurrency bound and one memo.
///
/// An opened node becomes its decrypted post. A node that stays pending a key
/// or is unverifiable becomes a placeholder node (the union's `.unexpected`
/// arm carrying `placeholderType`), rendered as `CircleEncryptedStatusRow`, so
/// the thread keeps its shape; nothing here is persisted.
enum CircleThreadOpening {
  /// Local-only marker; never sent or stored.
  static let placeholderType = "blue.catbird.circle.local#threadPlaceholder"
  /// Per-process secret every placeholder carries. Petrel decodes an unknown
  /// wire `$type` into the same `.unknownType` shape, so the type name alone
  /// is forgeable; a server cannot know this value.
  private static let processToken = UUID().uuidString

  static func open(
    _ items: [AppBskyUnspeccedGetPostThreadV2.ThreadItem],
    circle: CircleSummary,
    opener: CirclePostOpener?,
    ownerHandle: @Sendable () async -> String?
  ) async -> [AppBskyUnspeccedGetPostThreadV2.ThreadItem] {
    let items = items.map(untrustingWireMarker)
    let encrypted = items.compactMap { item -> AppBskyFeedDefs.PostView? in
      guard case .appBskyUnspeccedDefsThreadItemPost(let node) = item.value,
            CirclePostOpener.circlePostRecord(node.post.record) != nil else { return nil }
      return node.post
    }
    guard !encrypted.isEmpty else { return items }

    var results: [ATProtocolURI: CircleOpenedItem] = [:]
    if let opener {
      results = await opener.openBatch(encrypted.map { .threadNode($0, circle: circle) })
    }
    let handle = results.values.contains(where: \.isPendingKey) ? await ownerHandle() : nil

    return items.map { item in
      guard case .appBskyUnspeccedDefsThreadItemPost(let node) = item.value,
            CirclePostOpener.circlePostRecord(node.post.record) != nil else { return item }
      let value: AppBskyUnspeccedGetPostThreadV2.ThreadItemValueUnion
      switch results[node.post.uri] {
      case .post(let feedViewPost, _)?:
        value = .appBskyUnspeccedDefsThreadItemPost(AppBskyUnspeccedDefs.ThreadItemPost(
          post: feedViewPost.post,
          moreParents: node.moreParents,
          moreReplies: node.moreReplies,
          opThread: node.opThread,
          opThreadPostIndex: node.opThreadPostIndex,
          opThreadPostCount: node.opThreadPostCount,
          hiddenByThreadgate: node.hiddenByThreadgate,
          mutedByViewer: node.mutedByViewer
        ))
      case .pendingKey?:
        value = placeholderValue(CircleThreadPlaceholder(state: .waitingForKey, ownerHandle: handle))
      case .postedBeforeJoined?:
        value = placeholderValue(CircleThreadPlaceholder(state: .postedBeforeJoined, ownerHandle: nil))
      case .unavailable?:
        value = placeholderValue(CircleThreadPlaceholder(state: .unavailable, ownerHandle: nil))
      case .retryLater?:
        // I3: transient (offline, directory); opened again on the next load.
        value = placeholderValue(CircleThreadPlaceholder(state: .waiting, ownerHandle: nil))
      case nil where opener == nil:
        // I11: the MLS client is not up yet; this is not a verification failure.
        value = placeholderValue(CircleThreadPlaceholder(state: .waiting, ownerHandle: nil))
      case .unverifiable?, nil:
        value = placeholderValue(CircleThreadPlaceholder(state: .unverifiable, ownerHandle: nil))
      }
      return AppBskyUnspeccedGetPostThreadV2.ThreadItem(uri: item.uri, depth: item.depth, value: value)
    }
  }

  /// A wire item claiming the local marker type is not a placeholder: it
  /// becomes a plain unexpected item before anything else looks at it.
  static func untrustingWireMarker(
    _ item: AppBskyUnspeccedGetPostThreadV2.ThreadItem
  ) -> AppBskyUnspeccedGetPostThreadV2.ThreadItem {
    guard case .unexpected(.unknownType(let type, _)) = item.value, type == placeholderType else { return item }
    return AppBskyUnspeccedGetPostThreadV2.ThreadItem(
      uri: item.uri, depth: item.depth, value: .unexpected(.decodeError("untrusted placeholder marker"))
    )
  }

  static func placeholderValue(_ placeholder: CircleThreadPlaceholder) -> AppBskyUnspeccedGetPostThreadV2.ThreadItemValueUnion {
    var fields: [String: ATProtocolValueContainer] = [
      "state": .string(stateName(placeholder.state)),
      "token": .string(processToken)
    ]
    if let ownerHandle = placeholder.ownerHandle { fields["ownerHandle"] = .string(ownerHandle) }
    return .unexpected(.unknownType(placeholderType, .object(fields)))
  }

  /// The placeholder a thread item stands for, or nil for any other item.
  static func placeholder(in value: AppBskyUnspeccedGetPostThreadV2.ThreadItemValueUnion) -> CircleThreadPlaceholder? {
    guard case .unexpected(.unknownType(let type, .object(let fields))) = value, type == placeholderType,
          fields["token"] == .string(processToken),
          case .string(let name)? = fields["state"], let state = state(named: name) else { return nil }
    var handle: String?
    if case .string(let value)? = fields["ownerHandle"] { handle = value }
    return CircleThreadPlaceholder(state: state, ownerHandle: handle)
  }

  private static func stateName(_ state: CircleEncryptedStatusRow.State) -> String {
    switch state {
    case .opening: return "opening"
    case .waiting: return "waiting"
    case .postedBeforeJoined: return "postedBeforeJoined"
    case .waitingForKey: return "waitingForKey"
    case .unverifiable: return "unverifiable"
    case .updateRequired: return "updateRequired"
    case .unavailable: return "unavailable"
    }
  }

  private static func state(named name: String) -> CircleEncryptedStatusRow.State? {
    switch name {
    case "opening": return .opening
    case "waiting": return .waiting
    case "postedBeforeJoined": return .postedBeforeJoined
    case "waitingForKey": return .waitingForKey
    case "unverifiable": return .unverifiable
    case "updateRequired": return .updateRequired
    case "unavailable": return .unavailable
    default: return nil
    }
  }
}
