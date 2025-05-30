//
//  PostEmbed.swift
//  Catbird
//
//  Created by Josh LaCalamito on 7/28/24.
//

import SwiftUI
import Petrel
import NukeUI
import Observation

/// A unified component for displaying different types of post embeds.
struct PostEmbed: View {
    // MARK: - Properties
    let embed: AppBskyFeedDefs.PostViewEmbedUnion
    let labels: [ComAtprotoLabelDefs.Label]?
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    @Environment(\.postID) private var postID
    
    // MARK: - Constants
    private static let cornerRadius: CGFloat = 10
    private static let spacing: CGFloat = 8
    
    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch embed {
            case .appBskyEmbedImagesView(let imagesView):
                imageEmbed(imagesView)
                
            case .appBskyEmbedExternalView(let externalView):
                externalEmbed(externalView)
                
            case .appBskyEmbedRecordView(let recordView):
                recordEmbed(recordView)
                
            case .appBskyEmbedRecordWithMediaView(let recordWithMediaView):
                recordWithMediaEmbed(recordWithMediaView)
                
            case .appBskyEmbedVideoView(let videoView):
                videoEmbed(videoView)
                
            case .unexpected:
                EmptyView()
            }
        }
        // Force calculated height to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    // MARK: - Embed Type Views

    @ViewBuilder
    private func imageEmbed(_ imagesView: AppBskyEmbedImages.View) -> some View {
        ContentLabelManager(
            labels: labels,
            contentType: "image"
        ) {
            ViewImageGridView(
                viewImages: imagesView.images,
                shouldBlur: false // We're handling blur at the ContentLabelManager level now
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        }
    }

    @ViewBuilder
    private func externalEmbed(_ externalView: AppBskyEmbedExternal.View) -> some View {
        ContentLabelManager(
            labels: labels,
            contentType: "link"
        ) {
            ExternalEmbedView(
                external: externalView.external,
                shouldBlur: false, // We're handling blur at the ContentLabelManager level now
                postID: postID
            )
        }
    }

    @ViewBuilder
    private func recordEmbed(_ recordView: AppBskyEmbedRecord.View) -> some View {
        RecordEmbedView(
            record: recordView.record,
            labels: labels,
            path: $path
        )
    }

    @ViewBuilder
    private func recordWithMediaEmbed(_ recordWithMediaView: AppBskyEmbedRecordWithMedia.View) -> some View {
        VStack(spacing: Self.spacing) {
            //  show the media part
            switch recordWithMediaView.media {
            case .appBskyEmbedImagesView(let imagesView):
                ContentLabelManager(
                    labels: labels,
                    contentType: "image"
                ) {
                    ViewImageGridView(
                        viewImages: imagesView.images,
                        shouldBlur: false // We're handling blur at the ContentLabelManager level now
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                }

            case .appBskyEmbedExternalView(let externalView):
                ContentLabelManager(
                    labels: labels,
                    contentType: "link"
                ) {
                    ExternalEmbedView(
                        external: externalView.external,
                        shouldBlur: false, // We're handling blur at the ContentLabelManager level now
                        postID: postID
                    )
                }

            case .appBskyEmbedVideoView(let videoView):
                // For videos with adult content, use ContentLabelManager with specific handling
                if hasAdultContentLabel(labels) {
                    ContentLabelManager(
                        labels: labels,
                        contentType: "video"
                    ) {
                        if let playerView = ModernVideoPlayerView18(
                            bskyVideo: videoView,
                            postID: "\(postID)-\(videoView.playlist.uriString())-\(videoView.cid)"
                        ) {
                            playerView
                                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Unable to load video")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    // No adult content, show video as normal
                    if let playerView = ModernVideoPlayerView18(
                        bskyVideo: videoView,
                        postID: "\(postID)-\(videoView.playlist.uriString())-\(videoView.cid)"
                    ) {
                        playerView
                            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Unable to load video")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            case .unexpected:
                EmptyView()
            }

            //  show the record
            RecordEmbedView(
                record: recordWithMediaView.record.record,
                labels: labels,
                path: $path
            )
        }
    }

    @ViewBuilder
    private func videoEmbed(_ videoView: AppBskyEmbedVideo.View) -> some View {
        // For videos with adult content, use ContentLabelManager with specific handling
        if hasAdultContentLabel(labels) {
            ContentLabelManager(
                labels: labels,
                contentType: "video"
            ) {
                if let playerView = ModernVideoPlayerView18(
                    bskyVideo: videoView,
                    postID: "\(postID)-\(videoView.playlist.uriString())-\(videoView.cid)"
                ) {
                    playerView
                        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Unable to load video")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // No adult content, show video as normal
            if let playerView = ModernVideoPlayerView18(
                bskyVideo: videoView,
                postID: "\(postID)-\(videoView.playlist.uriString())-\(videoView.cid)"
            ) {
                playerView
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
                    .frame(maxWidth: .infinity)
            } else {
                Text("Unable to load video")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Helper Methods
    
    /// Determines if the post has adult content labels.
    private func hasAdultContentLabel(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        guard !appState.isAdultContentEnabled else { return false }
        return labels?.contains { label in
            let lowercasedValue = label.val.lowercased()
            return lowercasedValue == "porn" || lowercasedValue == "nsfw" || lowercasedValue == "nudity"
        } ?? false
    }
}
