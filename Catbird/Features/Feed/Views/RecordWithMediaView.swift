import SwiftUI
import Petrel
import NukeUI

/// A quote with media: the media part gated by the parent's `contentMedia`
/// decision, then the quoted record, which moderates itself.
struct RecordWithMediaView: View {
    let recordWithMedia: AppBskyEmbedRecordWithMedia.View
    let postID: String
    /// The parent post's `ui(.contentMedia)`.
    let mediaModeration: ModerationUI
    @Binding var path: NavigationPath

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mediaContent
                .layoutPriority(1)

            RecordEmbedView(record: recordWithMedia.record.record, path: $path)
                .layoutPriority(1)
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var mediaContent: some View {
        switch recordWithMedia.media {
        case .appBskyEmbedImagesView(let imageView):
            ModerationMediaGate(ui: mediaModeration) {
                ViewImageGridView(viewImages: imageView.images, shouldBlur: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .appBskyEmbedGalleryView(let galleryView):
            ModerationMediaGate(ui: mediaModeration) {
                GalleryEmbedView(gallery: galleryView, shouldBlur: false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .appBskyEmbedExternalView(let externalView):
            ModerationMediaGate(ui: mediaModeration) {
                ExternalEmbedView(external: externalView.external, shouldBlur: false, postID: postID)
            }

        case .appBskyEmbedVideoView(let video):
            ModerationMediaGate(ui: mediaModeration) {
                if let playerView = ModernVideoPlayerView(bskyVideo: video, postID: postID) {
                    playerView
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Unable to load video")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

        case .unexpected:
            EmptyView()
        }
    }
}
