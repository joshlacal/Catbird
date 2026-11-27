import Nuke
import NukeUI
import Petrel
import SwiftUI

/// A circular account avatar, moderated by the signed-in account's policy.
/// Source-compatible wrapper delegating to the Kit's `CatbirdAvatar`.
///
/// Pass the account's DID and labels (account and profile-record labels) when
/// the model has them. An avatar the moderation engine blurs renders a neutral
/// placeholder and is never downloaded.
struct AsyncProfileImage: View {
  let url: URL?
  let size: CGFloat
  let did: String?
  let labels: [ComAtprotoLabelDefs.Label]?

  init(url: URL?, size: CGFloat, did: String? = nil, labels: [ComAtprotoLabelDefs.Label]? = nil) {
    self.url = url
    self.size = size
    self.did = did
    self.labels = labels
  }

  // MARK: - Source

  /// What the avatar shows.
  typealias Source = CatbirdAvatar.Source

  /// Decide what to show before anything is requested, so a concealed avatar
  /// never builds a request or probes the image cache.
  static func source(
    url: URL?,
    sizeInPoints: CGFloat,
    displayScale: CGFloat,
    did: String?,
    labels: [ComAtprotoLabelDefs.Label]?,
    policy: ModerationPolicy
  ) -> Source {
    CatbirdAvatar.source(
      url: url,
      sizeInPoints: sizeInPoints,
      displayScale: displayScale,
      did: did,
      labels: labels,
      policy: policy
    )
  }

  /// Resize the supplied avatar to the target pixel dimensions for the display
  /// the view is rendering on.
  static func resizedRequest(for url: URL?, sizeInPoints: CGFloat, displayScale: CGFloat) -> ImageRequest? {
    CatbirdAvatar.resizedRequest(for: url, sizeInPoints: sizeInPoints, displayScale: displayScale)
  }

  // MARK: - Body

  var body: some View {
    CatbirdAvatar(
      url: url,
      size: size,
      shape: .circle,
      did: did,
      labels: labels
    )
  }
}

#Preview {
  AsyncPreviewContent { _ in
    VStack(spacing: Space.xl) {
      AsyncProfileImage(url: URL(string: "https://example.com/missing.jpg"), size: AvatarSize.md)
      AsyncProfileImage(url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"), size: AvatarSize.xl)
      AsyncProfileImage(url: nil, size: AvatarSize.xxl)
    }
    .padding(Space.screenMargin)
  }
}
