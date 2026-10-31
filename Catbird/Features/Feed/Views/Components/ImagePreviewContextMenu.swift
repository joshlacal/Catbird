//
//  ImagePreviewContextMenu.swift
//  Catbird
//
//  Long-press menu for post images. The menu's preview loads the fullsize
//  image at its own aspect ratio instead of lifting the cropped thumbnail.
//

import Nuke
import NukeUI
import Petrel
import SwiftUI

struct ImagePreviewContextMenu: ViewModifier {
  let image: AppBskyEmbedImages.ViewImage
  /// Off while the image is hidden behind a content warning, so the preview can't reveal it.
  let isEnabled: Bool
  let onOpen: () -> Void
  @Environment(\.containerViewportSize) private var containerViewportSize
  @State private var hostingWindowSize: CGSize?

  func body(content: Content) -> some View {
    if isEnabled {
      content
        .background(viewportReader)
        .contextMenu {
          Button(action: onOpen) {
            Label("Open Image", systemImage: "arrow.up.left.and.arrow.down.right")
          }
          if let url = URL(string: image.fullsize.uriString()) {
            ShareLink(item: url) {
              Label("Share Image Link", systemImage: "square.and.arrow.up")
            }
          }
        } preview: {
          FullsizeImagePreview(image: image, viewportSize: containerViewportSize ?? hostingWindowSize)
        }
    } else {
      content
    }
  }

  /// Feed cells and the root drawer pass the viewport through the environment. Hosts
  /// that don't, such as the UIKit thread cells, read the window the image sits in.
  @ViewBuilder
  private var viewportReader: some View {
    #if os(iOS)
    if containerViewportSize == nil {
      WindowViewportReader { hostingWindowSize = $0 }
    }
    #endif
  }
}

extension View {
  /// Adds a long-press menu whose preview shows `image` at full size.
  func imagePreviewContextMenu(
    _ image: AppBskyEmbedImages.ViewImage,
    isEnabled: Bool = true,
    onOpen: @escaping () -> Void
  ) -> some View {
    modifier(ImagePreviewContextMenu(image: image, isEnabled: isEnabled, onOpen: onOpen))
  }
}

/// The fullsize image, sized to its aspect ratio. The thumbnail shows underneath until the fullsize arrives.
private struct FullsizeImagePreview: View {
  let image: AppBskyEmbedImages.ViewImage
  /// The window or container the image is shown in, when known.
  let viewportSize: CGSize?

  var body: some View {
    let size = Self.previewSize(for: image, viewportSize: viewportSize)

    ZStack {
      Color.black

      LazyImage(request: ImageRequest(url: URL(string: image.thumb.uriString()), priority: .veryHigh)) { state in
        if let thumb = state.image {
          thumb
            .resizable()
            .aspectRatio(contentMode: .fit)
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)

      LazyImage(request: ImageRequest(url: URL(string: image.fullsize.uriString()), priority: .veryHigh)) { state in
        if let fullsize = state.image {
          fullsize
            .resizable()
            .aspectRatio(contentMode: .fit)
        } else if state.error == nil {
          ProgressView()
            .tint(.white)
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)
    }
    .frame(width: size.width, height: size.height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
    .accessibilityAddTraits(.isImage)
  }

  /// Fits the image's aspect ratio inside the viewport width and the upper part of
  /// the viewport, leaving room for the menu below it.
  @MainActor
  static func previewSize(for image: AppBskyEmbedImages.ViewImage, viewportSize: CGSize?) -> CGSize {
    let viewport = viewportSize.flatMap { $0.width > 32 && $0.height > 0 ? $0 : nil } ?? fallbackViewportSize
    let maxWidth = min(viewport.width - 32, 720)
    let maxHeight = viewport.height * 0.6

    let ratio: CGFloat = image.aspectRatio.flatMap { ratio -> CGFloat? in
      guard ratio.width > 0, ratio.height > 0 else { return nil }
      return CGFloat(ratio.width) / CGFloat(ratio.height)
    } ?? 1

    var width = maxWidth
    var height = width / ratio
    if height > maxHeight {
      height = maxHeight
      width = height * ratio
    }
    return CGSize(width: width.rounded(), height: height.rounded())
  }

  /// Used until the hosting window reports its size: the key window on macOS,
  /// and the smallest supported iPhone on iOS.
  @MainActor
  private static var fallbackViewportSize: CGSize {
    #if os(macOS)
    return PlatformScreenInfo.size
    #else
    return CGSize(width: 375, height: 667)
    #endif
  }
}
