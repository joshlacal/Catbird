//
//  MediaGalleryView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// A horizontally scrolling gallery of media items with an option to add more
struct MediaGalleryView: View {
    @Binding var mediaItems: [PostComposerViewModel.MediaItem]
    @Binding var currentEditingMediaId: UUID?
    @Binding var isAltTextEditorPresented: Bool
    let maxImagesAllowed: Int
    let onAddMore: () -> Void
    var onMoveLeft: ((UUID) -> Void)? = nil
    var onMoveRight: ((UUID) -> Void)? = nil
    var onCropSquare: ((UUID) -> Void)? = nil
    var onPaste: (() -> Void)?
    var hasClipboardMedia: Bool = false
    var onReorder: ((Int, Int) -> Void)? = nil
    #if os(iOS)
    var onExternalImageDrop: (([Data]) -> Void)? = nil
    #endif

    @State private var draggingId: UUID?
    @State private var isExternalTargeted: Bool = false
    
    private let itemSize: CGFloat = 100
    private let spacing: CGFloat = 12
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with count
            HStack {
                Text("Media")
                    .appFont(AppTextRole.headline)
                
                Spacer()
                
                Text("\(mediaItems.count)/\(maxImagesAllowed)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            
            // Image gallery
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: spacing) {
                    // Existing media items
                    ForEach(Array(mediaItems.enumerated()), id: \.element.id) { index, item in
                        VStack(spacing: 6) {
                            MediaItemView(
                                item: item,
                                onRemove: { removeMediaItem(withId: item.id) },
                                onEditAlt: { beginEditingAltText(for: item.id) }
                            )
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { items, _ in
                                guard let idStr = items.first,
                                      let sourceIndex = mediaItems.firstIndex(where: { $0.id.uuidString == idStr }) else { return false }
                                if let onReorder = onReorder {
                                    onReorder(sourceIndex, index)
                                } else {
                                    reorderLocal(from: sourceIndex, to: index)
                                }
                                return true
                            }
                            #if os(iOS)
                            .onDrop(of: [UTType.image], isTargeted: $isExternalTargeted) { providers in
                                guard let onExternalImageDrop = onExternalImageDrop else { return false }
                                var datas: [Data] = []
                                let group = DispatchGroup()
                                for p in providers {
                                    group.enter()
                                    p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                                        if let data = data { datas.append(data) }
                                        group.leave()
                                    }
                                }
                                group.notify(queue: .main) {
                                    if !datas.isEmpty { onExternalImageDrop(datas) }
                                }
                                return true
                            }
                            .overlay(alignment: .topTrailing) {
                                if isExternalTargeted {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                        .padding(6)
                                }
                            }
                            #endif
                            HStack(spacing: 8) {
                                if let onMoveLeft = onMoveLeft { Button(action: { onMoveLeft(item.id) }) { Image(systemName: "arrow.left") } }
                                if let onMoveRight = onMoveRight { Button(action: { onMoveRight(item.id) }) { Image(systemName: "arrow.right") } }
                                if let onCropSquare = onCropSquare { Button(action: { onCropSquare(item.id) }) { Image(systemName: "crop") } }
                            }
                            .buttonStyle(.borderless)
                            .appFont(AppTextRole.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    
                    // Paste button (if clipboard has media and we can add more)
                    if canAddMoreMedia && hasClipboardMedia, let onPaste = onPaste {
                        pasteButton(action: onPaste)
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
    
    /// Button to paste media from clipboard
    private func pasteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.clipboard")
                    .appFont(size: 24)
                
                Text("Paste")
                    .appFont(AppTextRole.caption)
            }
            .frame(width: itemSize, height: itemSize)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.1))
            .cornerRadius(12)
        }
        .accessibilityLabel("Paste media from clipboard")
    }

    /// Button to add more media
    private var addMoreButton: some View {
        Button(action: onAddMore) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .appFont(size: 24)
                
                Text("Add Media")
                    .appFont(AppTextRole.caption)
            }
            .frame(width: itemSize, height: itemSize)
            .foregroundStyle(Color.accentColor)
            .background(Color(platformColor: PlatformColor.platformSystemGray6))
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

    private func reorderLocal(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              mediaItems.indices.contains(sourceIndex),
              mediaItems.indices.contains(destinationIndex) else { return }
        let item = mediaItems.remove(at: sourceIndex)
        mediaItems.insert(item, at: destinationIndex)
    }
}

#Preview {
    @Previewable @Environment(AppState.self) var appState
    MediaGalleryView(
        mediaItems: .constant([
            {
                var item = PostComposerViewModel.MediaItem()
                item.image = Image(systemName: "photo")
                item.altText = ""
                item.isLoading = false
                return item
            }()
        ]),
        currentEditingMediaId: .constant(nil),
        isAltTextEditorPresented: .constant(false),
        maxImagesAllowed: 4,
        onAddMore: {}
    )
}
