import SwiftUI
import Petrel
import NukeUI

struct RecordWithMediaView: View {
    let recordWithMedia: AppBskyEmbedRecordWithMedia.View
    let postID: String
    let labels: [ComAtprotoLabelDefs.Label]?
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    private var shouldBlur: Bool {
        guard !appState.isAdultContentEnabled else { return false }
        return labels?.contains { label in
            let lowercasedValue = label.val.lowercased()
            return lowercasedValue == "porn" || lowercasedValue == "nsfw" || lowercasedValue == "nudity"
        } ?? false
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Media content first
            mediaContent
                .layoutPriority(1)
            
            // Then the record embed
            RecordEmbedView(record: recordWithMedia.record.record, labels: labels, path: $path)
                .layoutPriority(1)
        }
        // Use fixed sizing to prevent layout jumps
        .fixedSize(horizontal: false, vertical: true)
    }
    
    @ViewBuilder
    private var mediaContent: some View {
        switch recordWithMedia.media {
        case .appBskyEmbedImagesView(let imageView):
            ViewImageGridView(viewImages: imageView.images, shouldBlur: shouldBlur)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            
        case .appBskyEmbedExternalView(let externalView):
            ExternalEmbedView(external: externalView.external, shouldBlur: shouldBlur, postID: postID)
            
        case .appBskyEmbedVideoView(let video):
            if let url = video.playlist.url {
//                ModernVideoPlayerView(
//                    url: url,
//                    aspectRatio: video.aspectRatio.map { CGFloat($0.width) / CGFloat($0.height) } ?? 16/9
//                )
                ModernVideoPlayerView18(bskyVideo: video, postID: postID)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            
        case .unexpected:
            EmptyView()
        }
    }
}
