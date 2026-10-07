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

/// Disable media navigation while leaving its enclosing moderation gate usable.
struct ReadOnlyPostMediaModifier: ViewModifier {
  @Environment(\.isReadOnlyPostPreview) private var isReadOnly

  func body(content: Content) -> some View {
    content
      .allowsHitTesting(!isReadOnly)
      .disabled(isReadOnly)
  }
}

/// A discovery preview never instantiates a player or starts autoplay.
struct PostVideoEmbedContent: View {
  let video: AppBskyEmbedVideo.View
  let postID: String
  @Environment(\.isReadOnlyPostPreview) private var isReadOnly

  private var aspectRatio: CGFloat {
    guard let ratio = video.aspectRatio, ratio.width > 0, ratio.height > 0 else { return 16.0 / 9.0 }
    return min(max(CGFloat(ratio.width) / CGFloat(ratio.height), 0.75), 2)
  }

  var body: some View {
    if isReadOnly {
      Group {
        if let thumbnail = video.thumbnail?.url {
          VideoThumbnailView(thumbnailURL: thumbnail, aspectRatio: aspectRatio)
        } else {
          Rectangle().fill(Color.secondary.opacity(0.12))
            .aspectRatio(aspectRatio, contentMode: .fit)
        }
      }
      .overlay(alignment: .bottomLeading) {
        Label("Video preview", systemImage: "video")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.white)
          .padding(8)
          .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
          .padding(8)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(video.alt.flatMap { $0.isEmpty ? nil : $0 } ?? "Video preview")
    } else if let player = ModernVideoPlayerView(bskyVideo: video, postID: postID) {
      player.frame(maxWidth: .infinity)
    } else {
      Text("Unable to load video")
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
    }
  }
}

/// Uses supplied link metadata in discovery; never loads a third-party player.
struct PostExternalEmbedContent: View {
  let external: AppBskyEmbedExternal.ViewExternal
  let postID: String
  @Environment(\.isReadOnlyPostPreview) private var isReadOnly

  var body: some View {
    if isReadOnly {
      ExternalEmbedLabelGate(labels: external.labels) {
        VStack(alignment: .leading, spacing: 8) {
          if let thumbnail = external.thumb?.url {
            LazyImage(url: thumbnail) { state in
              if let image = state.image {
                image.resizable().scaledToFill()
              } else {
                Color.secondary.opacity(0.12)
              }
            }
            .pipeline(ImageLoadingManager.shared.pipeline)
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipped()
            .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 6) {
            if !external.title.isEmpty {
              Text(external.title).appFont(AppTextRole.headline)
            }
            if !external.description.isEmpty {
              Text(external.description)
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            }
            if let host = external.uri.url?.host {
              Label(host, systemImage: "link")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(12)
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
      }
    } else {
      ExternalEmbedView(external: external, shouldBlur: false, postID: postID)
    }
  }
}

/// A unified component for displaying different types of post embeds.
struct PostEmbed: View {
    // MARK: - Properties
    let embed: AppBskyFeedDefs.PostViewEmbedUnion
    let labels: [ComAtprotoLabelDefs.Label]?
    @Binding var path: NavigationPath
    var visibilityContext: PostVisibilityContext = .public
    var authorDID: DID? = nil
    @ObservationIgnored
    @Environment(AppState.self) private var appState
    @Environment(\.appSettings) private var appSettings
    @Environment(\.adultContentEnabled) private var adultContentEnabled
    @Environment(\.themeManager) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.postID) private var postID

    init(
        embed: AppBskyFeedDefs.PostViewEmbedUnion,
        labels: [ComAtprotoLabelDefs.Label]?,
        path: Binding<NavigationPath>,
        visibilityContext: PostVisibilityContext = .public,
        authorDID: DID? = nil
    ) {
        self.embed = embed
        self.labels = labels
        self._path = path
        self.visibilityContext = visibilityContext
        self.authorDID = authorDID
    }
    // MARK: - Constants
    private static let cornerRadius: CGFloat = 10
    private static let spacing: CGFloat = 8
    
    // MARK: - Body
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch embed {
            case .appBskyEmbedImagesView(let imagesView):
                imageEmbed(imagesView)

            case .appBskyEmbedGalleryView(let galleryView):
                galleryEmbed(galleryView)

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
            .modifier(ReadOnlyPostMediaModifier())
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private func galleryEmbed(_ galleryView: AppBskyEmbedGallery.View) -> some View {
        ContentLabelManager(
            labels: labels,
            contentType: "image"
        ) {
            GalleryEmbedView(
                gallery: galleryView,
                shouldBlur: false, // We're handling blur at the ContentLabelManager level now
                visibilityContext: visibilityContext,
                authorDID: authorDID
            )
            .modifier(ReadOnlyPostMediaModifier())
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    @ViewBuilder
    private func externalEmbed(_ externalView: AppBskyEmbedExternal.View) -> some View {
        ContentLabelManager(
            labels: labels,
            contentType: "link"
        ) {
            PostExternalEmbedContent(
                external: externalView.external,
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
                    .modifier(ReadOnlyPostMediaModifier())
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))

            case .appBskyEmbedGalleryView(let galleryView):
                ContentLabelManager(
                    labels: labels,
                    contentType: "image"
                ) {
                    GalleryEmbedView(
                        gallery: galleryView,
                        shouldBlur: false, // We're handling blur at the ContentLabelManager level now
                        visibilityContext: visibilityContext,
                        authorDID: authorDID
                    )
                    .modifier(ReadOnlyPostMediaModifier())
                }
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            case .appBskyEmbedExternalView(let externalView):
                ContentLabelManager(
                    labels: labels,
                    contentType: "link"
                ) {
                    PostExternalEmbedContent(
                        external: externalView.external,
                        postID: postID
                    )
                }

            case .appBskyEmbedVideoView(let videoView):
                // Always use ContentLabelManager for videos - it will handle show/warn/hide based on user preferences
                ContentLabelManager(
                    labels: labels,
                    contentType: "video"
                ) {
                    PostVideoEmbedContent(video: videoView, postID: postID)
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
            PostVideoEmbedContent(video: videoView, postID: postID)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
    }

    // MARK: - Helper Methods
    
    /// This method is deprecated - ContentLabelManager now handles all visibility logic
    private func hasAdultContentLabel(_ labels: [ComAtprotoLabelDefs.Label]?) -> Bool {
        // Kept for backward compatibility, but ContentLabelManager should be used instead
        guard !adultContentEnabled else { return false }
        return labels?.contains { label in
            let lowercasedValue = label.val.lowercased()
            return lowercasedValue == "porn" || lowercasedValue == "nsfw" || lowercasedValue == "nudity"
        } ?? false
    }
}

#Preview("Post Embed") {
  AsyncPreviewContent { appState in
    PostEmbedPreviewLoader(appState: appState)
  }
}

private struct PostEmbedPreviewLoader: View {
  let appState: AppState
  @State private var data: (post: AppBskyFeedDefs.PostView, embed: AppBskyFeedDefs.PostViewEmbedUnion)?

  var body: some View {
    Group {
      if let data {
        PostEmbed(
          embed: data.embed,
          labels: data.post.labels,
          path: .constant(NavigationPath()),
          authorDID: data.post.author.did
        )
        .environment(\.postID, data.post.cid.string)
        .padding()
      } else {
        ProgressView("Loading embed…")
      }
    }
    .task {
      data = await PreviewData.firstPostWithEmbed(from: appState)
    }
  }
}
