import Nuke
import NukeUI
import Petrel
import SwiftUI

/// A circular account avatar, moderated by the signed-in account's policy.
///
/// Pass the account's DID and labels (account and profile-record labels) when
/// the model has them. An avatar the moderation engine blurs renders a neutral
/// placeholder and is never downloaded.
struct AsyncProfileImage: View {
  let url: URL?
  let size: CGFloat
  let did: String?
  let labels: [ComAtprotoLabelDefs.Label]?

  @Environment(\.moderationPolicy) private var moderationPolicy
  @Environment(\.displayScale) private var displayScale

  init(url: URL?, size: CGFloat, did: String? = nil, labels: [ComAtprotoLabelDefs.Label]? = nil) {
    self.url = url
    self.size = size
    self.did = did
    self.labels = labels
  }

  // MARK: - Source

  /// What the avatar shows.
  enum Source {
    /// The moderation policy blurs this avatar: placeholder only, no load.
    case concealed
    /// Load (or paint from the memory cache) this resized request.
    case image(ImageRequest)
    /// No avatar URL: the plain person placeholder.
    case placeholder
  }

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
    if policy.concealsAvatar(did: did, labels: labels) { return .concealed }
    guard let request = resizedRequest(for: url, sizeInPoints: sizeInPoints, displayScale: displayScale) else {
      return .placeholder
    }
    return .image(request)
  }

  // Resize the supplied avatar to the target pixel dimensions for the display
  // the view is rendering on.
  static func resizedRequest(for url: URL?, sizeInPoints: CGFloat, displayScale: CGFloat) -> ImageRequest? {
    guard let url = url else { return nil }
    let pixelDimension = max(1, (sizeInPoints * displayScale).rounded(.toNearestOrAwayFromZero))
    let pixelSize = CGSize(width: pixelDimension, height: pixelDimension)
    let processors: [any ImageProcessing] = [
      ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
    ]
    return ImageRequest(url: url, processors: processors, priority: .high)
  }

  // MARK: - Body

  var body: some View {
    let source = Self.source(
      url: url, sizeInPoints: size, displayScale: displayScale, did: did, labels: labels,
      policy: moderationPolicy)

    Group {
      switch source {
      case .concealed:
        concealedPlaceholder
      case .image(let request):
        avatarImage(request)
      case .placeholder:
        placeholder
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }

  @ViewBuilder
  private func avatarImage(_ request: ImageRequest) -> some View {
    // Synchronous memory-cache probe: if the resized avatar is already in the
    // in-memory cache, paint it directly so the first frame is the final image
    // (no placeholder-to-fade transition for cache hits).
    if let cached = ImageLoadingManager.shared.pipeline.cache[request]?.image {
      Image(platformImage: cached)
        .resizable()
        .aspectRatio(contentMode: .fill)
    } else {
      LazyImage(request: request) { state in
        if let image = state.image {
          image
            .resizable()
            .aspectRatio(contentMode: .fill)
            .transition(.opacity.animation(.easeOut(duration: 0.18)))
        } else {
          placeholder
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)
      .priority(.high)
    }
  }

  /// Shown in place of an avatar the moderation policy blurs.
  private var concealedPlaceholder: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .overlay {
        Image(systemName: "eye.slash.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundColor(.secondary.opacity(0.5))
          .frame(width: size * 0.5, height: size * 0.5)
      }
  }

  private var placeholder: some View {
    Circle()
      .fill(Color.gray.opacity(0.2))
      .overlay {
        Image(systemName: "person.crop.circle.fill")
          .resizable()
          .aspectRatio(contentMode: .fill)
          .foregroundColor(.accentColor.opacity(0.5))
          .padding(size * 0.08)
      }
  }
}

#Preview {
  AsyncPreviewContent { _ in
    VStack(spacing: 20) {
      AsyncProfileImage(url: URL(string: "https://example.com/missing.jpg"), size: 40)
      AsyncProfileImage(url: URL(string: "https://avatars.githubusercontent.com/u/1?v=4"), size: 60)
      AsyncProfileImage(url: nil, size: 80)
    }
    .padding()
  }
}
