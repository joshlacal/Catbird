import Foundation

/// What a DM shared-post card is built from: the post's URI, nothing else.
///
/// An MLS payload also carries the post's author handle and text, but the sender supplies them and the
/// viewer's labelers have not seen them, so they never reach the card. Until the record is confirmed
/// under the labeler scope now in effect, every shared post shows the same neutral placeholder: no
/// author, text or media.
struct ChatSharedPostCard: Equatable, Sendable {
  struct Placeholder: Equatable, Sendable {
    let title: String
    let detail: String
    let accessibilityLabel: String
  }

  /// The card's look before its record is confirmed, the same for Bluesky DM and MLS posts.
  static let placeholder = Placeholder(title: "Shared Post", detail: "Shared post", accessibilityLabel: "Shared post")

  let uri: String

  var placeholder: Placeholder { Self.placeholder }

  /// nil for embeds that are not shared posts.
  init?(embed: UnifiedEmbed) {
    switch embed {
    case .blueskyRecord(let record):
      uri = record.uri
    case .post(let post):
      uri = post.uri
    case .link, .gif, .tile, .image, .audio, .groupInvite, .groupInvitation:
      return nil
    }
  }
}
