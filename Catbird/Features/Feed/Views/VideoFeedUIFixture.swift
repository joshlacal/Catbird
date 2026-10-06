import SwiftUI

#if DEBUG
/// Account-free rendering fixture. It uses the production pager, header, footer,
/// actions, and scrubber with local state; it never creates an AppState or client.
struct VideoFeedUIFixture: View {
  @State private var selection: Int? = 0
  @State private var isMuted = true
  @State private var path: [VideoFeedFixtureDestination] = []
  private let pages = [
    VideoFeedFixtureItem(id: 0, title: "Portrait", aspectRatio: 9.0 / 16.0, color: .indigo),
    VideoFeedFixtureItem(id: 1, title: "Landscape", aspectRatio: 16.0 / 9.0, color: .orange),
    VideoFeedFixtureItem(id: 2, title: "Square", aspectRatio: 1, color: .teal)
  ]

  var body: some View {
    TabView {
      Tab("Home", systemImage: "house") {
        NavigationStack(path: $path) {
          ZStack {
            Color.black.ignoresSafeArea()
            VideoFeedPager(items: pages, selection: $selection) { item, size in
              VideoFeedFixturePage(
                item: item, pageSize: size, isActive: selection == item.id,
                onComments: { path.append(.thread) }, onProfile: { path.append(.profile) }
              )
            }
          }
          .safeAreaInset(edge: .top, spacing: 0) {
            VideoFeedNavigationControls(isMuted: isMuted, onBack: {}, onMute: { isMuted.toggle() })
          }
          .modifier(VideoFeedNavigationModifier())
          .navigationDestination(for: VideoFeedFixtureDestination.self) { destination in
            switch destination {
            case .thread:
              Text("Fixture thread comments").accessibilityIdentifier("videoFixtureThread")
            case .profile:
              Text("Fixture author profile").accessibilityIdentifier("videoFixtureProfile")
            }
          }
        }
      }
      Tab("Notifications", systemImage: "bell") { Text("Local notification fixture") }
      Tab("Messages", systemImage: "bubble.left.and.bubble.right") { Text("Local messages fixture") }
      Tab("Search", systemImage: "magnifyingglass", role: .search) {
        NavigationStack {
          Text("Local search fixture")
            .searchable(text: .constant(""))
        }
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .modifier(VideoFeedFixtureInheritedEdges())
    .environment(\.dynamicTypeSize,
      ProcessInfo.processInfo.arguments.contains("--video-fixture-accessibility") ? .accessibility3 : .large)
  }
}

private struct VideoFeedFixtureInheritedEdges: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, macOS 26.0, *) {
      content.scrollEdgeEffectStyle(.soft, for: .all)
    } else {
      content
    }
  }
}

private struct VideoFeedFixtureItem: Identifiable {
  let id: Int
  let title: String
  let aspectRatio: CGFloat
  let color: Color
}

private struct VideoFeedFixturePage: View {
  let item: VideoFeedFixtureItem
  let pageSize: CGSize
  let isActive: Bool
  let onComments: () -> Void
  let onProfile: () -> Void
  @State private var coordinator = VideoFeedActionCoordinator()
  @State private var isLiked = false
  @State private var isReposted = false
  @State private var currentTime = 15.0
  @State private var playbackState: VideoFeedPlayerPool.PlaybackState =
    ProcessInfo.processInfo.arguments.contains("--video-fixture-fail-playback") ? .failed : .paused

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black
      Rectangle()
        .fill(item.color.gradient)
        .aspectRatio(item.aspectRatio, contentMode: .fit)
        .overlay(alignment: .top) {
          Text("\(item.title) fixture \(item.id + 1)")
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(8)
            .accessibilityIdentifier("videoFixturePage\(item.id)")
        }
        .frame(maxHeight: .infinity)
      Button {
        playbackState = playbackState == .playing ? .paused : .playing
      } label: {
        Color.clear.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(playbackState == .failed || playbackState == .loading)
      .accessibilityLabel(playbackState == .playing ? "Pause video" : "Play video")
      LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        .allowsHitTesting(false)
      VideoFeedPageOverlays(
        status: {
          if isActive {
            VideoFeedPlaybackStatus(state: playbackState) { playbackState = .playing }
          }
        },
        footer: { footer }
      )
    }
    .clipped()
    .onChange(of: isActive) { _, active in if !active { coordinator.cancel() } }
    .onDisappear { coordinator.cancel() }
    .alert("Action unsuccessful", isPresented: Binding(
      get: { coordinator.errorMessage != nil },
      set: { if !$0 { coordinator.errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { coordinator.errorMessage = nil }
    } message: {
      Text(coordinator.errorMessage ?? "")
    }
  }

  private var footer: some View {
    VideoFeedOverlayControls(
      pageSize: pageSize,
      hasCaption: true,
      author: { compact in
        Button(action: onProfile) {
          HStack(spacing: 8) {
            Circle().fill(.white.opacity(0.6)).frame(width: 38, height: 38)
            VStack(alignment: .leading) {
              Text("An author with a long display name").font(.subheadline.bold()).lineLimit(1)
              if !compact { Text("@local.fixture").font(.caption2).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("videoFixtureAuthor")
      },
      caption: { lines in
        Button(action: onComments) {
          Text("A long caption checks wrapping, larger text, and narrow or resized video pages.")
            .font(.subheadline)
            .lineLimit(lines)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      },
      actions: { horizontal in
        VideoFeedReactionControls(
          horizontal: horizontal,
          isLiked: isLiked,
          isReposted: isReposted,
          replyCount: 12,
          likeCount: isLiked ? 124 : 123,
          repostCount: isReposted ? 5 : 4,
          canAct: isActive && !coordinator.isBusy,
          onComments: onComments,
          onLike: { performFixtureAction { isLiked.toggle() } },
          onRepost: { performFixtureAction { isReposted.toggle() } }
        )
      },
      progress: {
        VideoProgressBar(currentTime: currentTime, duration: 60, bufferedTime: 45) { currentTime = $0 }
          .accessibilityIdentifier("videoProgress")
      }
    )
  }

  private func performFixtureAction(_ action: @escaping @MainActor () -> Void) {
    coordinator.perform {
      let slow = ProcessInfo.processInfo.arguments.contains("--video-fixture-slow-actions")
      try await Task.sleep(for: .milliseconds(slow ? 2_000 : 180))
      if ProcessInfo.processInfo.arguments.contains("--video-fixture-fail-actions") {
        throw VideoFeedFixtureFailure.rejected
      }
      action()
    }
  }
}

private enum VideoFeedFixtureDestination: Hashable { case thread, profile }

private enum VideoFeedFixtureFailure: Error { case rejected }
#endif
