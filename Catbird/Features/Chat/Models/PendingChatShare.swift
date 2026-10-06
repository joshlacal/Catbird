import Foundation
import Petrel
import Observation

/// A post staged for sharing into a Bluesky conversation. Set by the share
/// picker, consumed once by `ConversationView` when the target convo opens.
struct PendingChatShare: Identifiable {
  let id = UUID()
  let originSceneID: UUID
  let accountDID: String
  let convoId: String
  /// Strong ref sent as the `app.bsky.embed.record` message embed.
  let postRef: ComAtprotoRepoStrongRef
  /// Preview rendered in the composer's staged-post strip.
  let previewEmbed: ChatSharedPostPreview

  /// Staging changes only the attachment; typed text and reply context survive.
  func apply(to draft: inout BlueskyConversationDraft) {
    draft.attachedEmbed = previewEmbed
    draft.postRef = postRef
  }

  static func makePreviewEmbed(from post: AppBskyFeedDefs.PostView) -> ChatSharedPostPreview {
    let postText: String
    if case .knownType(let record) = post.record,
       let feedPost = record as? AppBskyFeedPost {
      postText = feedPost.text
    } else {
      postText = ""
    }

    return ChatSharedPostPreview(
      authorDisplayName: post.author.displayName,
      authorHandle: post.author.handle.description,
      text: postText
    )
  }
}

/// Scene, account and conversation ownership are explicit. A second window
/// showing the same chat cannot take the first window's pending attachment.
@MainActor
@Observable
final class PendingChatShareStore {
  static let shared = PendingChatShareStore()

  private struct Key: Hashable {
    let sceneID: UUID
    let accountDID: String
    let convoId: String
  }

  private var entries: [Key: PendingChatShare] = [:]
  private(set) var revision = 0

  func stage(_ share: PendingChatShare) {
    guard !share.accountDID.isEmpty, !share.convoId.isEmpty else { return }
    entries[Key(sceneID: share.originSceneID, accountDID: share.accountDID, convoId: share.convoId)] = share
    revision += 1
  }

  func peek(sceneID: UUID, accountDID: String, convoId: String) -> PendingChatShare? {
    entries[Key(sceneID: sceneID, accountDID: accountDID, convoId: convoId)]
  }

  @discardableResult
  func consume(sceneID: UUID, accountDID: String, convoId: String, expectedID: UUID) -> PendingChatShare? {
    let key = Key(sceneID: sceneID, accountDID: accountDID, convoId: convoId)
    guard entries[key]?.id == expectedID else { return nil }
    let share = entries.removeValue(forKey: key)
    revision += 1
    return share
  }

  /// Called when the owning context is invalidated. Other windows and accounts
  /// retain their handoffs; stale confirmations cannot claim the discarded IDs.
  func discard(sceneID: UUID, accountDID: String) {
    let remaining = entries.filter { $0.key.sceneID != sceneID || $0.key.accountDID != accountDID }
    guard remaining.count != entries.count else { return }
    entries = remaining
    revision += 1
  }

}
