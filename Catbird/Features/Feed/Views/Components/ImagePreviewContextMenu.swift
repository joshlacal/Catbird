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

  func body(content: Content) -> some View {
    if isEnabled {
      content
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
          FullsizeImagePreview(image: image)
        }
    } else {
      content
    }
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

  var body: some View {
    let size = Self.previewSize(for: image)

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

  /// Fits the image's aspect ratio inside the screen width and the upper part of
  /// the screen, leaving room for the menu below it.
  @MainActor
  static func previewSize(for image: AppBskyEmbedImages.ViewImage) -> CGSize {
    let screen = PlatformScreenInfo.size
    let maxWidth = min(screen.width - 32, 720)
    let maxHeight = screen.height * 0.6

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
}
