//
//  CircleFeedItemRow.swift
//  Catbird
//

import SwiftUI
import Petrel
import PetrelCatbird

/// One Circle feed row: a plaintext post, an opened encrypted post, the state
/// of an encrypted post that is not readable yet (Review Focus 5), or, for a
/// post variant this build does not know (an encrypted post reaching a client
/// without encryption support), an update prompt.
struct CircleFeedItemRow: View {
  let item: BlueCatbirdCircleDefs.FeedItem
  let opened: CircleOpenedItem?
  let ownerHandle: String?
  @Binding var path: NavigationPath
  let appState: AppState

  var body: some View {
    if let row = PostView.circleRow(item: item, opened: opened, path: $path, appState: appState) {
      row
    } else {
      CircleEncryptedStatusRow(state: Self.statusState(item: item, opened: opened), ownerHandle: ownerHandle)
    }
  }

  /// The placeholder for a row that is not a renderable post.
  static func statusState(
    item: BlueCatbirdCircleDefs.FeedItem, opened: CircleOpenedItem?
  ) -> CircleEncryptedStatusRow.State {
    if case .unexpected = item.post { return .updateRequired }
    switch opened {
    case .pendingKey?: return .waitingForKey
    case .unverifiable?: return .unverifiable
    case .postedBeforeJoined?: return .postedBeforeJoined
    case .unavailable?: return .unavailable
    case .retryLater?: return .waiting
    case .post?, nil: return .opening
    }
  }

  /// Identity that changes when the row's content or counts change.
  static func identity(item: BlueCatbirdCircleDefs.FeedItem, opened: CircleOpenedItem?) -> String {
    let uri = item.post.postURI?.uriString() ?? "unknown"
    guard let post = item.post.feedViewPost?.post ?? opened?.feedViewPost?.post else {
      let state: String
      switch opened {
      case .pendingKey(_, let version)?: state = "pending-\(version)"
      case .unverifiable?: state = "unverifiable"
      case .postedBeforeJoined?: state = "before-joined"
      case .unavailable?: state = "unavailable"
      case .retryLater?: state = "retry"
      default: state = item.post.postURI == nil ? "update" : "opening"
      }
      return "\(uri)-\(state)"
    }
    return "\(uri)-\(post.replyCount ?? 0)-\(post.likeCount ?? 0)-\(post.viewer?.like != nil)"
  }
}

/// Placeholder for an encrypted Circle post that cannot be shown yet.
struct CircleEncryptedStatusRow: View {
  enum State: Equatable, Sendable {
    case opening
    /// The MLS client (and so the opener) is not up yet (I11).
    case waiting
    case waitingForKey
    case unverifiable
    /// Sealed before this member's access began (I12).
    case postedBeforeJoined
    /// A post variant this build cannot read.
    case updateRequired
    /// This device's key store could not be read right now (I3).
    case unavailable
  }

  /// Title and detail for `state` (shared by feed rows and thread placeholders).
  static func copy(for state: State, ownerHandle: String?) -> (title: String, detail: String) {
    switch state {
    case .opening:
      return ("Encrypted post", "Opening…")
    case .waiting:
      return ("Encrypted post", "Waiting…")
    case .postedBeforeJoined:
      return ("Encrypted post", "Posted before you joined")
    case .waitingForKey:
      if let ownerHandle {
        return ("Encrypted post", "Waiting for @\(ownerHandle) to refresh your access.")
      }
      return ("Encrypted post", "Waiting for the Circle owner to refresh your access.")
    case .unverifiable:
      return ("Encrypted post", "Couldn’t verify this post’s author")
    case .updateRequired:
      return ("Encrypted post", "Update Catbird to view this post")
    case .unavailable:
      return ("Encrypted post", "Unavailable on this device right now")
    }
  }

  static func iconName(for state: State) -> String {
    switch state {
    case .opening, .waiting: return "lock"
    case .postedBeforeJoined: return "clock.badge.xmark"
    case .waitingForKey: return "lock.badge.clock"
    case .unverifiable: return "lock.trianglebadge.exclamationmark"
    case .updateRequired: return "arrow.down.app"
    case .unavailable: return "lock.slash"
    }
  }

  let state: State
  let ownerHandle: String?

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: iconName)
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(detail)
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if state == .opening || state == .waiting {
        ProgressView()
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .accessibilityElement(children: .combine)
  }

  private var iconName: String { Self.iconName(for: state) }
  private var title: String { Self.copy(for: state, ownerHandle: ownerHandle).title }
  private var detail: String { Self.copy(for: state, ownerHandle: ownerHandle).detail }
}
