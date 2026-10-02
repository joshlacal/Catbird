//
//  VideoPickerView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/24/25.
//

import SwiftUI
import AVKit
import PhotosUI
import Petrel

/// A view for selecting and displaying video content for uploading
struct VideoPickerView: View {
    @Binding var videoItem: PostComposerViewModel.MediaItem?
    @Binding var isUploading: Bool
    let mediaUploadManager: MediaUploadManager?
    let onEditAlt: (UUID) -> Void
    var onUpdateCaption: ((VideoCaption?) -> Void)? = nil
    var onRemoveCaption: (() -> Void)? = nil
    @State private var showingCaptionEditor: Bool = false

    init(
        videoItem: Binding<PostComposerViewModel.MediaItem?>,
        isUploading: Binding<Bool>,
        mediaUploadManager: MediaUploadManager?,
        onEditAlt: @escaping (UUID) -> Void,
        onUpdateCaption: ((VideoCaption?) -> Void)? = nil,
        onRemoveCaption: (() -> Void)? = nil
    ) {
        self._videoItem = videoItem
        self._isUploading = isUploading
        self.mediaUploadManager = mediaUploadManager
        self.onEditAlt = onEditAlt
        self.onUpdateCaption = onUpdateCaption
        self.onRemoveCaption = onRemoveCaption
    }
    var body: some View {
        VStack(spacing: 12) {
            if let videoItem = videoItem {
                ZStack(alignment: .topTrailing) {
                    // Video thumbnail
                    if videoItem.isLoading {
                        VStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                            Text("Preparing video…")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxHeight: 200)
                    } else if let image = videoItem.image {
                        VStack {
                            ZStack {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                
                                // Play icon overlay
                                Image(systemName: "play.circle.fill")
                                    .appFont(size: 44)
                                    .foregroundStyle(.white)
                                    .opacity(0.8)
                            }
                            
                            // Alt text and Captions status
                            VStack(spacing: 6) {
                                // Alt text status
                                HStack {
                                    Text(videoItem.altText.isEmpty ? "Add description" : videoItem.altText)
                                        .appFont(AppTextRole.caption)
                                        .foregroundColor(videoItem.altText.isEmpty ? .gray : .primary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    
                                    Spacer()
                                    
                                    Image(systemName: "pencil")
                                        .appFont(AppTextRole.caption)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(platformColor: .platformSystemGray6))
                                .cornerRadius(6)
                                .onTapGesture {
                                    onEditAlt(videoItem.id)
                                }

                                // Captions status
                                HStack {
                                    if let caption = videoItem.caption {
                                        let langCode = caption.lang.lang.languageCode?.identifier ?? caption.lang.lang.minimalIdentifier
                                        let langName = Locale.current.localizedString(forLanguageCode: langCode) ?? caption.lang.lang.minimalIdentifier
                                        
                                        Image(systemName: "captions.bubble.fill")
                                            .appFont(AppTextRole.caption)
                                            .foregroundStyle(.tint)
                                        
                                        Text("\(langName) (\(caption.filename))")
                                            .appFont(AppTextRole.caption)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        
                                        Spacer()
                                        
                                        Button(action: {
                                            self.videoItem?.caption = nil
                                            if let onRemoveCaption {
                                                onRemoveCaption()
                                            } else if let onUpdateCaption {
                                                onUpdateCaption(nil)
                                            }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .appFont(AppTextRole.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Remove caption")
                                    } else {
                                        Image(systemName: "captions.bubble")
                                            .appFont(AppTextRole.caption)
                                            .foregroundStyle(.secondary)
                                        
                                        Text("Captions (.vtt)")
                                            .appFont(AppTextRole.caption)
                                            .foregroundColor(.gray)
                                        
                                        Spacer()
                                        
                                        Image(systemName: "plus")
                                            .appFont(AppTextRole.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(platformColor: .platformSystemGray6))
                                .cornerRadius(6)
                                .onTapGesture {
                                    showingCaptionEditor = true
                                }
                            }
                        }
                    }
                    
                    // Remove button
                    Button(action: {
                        self.videoItem = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .appFont(AppTextRole.title1)
                            .foregroundStyle(.white, Color(platformColor: .platformSystemGray3))
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.3))
                            )
                    }
                    .padding(8)
                    .disabled(isUploading)
                }
                
                // Upload status indicator
                if isUploading, let uploadManager = mediaUploadManager {
                    VStack(spacing: 8) {
                        switch uploadManager.uploadStatus {
                        case .uploading(let progress):
                            ProgressView(value: progress) {
                                Text("Uploading video: \(Int(progress * 100))%")
                                    .appFont(AppTextRole.caption)
                            }
                            .progressViewStyle(.linear)
                        case .processing(let progress):
                            ProgressView(value: progress) {
                                Text("Processing video: \(Int(progress * 100))%")
                                    .appFont(AppTextRole.caption)
                            }
                            .progressViewStyle(.linear)
                        case .complete:
                            Text("Video ready to post")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.green)
                        case .failed(let error):
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("Error: \(error)")
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.red)
                            }
                        case .notStarted:
                            Text("Ready to upload")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        case .cancelled:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text("Cancelled")
                                .appFont(AppTextRole.caption)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .sheet(isPresented: $showingCaptionEditor) {
            if let currentVideo = videoItem {
                VideoCaptionEditorView(
                    caption: currentVideo.caption,
                    onSave: { newCaption in
                        self.videoItem?.caption = newCaption
                        if let onUpdateCaption {
                            onUpdateCaption(newCaption)
                        }
                    },
                    onRemove: {
                        self.videoItem?.caption = nil
                        if let onRemoveCaption {
                            onRemoveCaption()
                        } else if let onUpdateCaption {
                            onUpdateCaption(nil)
                        }
                    }
                )
            }
        }
    }
}

#Preview {
    @ObservationIgnored @Previewable @ObservationIgnored @Environment(AppState.self) var appState
    VideoPickerView(
        videoItem: .constant({
            var item = PostComposerViewModel.MediaItem()
            item.image = Image(systemName: "video")
            item.altText = "Preview video"
            item.isLoading = false
            return item
        }()),
        isUploading: .constant(false),
        mediaUploadManager: nil,
        onEditAlt: { _ in }
    )
    .padding()
    .previewLayout(.sizeThatFits)
}
