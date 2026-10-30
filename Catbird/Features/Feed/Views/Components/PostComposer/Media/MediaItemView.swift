//
//  MediaItemView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI
import PhotosUI

/// A view representing a single media item in the composer
struct MediaItemView: View {
    let item: PostComposerViewModel.MediaItem
    let onRemove: () -> Void
    let onEditAlt: () -> Void
    let onEditImage: (() -> Void)?
    let isVideo: Bool
    let onRetry: (() -> Void)?

    // Dimensions for thumbnails
    private let size: CGFloat = 100

    init(
      item: PostComposerViewModel.MediaItem,
      onRemove: @escaping () -> Void,
      onEditAlt: @escaping () -> Void,
      onEditImage: (() -> Void)? = nil,
      isVideo: Bool = false,
      onRetry: (() -> Void)? = nil
    ) {
        self.item = item
        self.onRemove = onRemove
        self.onEditAlt = onEditAlt
        self.onEditImage = onEditImage
        self.isVideo = isVideo
        self.onRetry = onRetry
    }
    
    var body: some View {
        ZStack {
            // Image or loading state
            Group {
                if let image = item.image {
                    ZStack {
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)

                        // Video play indicator if this is a video
                        if isVideo {
                            Image(systemName: "play.circle.fill")
                                .appFont(size: 28)
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                    }
                } else if item.isLoading {
                    ProgressView()
                        .accessibilityLabel("Loading media")
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Preview unavailable")
                            .appFont(AppTextRole.caption2)
                            .multilineTextAlignment(.center)
                        if item.canRetryLoading, let onRetry {
                            Button("Retry", action: onRetry)
                                .appFont(AppTextRole.caption)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .frame(width: size, height: size)
            .background(Color(platformColor: PlatformColor.platformSystemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Top-left: Edit image button (only for images, not videos)
            if !isVideo, item.image != nil, !item.isLoading, let onEditImage = onEditImage {
                VStack {
                    HStack {
                        if #available(iOS 26.0, macOS 26.0, *) {
                            Button(action: onEditImage) {
                                Image(systemName: "slider.horizontal.3")
                                    .appFont(size: 14)
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive())
                            .accessibilityLabel("Edit Image")
                        } else {
                            Button(action: onEditImage) {
                                Image(systemName: "slider.horizontal.3")
                                    .appFont(size: 14)
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit Image")
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(4)
            }

            // Top-right: Remove button
            VStack {
                HStack {
                    Spacer()
                    Button(action: onRemove) {
                        ComposerAttachmentRemoveLabel()
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isVideo ? "Remove Video" : "Remove Image")
                }
                Spacer()
            }
            .padding(4)
            
            if item.image != nil {
            // Alt text status indicator
            VStack {
                Spacer()
                
                HStack {
                    Spacer()
                    
                    Button(action: onEditAlt) {
                        HStack(spacing: 4) {
                            Image(systemName: item.altText.isEmpty ? "text.badge.plus" : "text.badge.checkmark")
                                .appFont(AppTextRole.caption)
                            
                            Text(item.altText.isEmpty ? "Add alt" : "Edit alt")
                                .appFont(AppTextRole.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .modifier(MediaAltBadgeBackground())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.altText.isEmpty ? "Add description" : "Edit description")
                }
                .padding(6)
            }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap on the image opens the alt text editor
            if item.image != nil { onEditAlt() }
        }
    }
}

/// The remove control drawn over composer media, matching the glass edit button on iOS 26.
struct ComposerAttachmentRemoveLabel: View {
    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Image(systemName: "xmark")
                .appFont(size: 11, weight: .bold)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            Image(systemName: "xmark.circle.fill")
                .appFont(size: 20)
                .foregroundStyle(.white, Color(platformColor: PlatformColor.platformSystemGray3))
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
    }
}

private struct MediaAltBadgeBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .foregroundStyle(.white)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .foregroundStyle(.primary)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// Helper for conditional modifiers
private extension View {
  @ViewBuilder
  func `if`<Content: View>(
    _ condition: Bool,
    transform: (Self) -> Content,
    else elseTransform: (Self) -> Content
  ) -> some View {
    if condition {
      transform(self)
    } else {
      elseTransform(self)
    }
  }
}

#Preview {
    @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
    HStack {
        MediaItemView(
            item: {
                var item = PostComposerViewModel.MediaItem()
                item.image = Image(systemName: "photo")
                item.altText = ""
                item.isLoading = false
                return item
            }(),
            onRemove: {},
            onEditAlt: {}
        )
        
        MediaItemView(
            item: {
                var item = PostComposerViewModel.MediaItem()
                item.image = Image(systemName: "photo")
                item.altText = "A sample video"
                item.isLoading = false
                return item
            }(),
            onRemove: {},
            onEditAlt: {},
            isVideo: true
        )
    }
    .padding()
    .previewLayout(.sizeThatFits)
}
