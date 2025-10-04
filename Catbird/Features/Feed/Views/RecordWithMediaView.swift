import SwiftUI
import Petrel
import NukeUI

struct RecordWithMediaView: View {
    let recordWithMedia: AppBskyEmbedRecordWithMedia.View
    let postID: String
    let labels: [ComAtprotoLabelDefs.Label]?
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Media content first
            mediaContent
                .layoutPriority(1)
            
            // Then the record embed
            // Extract labels from the embedded record itself, not the parent post
            let embedLabels: [ComAtprotoLabelDefs.Label]? = {
                switch recordWithMedia.record.record {
                case .appBskyEmbedRecordViewRecord(let viewRecord):
                    return viewRecord.labels
                default:
                    return nil
                }
            }()

            RecordEmbedView(record: recordWithMedia.record.record, labels: embedLabels, path: $path)
                .layoutPriority(1)
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private var mediaContent: some View {
        switch recordWithMedia.media {
        case .appBskyEmbedImagesView(let imageView):
            ContentLabelManager(
                labels: labels,
                contentType: "image"
            ) {
                ViewImageGridView(
                    viewImages: imageView.images,
                    shouldBlur: false // ContentLabelManager handles blur decisions
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
        case .appBskyEmbedExternalView(let externalView):
            ContentLabelManager(
                labels: labels,
                contentType: "link"
            ) {
                ExternalEmbedView(
                    external: externalView.external,
                    shouldBlur: false, // ContentLabelManager handles blur decisions
                    postID: postID
                )
            }
            
        case .appBskyEmbedVideoView(let video):
            ContentLabelManager(
                labels: labels,
                contentType: "video"
            ) {
                if let playerView = ModernVideoPlayerView(
                    bskyVideo: video,
                    postID: postID
                ) {
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
