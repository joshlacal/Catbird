//
//  ImageRequestFactory.swift
//  Catbird
//
//  Central image request builder enforcing a unified display-size decoding policy
//  and URL rewriting across all image loading surfaces.
//
//  ### Policy & Conventions:
//  1. Display-Size Downsampling:
//     Images must not be decoded at full source/CDN resolution (which can exceed
//     1000x1000 for avatars or 3000x1000 for banners, consuming 4-12 MB of RAM each).
//     Requests created here attach an `ImageProcessors.Resize` processor configured with
//     exact target pixel dimensions (`pointSize * scale`).
//
//  2. Processor & Cache Key Identity:
//     `ImageProcessors.Resize` is initialized with `unit: .pixels`. Nuke hashes processor
//     identifiers directly into its memory and disk cache keys. The identifier format
//     `com.github.kean/nuke/resize?s=(width, height),cm=...` explicitly includes pixel
//     dimensions, ensuring that:
//     - Different display sizes or screen scales produce distinct cache entries without collisions.
//     - Downsampling occurs at decode time, protecting the 100 MB Nuke ImageCache from thrashing.
//
//  3. Avatar URL Rewriting:
//     For Bluesky CDN avatars (`cdn.bsky.app`), URLs matching `/img/avatar/plain/` are
//     rewritten to `/img/avatar_thumbnail/plain/` prior to building the request, mirroring
//     `ProfileViewBasic+Extensions.swift`. This avoids fetching high-resolution CDN assets
//     when displaying small avatar circles. Non-Bluesky CDN URLs, already-thumbnail URLs,
//     query parameters, and fragments are preserved.
//
//  4. Safe Nil & Geometry Handling:
//     Passing `nil` for a URL cleanly returns `nil`. Scales <= 0 default to 1.0, and
//     computed pixel dimensions are clamped to a minimum of 1 pixel to prevent invalid
//     zero-size decode requests.
//

import CoreGraphics
import Foundation
import Nuke

public enum ImageRequestFactory: Sendable {

  // MARK: - Avatar Requests

  /// Rewrites `/img/avatar/plain/` → `/img/avatar_thumbnail/plain/` for Bluesky CDN URLs
  /// and downsamples at decode to `pointSize * scale` pixels.
  ///
  /// - Parameters:
  ///   - url: The source avatar URL, or `nil`.
  ///   - pointSize: The target display size in points (width and height).
  ///   - scale: The display scale factor (e.g. from `@Environment(\.displayScale)`).
  ///   - contentMode: Image content mode, defaults to `.aspectFill` for circular avatars.
  ///   - priority: Loading priority, defaults to `.high` for avatars.
  /// - Returns: A configured `ImageRequest`, or `nil` if `url` is `nil`.
  public static func avatar(
    _ url: URL?,
    pointSize: CGFloat,
    scale: CGFloat,
    contentMode: ImageProcessingOptions.ContentMode = .aspectFill,
    priority: ImageRequest.Priority = .high
  ) -> ImageRequest? {
    guard let url else { return nil }

    let effectiveScale = scale > 0 ? scale : 1.0
    let pixelDimension = max(1, (pointSize * effectiveScale).rounded(.toNearestOrAwayFromZero))
    let pixelSize = CGSize(width: pixelDimension, height: pixelDimension)

    let processor = ImageProcessors.Resize(
      size: pixelSize,
      unit: .pixels,
      contentMode: contentMode,
      crop: false,
      upscale: false
    )

    let finalURL = rewriteAvatarURL(url)
    return ImageRequest(url: finalURL, processors: [processor], priority: priority)
  }

  // MARK: - Generic Image Requests

  /// Generic downsample-at-decode for banners, embed thumbnails, posters, and icons.
  /// Fits within `pointSize * scale` pixels.
  ///
  /// - Parameters:
  ///   - url: The source image URL, or `nil`.
  ///   - pointSize: Target bounding size in points.
  ///   - scale: The display scale factor (e.g. from `@Environment(\.displayScale)`).
  ///   - contentMode: Image content mode, defaults to `.aspectFit` (fits within bounds).
  ///   - priority: Loading priority, defaults to `.normal`.
  /// - Returns: A configured `ImageRequest`, or `nil` if `url` is `nil`.
  public static func image(
    _ url: URL?,
    pointSize: CGSize,
    scale: CGFloat,
    contentMode: ImageProcessingOptions.ContentMode = .aspectFit,
    priority: ImageRequest.Priority = .normal
  ) -> ImageRequest? {
    guard let url else { return nil }

    let effectiveScale = scale > 0 ? scale : 1.0
    let pixelWidth = max(1, (pointSize.width * effectiveScale).rounded(.toNearestOrAwayFromZero))
    let pixelHeight = max(1, (pointSize.height * effectiveScale).rounded(.toNearestOrAwayFromZero))
    let pixelSize = CGSize(width: pixelWidth, height: pixelHeight)

    let processor = ImageProcessors.Resize(
      size: pixelSize,
      unit: .pixels,
      contentMode: contentMode,
      crop: false,
      upscale: false
    )

    return ImageRequest(url: url, processors: [processor], priority: priority)
  }

  /// Convenience square overload for icons and square embed thumbnails.
  /// Fits within `pointSize * scale` pixels.
  public static func image(
    _ url: URL?,
    pointSize: CGFloat,
    scale: CGFloat,
    contentMode: ImageProcessingOptions.ContentMode = .aspectFit,
    priority: ImageRequest.Priority = .normal
  ) -> ImageRequest? {
    image(
      url,
      pointSize: CGSize(width: pointSize, height: pointSize),
      scale: scale,
      contentMode: contentMode,
      priority: priority
    )
  }

  // MARK: - URL Rewriting Helpers

  /// Rewrites Bluesky CDN avatar URLs from full-size `/img/avatar/plain/` to `/img/avatar_thumbnail/plain/`.
  /// Preserves non-Bluesky-CDN URLs, non-avatar URLs, query parameters, and fragments.
  public static func rewriteAvatarURL(_ url: URL) -> URL {
    if url.host == "cdn.bsky.app" && url.path.contains("/img/avatar/plain/") {
      let finalURLString = url.absoluteString.replacingOccurrences(
        of: "/img/avatar/plain/",
        with: "/img/avatar_thumbnail/plain/"
      )
      return URL(string: finalURLString) ?? url
    }
    return url
  }

  /// Optional-tolerant overload of avatar URL rewriting.
  public static func rewriteAvatarURL(_ url: URL?) -> URL? {
    guard let url else { return nil }
    return rewriteAvatarURL(url)
  }
}
