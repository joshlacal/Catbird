import Foundation
import Petrel

/// Direction and source(s) of a block relationship between the viewer and another account.
/// Direction is *what happened*; sources describe how the viewer's own side was
/// established (direct record, list, or both) and are independent of direction.
struct BlockRelationship: Equatable, Sendable {
  enum Direction: Equatable, Sendable {
    case youBlocked
    case blockedYou
    case mutual
    case unknown
  }

  struct ListRef: Equatable, Sendable {
    let uri: ATProtocolURI
    let name: String
    /// URI of the viewer's app.bsky.graph.listblock record, when known.
    let listblockRecordUri: ATProtocolURI?
  }

  enum Source: Equatable, Sendable {
    case direct(recordUri: ATProtocolURI)
    case list(ListRef)
  }

  let direction: Direction
  let sources: [Source]

  init(blocking: ATProtocolURI?, blockedBy: Bool?, blockingByList: ListRef?) {
    let youBlocked = blocking != nil || blockingByList != nil
    let blockedYou = blockedBy == true
    switch (youBlocked, blockedYou) {
    case (true, true): direction = .mutual
    case (true, false): direction = .youBlocked
    case (false, true): direction = .blockedYou
    case (false, false): direction = .unknown
    }
    var sources: [Source] = []
    if let blocking { sources.append(.direct(recordUri: blocking)) }
    if let blockingByList { sources.append(.list(blockingByList)) }
    self.sources = sources
  }

  init(viewer: AppBskyActorDefs.ViewerState?) {
    let listRef = viewer?.blockingByList.map { list in
      ListRef(uri: list.uri, name: list.name, listblockRecordUri: list.viewer?.blocked)
    }
    self.init(blocking: viewer?.blocking, blockedBy: viewer?.blockedBy, blockingByList: listRef)
  }

  var directBlockUri: ATProtocolURI? {
    for case .direct(let uri) in sources { return uri }
    return nil
  }

  var listRef: ListRef? {
    for case .list(let ref) in sources { return ref }
    return nil
  }

  /// The viewer may reveal the hidden post only when their own block is the
  /// (or a) reason it is hidden. For `.blockedYou` the server withholds content.
  var canReveal: Bool { direction == .youBlocked || direction == .mutual }

  /// Unblock is offered whenever the viewer has a direct block record.
  var canUnblockDirectly: Bool { directBlockUri != nil }

  /// Complete direction+source sentence. Text carries the full meaning
  /// (never rely on tint/icon alone).
  var statusText: String {
    switch direction {
    case .blockedYou:
      return "This account blocked you"
    case .mutual:
      if let listRef {
        return "You and this account have blocked each other. Your block comes from \(listRef.name)."
      }
      return "You and this account have blocked each other"
    case .youBlocked:
      switch (directBlockUri != nil, listRef) {
      case (true, .some(let ref)):
        return "You blocked this account directly and through \(ref.name)"
      case (false, .some(let ref)):
        return "You blocked this account through \(ref.name)"
      default:
        return "You blocked this account"
      }
    case .unknown:
      return "Post blocked"
    }
  }
}

extension BlockRelationship {
  init(blockedPost: AppBskyFeedDefs.BlockedPost) { self.init(viewer: blockedPost.author.viewer) }
  init(threadItemBlocked: AppBskyUnspeccedDefs.ThreadItemBlocked) { self.init(viewer: threadItemBlocked.author.viewer) }
  init(viewBlocked: AppBskyEmbedRecord.ViewBlocked) { self.init(viewer: viewBlocked.author.viewer) }
}
