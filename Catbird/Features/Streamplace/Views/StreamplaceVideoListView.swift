import Petrel
import SwiftUI

struct StreamplaceVideoListView: View {
  let userDID: String
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @State private var service: StreamplaceService?
  @State private var selectedVideo: StreamplaceService.VideoRecord?
  @Namespace private var videoTransition

  var body: some View {
    Group {
      if let service {
        if service.isLoading && service.videos.isEmpty {
          ProgressView("Loading videos...")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if service.videos.isEmpty {
          emptyState
        } else {
          videoList(service: service)
        }
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .navigationTitle("Streamplace Videos")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task {
      guard service == nil, let client = appState.atProtoClient else { return }
    
      let svc = StreamplaceService(client: client)
      service = svc
      await svc.loadVideos(forDID: userDID)
    }
    .refreshable {
      guard let service else { return }
      service.reset()
      await service.loadVideos(forDID: userDID)
    }
    #if os(iOS)
    .fullScreenCover(item: $selectedVideo) { video in
      StreamplaceVideoPlayerView(video: video)
        .if_iOS18 { view in
          view.navigationTransition(.zoom(sourceID: video.id, in: videoTransition))
        }
    }
    #else
    .sheet(item: $selectedVideo) { video in
      StreamplaceVideoPlayerView(video: video)
    }
    #endif
  }

  @ViewBuilder
  private func videoList(service: StreamplaceService) -> some View {
    List {
      ForEach(service.videos) { video in
        StreamplaceVideoCard(video: video, thumbnail: service.thumbnails[video.id])
          .contentShape(Rectangle())
          .onTapGesture {
            selectedVideo = video
          }
          .if_iOS18 { view in
            view.matchedTransitionSource(id: video.id, in: videoTransition)
          }
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .onAppear {
            if video == service.videos.last && service.hasMore && !service.isLoading {
              Task { await service.loadVideos(forDID: userDID) }
            }
          }
      }

      if service.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding()
      }
    }
    .listStyle(.plain)
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "play.rectangle.fill")
        .font(.system(size: 48))
        .foregroundColor(.secondary)
      Text("No Videos")
        .appFont(AppTextRole.title3)
        .fontWeight(.semibold)
      Text("This user hasn't published any videos yet.")
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal)
      Spacer()
    }
    .frame(maxWidth: .infinity, minHeight: 300)
  }
}

// MARK: - iOS 18 conditional modifier

private extension View {
  @ViewBuilder
  func if_iOS18<Content: View>(@ViewBuilder transform: (Self) -> Content) -> some View {
    if #available(iOS 18.0, *) {
      transform(self)
    } else {
      self
    }
  }
}
