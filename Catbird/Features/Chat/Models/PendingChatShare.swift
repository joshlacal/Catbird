import Foundation
import Petrel
import Observation

/// A post staged for sharing into a Bluesky conversation. Set by the share
/// picker, consumed once by `ConversationView` when the target convo opens.
struct PendingChatShare: Identifiable {
  let id = UUID()
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

/// Account and conversation ownership are explicit even when a view survives an
/// account switch. Entries are taken once, and replacing one account's entry
/// never discards another account's pending attachment.
@MainActor
@Observable
final class PendingChatShareStore {
  static let shared = PendingChatShareStore()

  private struct Key: Hashable {
    let accountDID: String
    let convoId: String
  }

  private var entries: [Key: PendingChatShare] = [:]
  private(set) var revision = 0

  func stage(_ share: PendingChatShare) {
    guard !share.accountDID.isEmpty, !share.convoId.isEmpty else { return }
    entries[Key(accountDID: share.accountDID, convoId: share.convoId)] = share
    revision += 1
  }

  func peek(accountDID: String, convoId: String) -> PendingChatShare? {
    entries[Key(accountDID: accountDID, convoId: convoId)]
  }

  @discardableResult
  func consume(accountDID: String, convoId: String, expectedID: UUID) -> PendingChatShare? {
    let key = Key(accountDID: accountDID, convoId: convoId)
    guard entries[key]?.id == expectedID else { return nil }
    let share = entries.removeValue(forKey: key)
    revision += 1
    return share
  }
}
