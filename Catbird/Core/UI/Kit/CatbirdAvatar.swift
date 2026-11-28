//
//  CatbirdAvatar.swift
//  Catbird
//
//  Unified avatar primitive aligned with docs/brand/08-components/avatar.md.
//  Supports circular and continuous-squircle shapes, AvatarSize tokens, moderation
//  concealment before any network fetch, synchronous Nuke memory-cache hits, and
//  deterministic initial-on-accent fallbacks.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI

/// Visual clipping shape for `CatbirdAvatar`.
enum CatbirdAvatarShape: Equatable, Sendable {
  /// Standard circular user avatar (post rows, messages, comments, notifications).
  case circle
  /// Continuous squircle avatar (profile cards, group headers, featured surfaces).
  case squircle(Radius = .md)
}

struct CatbirdAvatar: View {
  let url: URL?
  let displayName: String?
  let handle: String?
  let size: CGFloat
  let shape: CatbirdAvatarShape
  let did: String?
  let labels: [ComAtprotoLabelDefs.Label]?

  @Environment(\.moderationPolicy) private var moderationPolicy
  @Environment(\.displayScale) private var displayScale
  @Environment(\.catbirdTheme) private var theme

  init(
    url: URL?,
    displayName: String? = nil,
    handle: String? = nil,
    size: CGFloat = AvatarSize.md,
    shape: CatbirdAvatarShape = .circle,
    did: String? = nil,
    labels: [ComAtprotoLabelDefs.Label]? = nil
  ) {
    self.url = url
    self.displayName = displayName
    self.handle = handle
    self.size = size
    self.shape = shape
    self.did = did
    self.labels = labels
  }

  // MARK: - Source Resolution

  enum Source {
    /// Moderation policy conceals this avatar: neutral placeholder, zero requests.
    case concealed
    /// Load (or synchronously paint from cache) this resized Nuke request.
    case image(ImageRequest)
    /// No URL supplied: render deterministic initial or person fallback.
    case placeholder
  }

  static func source(
    url: URL?,
    sizeInPoints: CGFloat,
    displayScale: CGFloat,
    did: String?,
    labels: [ComAtprotoLabelDefs.Label]?,
    policy: ModerationPolicy
  ) -> Source {
    if policy.concealsAvatar(did: did, labels: labels) {
      return .concealed
    }
    guard let request = resizedRequest(for: url, sizeInPoints: sizeInPoints, displayScale: displayScale) else {
      return .placeholder
    }
    return .image(request)
  }

  static func resizedRequest(for url: URL?, sizeInPoints: CGFloat, displayScale: CGFloat) -> ImageRequest? {
    guard let url else { return nil }
    let pixelDimension = max(1, (sizeInPoints * displayScale).rounded(.toNearestOrAwayFromZero))
    let pixelSize = CGSize(width: pixelDimension, height: pixelDimension)
    let processors: [any ImageProcessing] = [
      ImageProcessors.Resize(size: pixelSize, unit: .pixels, contentMode: .aspectFill)
    ]
    return ImageRequest(url: url, processors: processors, priority: .high)
  }

  // MARK: - Deterministic Fallback

  /// First visible initial from `displayName`, else `handle`, or nil when anonymous.
  static func fallbackInitial(displayName: String?, handle: String?) -> String? {
    if let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      let first = trimmed.first
    {
      return String(first).uppercased()
    }
    if let trimmedHandle = handle?.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "@")),
      let first = trimmedHandle.first
    {
      return String(first).uppercased()
    }
    return nil
  }

  /// Deterministic accent option keyed by stable user identity so missing avatars stay recognizable.
  static func fallbackPalette(seed: String?) -> AccentColorOption {
    guard let seed, !seed.isEmpty else { return .catbird }
    var hash: UInt64 = 14695981039346656037
    for byte in seed.utf8 {
      hash ^= UInt64(byte)
      hash &*= 1099511628211
    }
    let all = AccentColorOption.allCases
    return all[Int(hash % UInt64(all.count))]
  }

  // MARK: - Body

  var body: some View {
    let resolvedSource = Self.source(
      url: url,
      sizeInPoints: size,
      displayScale: displayScale,
      did: did,
      labels: labels,
      policy: moderationPolicy
    )

    Group {
      switch resolvedSource {
      case .concealed:
        concealedPlaceholder
      case .image(let request):
        avatarImage(request)
      case .placeholder:
        placeholder
      }
    }
    .frame(width: size, height: size)
    .modifier(AvatarClipModifier(shape: shape))
  }

  @ViewBuilder
  private func avatarImage(_ request: ImageRequest) -> some View {
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

  private var concealedPlaceholder: some View {
    Rectangle()
      .fill(theme.surface(.elevated))
      .overlay {
        Image(systemName: "eye.slash.fill")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .foregroundStyle(theme.text(.tertiary))
          .frame(width: size * 0.45, height: size * 0.45)
      }
  }

  @ViewBuilder
  private var placeholder: some View {
    if let initial = Self.fallbackInitial(displayName: displayName, handle: handle) {
      let palette = Self.fallbackPalette(seed: did ?? handle ?? displayName)
      let paletteTheme = CatbirdThemeColors.resolve(
        colorScheme: theme.colorScheme,
        darkThemeMode: theme.darkThemeMode,
        accent: palette,
        isHighContrast: theme.isHighContrast
      )
      Rectangle()
        .fill(paletteTheme.accentChrome)
        .overlay {
          Text(verbatim: initial)
            .appFont(size: max(11, size * 0.44), weight: .semibold, relativeTo: .body)
            .foregroundStyle(paletteTheme.onAccent)
            .minimumScaleFactor(0.7)
            .lineLimit(1)
        }
    } else {
      Rectangle()
        .fill(theme.surface(.elevated))
        .overlay {
          Image(systemName: "person.crop.circle.fill")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .foregroundStyle(theme.accentChrome.opacity(0.55))
            .padding(size * 0.08)
        }
    }
  }
}

private struct AvatarClipModifier: ViewModifier {
  let shape: CatbirdAvatarShape

  @ViewBuilder
  func body(content: Content) -> some View {
    switch shape {
    case .circle:
      content.clipShape(Circle())
    case .squircle(let radius):
      content.clipShape(radius.shape)
    }
  }
}

#Preview("Avatars") {
  VStack(spacing: Space.lg) {
    HStack(spacing: Space.md) {
      CatbirdAvatar(url: nil, displayName: "Alice", size: AvatarSize.xs)
      CatbirdAvatar(url: nil, displayName: "Bob", size: AvatarSize.sm)
      CatbirdAvatar(url: nil, displayName: "Catbird", size: AvatarSize.md)
      CatbirdAvatar(url: nil, displayName: "Dana", size: AvatarSize.lg)
      CatbirdAvatar(url: nil, displayName: "Eve", size: AvatarSize.xl, shape: .squircle(.md))
    }
    CatbirdAvatar(url: nil, size: AvatarSize.lg)
  }
  .padding(Space.screenMargin)
}
