#if os(iOS)
import Foundation
import Petrel
import UIKit

// MARK: - Native Feed Row Actions

/// What a native feed row does when the viewer interacts with it. The feed controller builds
/// one value per row it configures; the cell keeps it only until it is reused.
@MainActor
struct NativeFeedRowActions {
  /// A tap on the row outside its controls and links, or VoiceOver's "Open post" action.
  let openPost: (AppBskyFeedDefs.PostView) -> Void
  /// A tap on the avatar, with the author's DID.
  let openProfile: (String) -> Void
  /// A tap on a mention, hashtag or link run of the post's text.
  let openLink: (URL) -> Void
  /// The reply, repost, quote, like and share handlers of the post's action bar.
  let actionBar: (AppBskyFeedDefs.PostView) -> FeedActionBarActions
  /// The options menu's items, built each time the menu opens (`PostOptionsMenuBuilder`).
  let optionsMenu: (AppBskyFeedDefs.PostView) -> [UIMenuElement]
}

// MARK: - Native Feed Row Content

/// Everything a `NativeFeedPostCell` draws for one post, resolved by the feed controller.
///
/// `layout` must have been computed from a `FeedRowLayoutInput` built from these same values:
/// `text`, `displayName`, `handle`, `timeText`, and `verificationSymbol` equal to
/// `verification?.symbolName`. The cell draws them at the layout's frames without measuring.
struct NativeFeedRowContent {
  let post: AppBskyFeedDefs.PostView
  let layout: FeedRowLayout
  let text: NSAttributedString
  /// The name the header shows. The avatar's VoiceOver name comes from `post.author`, as on
  /// the hosted row.
  let displayName: String
  /// "@handle".
  let handle: String
  let timeText: String
  let timeAccessibilityLabel: String
  /// The author's badge, already resolved with the user's "hide verification badges"
  /// preference: `VerificationBadge.kind(for:did:hideBadges:)` with
  /// `hideBadges: appState.preferencesManager.hideVerificationBadges`. It is therefore `nil`
  /// whenever badges are hidden, and the layout reserves no space for a hidden badge. The cell
  /// passes `hideVerificationBadges: false` to the header because the preference is already
  /// applied here.
  let verification: VerificationBadgeKind?
  let actionBarState: FeedActionBarState
}
#endif
