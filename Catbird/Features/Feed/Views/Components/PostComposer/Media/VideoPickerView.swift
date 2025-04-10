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
    
    var body: some View {
        VStack(spacing: 12) {
            if let videoItem = videoItem {
                ZStack(alignment: .topTrailing) {
                    // Video thumbnail
                    if videoItem.isLoading {
                        ProgressView()
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
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white)
                                    .opacity(0.8)
                            }
                            
                            // Alt text status
                            HStack {
                                Text(videoItem.altText.isEmpty ? "Add description" : videoItem.altText)
                                    .font(.caption)
                                    .foregroundColor(videoItem.altText.isEmpty ? .gray : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                
                                Spacer()
                                
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                            .onTapGesture {
                                onEditAlt(videoItem.id)
                            }
                        }
                    }
                    
                    // Remove button
                    Button(action: {
                        self.videoItem = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white, Color(.systemGray3))
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
                                    .font(.caption)
                            }
                            .progressViewStyle(.linear)
                        case .processing(let progress):
                            ProgressView(value: progress) {
                                Text("Processing video: \(Int(progress * 100))%")
                                    .font(.caption)
                            }
                            .progressViewStyle(.linear)
                        case .complete:
                            Text("Video ready to post")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failed(let error):
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text("Error: \(error)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        case .notStarted:
                            Text("Ready to upload")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }
}

#Preview {
    VideoPickerView(
        videoItem: .constant(PostComposerViewModel.MediaItem(
            pickerItem: PhotosPickerItem(itemIdentifier: "preview"),
            image: Image(systemName: "video"),
            altText: "Preview video",
            isLoading: false
        )),
        isUploading: .constant(false),
        mediaUploadManager: nil,
        onEditAlt: { _ in }
    )
    .padding()
    .previewLayout(.sizeThatFits)
}
