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
    let isVideo: Bool
    
    // Dimensions for thumbnails
    private let size: CGFloat = 100
    
    init(item: PostComposerViewModel.MediaItem, onRemove: @escaping () -> Void, onEditAlt: @escaping () -> Void, isVideo: Bool = false) {
        self.item = item
        self.onRemove = onRemove
        self.onEditAlt = onEditAlt
        self.isVideo = isVideo
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                } else {
                    ProgressView()
                }
            }
            .frame(width: size, height: size)
            .background(Color(.systemGray5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .appFont(size: 20)
                    .foregroundStyle(.white, Color(.systemGray3))
                    .background(Circle().fill(Color.black.opacity(0.3)))
            }
            .padding(4)
            .accessibilityLabel("Remove \(isVideo ? "video" : "image")")
            
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
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                    }
                    .accessibilityLabel(item.altText.isEmpty ? "Add description" : "Edit description")
                }
                .padding(6)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap on the image opens the alt text editor
            onEditAlt()
        }
    }
}

#Preview {
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
