//
//  GalleryEmbedView.swift
//  Catbird
//
//  Renders app.bsky.embed.gallery embeds. Posts with 1-4 photos reuse the
//  existing image grid; posts with 5+ photos render a horizontal free-scrolling
//  carousel matching the official app's behavior.
//

import NukeUI
import Petrel
import SwiftUI

struct GalleryEmbedView: View {
  let gallery: AppBskyEmbedGallery.View
  let shouldBlur: Bool

  @State private var isBlurred: Bool
  @State private var selectedImage: AppBskyEmbedImages.ViewImage?
  @State private var currentIndex: Int = 0 {
    didSet {
      if selectedImage != nil {
        activeTransitionID = mappedImages[safe: currentIndex]?.id
      }
    }
  }
  @State private var lastViewedIndex: Int = 0
  @State private var activeTransitionID: String?
  @Namespace private var imageTransition

  #if os(iOS)
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  // MARK: - Constants
  private static let cornerRadius: CGFloat = 10
  private static let itemSpacing: CGFloat = 8
  private static let minItemAspectRatio: CGFloat = 2.0 / 3.0
  private static let maxItemAspectRatio: CGFloat = 3.0 / 2.0
  static let compactCarouselHeight: CGFloat = 200
  static let regularCarouselHeight: CGFloat = 300

  init(gallery: AppBskyEmbedGallery.View, shouldBlur: Bool) {
    self.gallery = gallery
    self.shouldBlur = shouldBlur
    self._isBlurred = State(initialValue: shouldBlur)
  }

  // MARK: - Image Extraction

  /// Gallery items narrowed to the known view-image case.
  private var galleryImages: [AppBskyEmbedGallery.ViewImage] {
    gallery.items.compactMap {
      if case .appBskyEmbedGalleryViewImage(let img) = $0 { return img } else { return nil }
    }
  }

  /// Gallery images mapped onto the images-embed shape so the grid and
  /// fullscreen viewer can be reused unchanged.
  private var mappedImages: [AppBskyEmbedImages.ViewImage] {
    galleryImages.map {
      AppBskyEmbedImages.ViewImage(
        thumb: $0.thumbnail,
        fullsize: $0.fullsize,
        alt: $0.alt,
        aspectRatio: $0.aspectRatio
      )
    }
  }

  private var carouselHeight: CGFloat {
    #if os(iOS)
    return horizontalSizeClass == .regular ? Self.regularCarouselHeight : Self.compactCarouselHeight
    #else
    return Self.regularCarouselHeight
    #endif
  }

  // MARK: - Body

  var body: some View {
    let images = mappedImages
    Group {
      if images.isEmpty {
        EmptyView()
      } else if images.count <= 4 {
        // Counts 1-4 behave exactly like the images embed (grid + lightbox + blur)
        ViewImageGridView(viewImages: images, shouldBlur: shouldBlur)
      } else {
        carousel(images: images)
      }
    }
  }

  // MARK: - Carousel (5+ items)

  @ViewBuilder
  private func carousel(images: [AppBskyEmbedImages.ViewImage]) -> some View {
    let height = carouselHeight

    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(spacing: Self.itemSpacing) {
        ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
          carouselItem(image: image, index: index, total: images.count, height: height)
        }
      }
    }
    .frame(height: height)
    .fixedSize(horizontal: false, vertical: true)
#if os(iOS)
    .fullScreenCover(item: $selectedImage) { initialImage in
      viewerContent(images: images, initialImage: initialImage)
    }
#elseif os(macOS)
    .sheet(item: $selectedImage) { initialImage in
      viewerContent(images: images, initialImage: initialImage)
    }
#endif
  }

  @ViewBuilder
  private func carouselItem(
    image: AppBskyEmbedImages.ViewImage, index: Int, total: Int, height: CGFloat
  ) -> some View {
    let rawAspectRatio: CGFloat = {
      guard let ratio = image.aspectRatio, ratio.height > 0 else { return 1 }
      return CGFloat(ratio.width) / CGFloat(ratio.height)
    }()
    let aspectRatio = min(max(rawAspectRatio, Self.minItemAspectRatio), Self.maxItemAspectRatio)
    let width = height * aspectRatio

    ZStack(alignment: .topTrailing) {
      RoundedRectangle(cornerRadius: Self.cornerRadius)
        .fill(Color.gray.opacity(0.1))
        .frame(width: width, height: height)

      LazyImage(request: ImageLoadingManager.imageRequest(
        for: URL(string: image.thumb.uriString()) ?? URL(string: "about:blank")!,
        targetSize: CGSize(width: width, height: height)
      )) { state in
        if let loadedImage = state.image {
          loadedImage
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .modifier(StrongBlurOverlayModifier(isBlurred: isBlurred, cornerRadius: Self.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            .matchedTransitionSource(id: image.id, in: imageTransition) { source in
              source
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
        } else if state.error != nil {
          Image(systemName: "photo")
            .aspectRatio(contentMode: .fit)
            .frame(width: width * 0.3, height: height * 0.3)
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .scaleEffect(0.7)
        }
      }
      .pipeline(ImageLoadingManager.shared.pipeline)

      if total > 1 {
        Text("\(index + 1)/\(total)")
          .appFont(AppTextRole.caption2)
          .fontWeight(.medium)
          .foregroundStyle(.white)
          .padding(.horizontal, 7)
          .padding(.vertical, 3)
          .background(Color.black.opacity(0.55), in: Capsule())
          .padding(6)
          .allowsHitTesting(false)
      }
    }
    .frame(width: width, height: height)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(image.alt.isEmpty ? "Image \(index + 1) of \(total)" : image.alt)
    .accessibilityAddTraits(.isImage)
    .onTapGesture {
      if shouldBlur {
        isBlurred.toggle()
      } else {
        currentIndex = index
        lastViewedIndex = index
        selectedImage = image
        activeTransitionID = image.id
      }
    }
  }

  // MARK: - Fullscreen Viewer

  @ViewBuilder
  private func viewerContent(
    images: [AppBskyEmbedImages.ViewImage], initialImage: AppBskyEmbedImages.ViewImage
  ) -> some View {
    // Derive the start index from the presented item itself: the cover content
    // is built with view closures captured from the pre-tap render, so reading
    // currentIndex here races the @State write from the tap handler and the
    // viewer can open on the wrong page (header/alt showing item 1).
    let startIndex = images.firstIndex { $0.id == initialImage.id } ?? 0
    GalleryViewerHost(
      images: images,
      initialIndex: startIndex,
      namespace: imageTransition,
      onIndexChange: { newIndex in
        currentIndex = newIndex
        lastViewedIndex = newIndex
        activeTransitionID = images[safe: newIndex]?.id
      },
      onDismiss: {
        DispatchQueue.main.async {
          selectedImage = nil
        }
      }
    )
    .onAppear {
      activeTransitionID = initialImage.id
    }
  }
}

/// Hosts EnhancedImageViewer with its own page index seeded at presentation,
/// so the open page does not depend on parent @State writes propagating into
/// the cover's captured closures.
private struct GalleryViewerHost: View {
  let images: [AppBskyEmbedImages.ViewImage]
  let initialIndex: Int
  let namespace: Namespace.ID
  let onIndexChange: (Int) -> Void
  let onDismiss: () -> Void

  @State private var index: Int
  @State private var isPresented = true

  init(
    images: [AppBskyEmbedImages.ViewImage],
    initialIndex: Int,
    namespace: Namespace.ID,
    onIndexChange: @escaping (Int) -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.images = images
    self.initialIndex = initialIndex
    self.namespace = namespace
    self.onIndexChange = onIndexChange
    self.onDismiss = onDismiss
    self._index = State(initialValue: initialIndex)
  }

  var body: some View {
    NavigationStack {
      EnhancedImageViewer(
        images: images,
        initialImageId: images[safe: initialIndex]?.id ?? "",
        currentIndex: Binding(
          get: { index },
          set: { newIndex in
            index = newIndex
            onIndexChange(newIndex)
          }
        ),
        isPresented: Binding(
          get: { isPresented },
          set: { newValue in
            if !newValue {
              isPresented = false
              onDismiss()
            }
          }
        ),
        namespace: namespace
      )
    }
#if os(iOS)
    .ignoresSafeArea()
    .navigationTransition(
      .zoom(sourceID: images[safe: index]?.id ?? "", in: namespace)
    )
#endif
  }
}
