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
    @Environment(\.colorScheme) private var colorScheme
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
            case .pending(_):
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
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
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
        // Extract labels from the embedded record itself, not the parent post
        let embedLabels: [ComAtprotoLabelDefs.Label]? = {
            switch recordView.record {
            case .appBskyEmbedRecordViewRecord(let viewRecord):
                return viewRecord.labels
            default:
                return nil
            }
        }()

        RecordEmbedView(
            record: recordView.record,
            labels: embedLabels,
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
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))

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
                // Always use ContentLabelManager for videos - it will handle show/warn/hide based on user preferences
                ContentLabelManager(
                    labels: labels,
                    contentType: "video"
                ) {
                    if let playerView = ModernVideoPlayerView(
                        bskyVideo: videoView,
                        postID: postID
                    ) {
                        playerView
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Unable to load video")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))

            case .unexpected:
                EmptyView()
            }

            //  show the record
            // Extract labels from the embedded record itself, not the parent post
            let embedLabels: [ComAtprotoLabelDefs.Label]? = {
                switch recordWithMediaView.record.record {
                case .appBskyEmbedRecordViewRecord(let viewRecord):
                    return viewRecord.labels
                default:
                    return nil
                }
            }()

            RecordEmbedView(
                record: recordWithMediaView.record.record,
                labels: embedLabels,
                path: $path
            )
        }
    }

    @ViewBuilder
    private func videoEmbed(_ videoView: AppBskyEmbedVideo.View) -> some View {
        // Always use ContentLabelManager for videos - it will handle show/warn/hide based on user preferences
        ContentLabelManager(
            labels: labels,
            contentType: "video"
        ) {
            if let playerView = ModernVideoPlayerView(
                bskyVideo: videoView,
                postID: postID
            ) {
                playerView
                    .frame(maxWidth: .infinity)
            } else {
                Text("Unable to load video")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: colorScheme))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }
    
    // MARK: - Helper Methods
    
    /// This method is deprecated - ContentLabelManager now handles all visibility logic
    private func hasAdultContentLabel(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        // Kept for backward compatibility, but ContentLabelManager should be used instead
        guard !appState.isAdultContentEnabled else { return false }
        return labels?.contains { label in
            let lowercasedValue = label.val.lowercased()
            return lowercasedValue == "porn" || lowercasedValue == "nsfw" || lowercasedValue == "nudity"
        } ?? false
    }
}
