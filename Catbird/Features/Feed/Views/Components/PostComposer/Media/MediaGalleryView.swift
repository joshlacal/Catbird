//
//  MediaGalleryView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI
import PhotosUI

/// A horizontally scrolling gallery of media items with an option to add more
struct MediaGalleryView: View {
    @Binding var mediaItems: [PostComposerViewModel.MediaItem]
    @Binding var currentEditingMediaId: UUID?
    @Binding var isAltTextEditorPresented: Bool
    let maxImagesAllowed: Int
    let onAddMore: () -> Void
    
    private let itemSize: CGFloat = 100
    private let spacing: CGFloat = 12
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with count
            HStack {
                Text("Media")
                    .font(.headline)
                
                Spacer()
                
                Text("\(mediaItems.count)/\(maxImagesAllowed)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            
            // Image gallery
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    // Existing media items
                    ForEach(mediaItems) { item in
                        MediaItemView(
                            item: item,
                            onRemove: { removeMediaItem(withId: item.id) },
                            onEditAlt: { beginEditingAltText(for: item.id) }
                        )
                    }
                    
                    // Add more button
                    if canAddMoreMedia {
                        addMoreButton
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: itemSize + 8) // Add a bit of padding
        }
    }
    
    /// Button to add more media
    private var addMoreButton: some View {
        Button(action: onAddMore) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24))
                
                Text("Add Media")
                    .font(.caption)
            }
            .frame(width: itemSize, height: itemSize)
            .foregroundStyle(Color.accentColor)
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .accessibilityLabel("Add more images")
    }
    
    // Helper computed property to check if more media can be added
    private var canAddMoreMedia: Bool {
        return mediaItems.count < maxImagesAllowed
    }
    
    // Remove a media item with the specified ID
    private func removeMediaItem(withId id: UUID) {
        mediaItems.removeAll(where: { $0.id == id })
    }
    
    // Begin editing alt text for a specific item
    private func beginEditingAltText(for id: UUID) {
        currentEditingMediaId = id
        isAltTextEditorPresented = true
    }
}

#Preview {
    MediaGalleryView(
        mediaItems: .constant([
            PostComposerViewModel.MediaItem(
                pickerItem: PhotosPickerItem(itemIdentifier: "preview"),
                image: Image(systemName: "photo"),
                altText: "",
                isLoading: false
            )
        ]),
        currentEditingMediaId: .constant(nil),
        isAltTextEditorPresented: .constant(false),
        maxImagesAllowed: 4,
        onAddMore: {}
    )
}
