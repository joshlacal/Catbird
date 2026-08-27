//
//  VideoFeedView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import AVFoundation
import Petrel
import SwiftUI

/// Dedicated edge-to-edge vertical video feed presenting full-screen playable video posts from the canonical 'thevids' generator.
public struct VideoFeedView: View {
  /// Canonical public Bluesky video feed generator URI
  public static let thevidsURI = "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.generator/thevids"

  public let feedURI: String
  @Binding public var path: NavigationPath

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var playerPool = VideoFeedPlayerPool()
  @State private var items: [VideoFeedItem] = []
  @State private var activeIndex: Int = 0
  @State private var cursor: String? = nil
  @State private var isLoading: Bool = false
  @State private var isInitialLoading: Bool = true
  @State private var hasMore: Bool = true
  @State private var errorMessage: String? = nil
  @State private var revealedItemIDs: Set<String> = []

  public init(feedURI: String = VideoFeedView.thevidsURI, path: Binding<NavigationPath>? = nil) {
    self.feedURI = feedURI
    self._path = path ?? .constant(NavigationPath())
  }
  public var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if isInitialLoading {
        VStack(spacing: 16) {
          ProgressView()
            .tint(.white)
          Text("Loading Video Feed…")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        }
      } else if let error = errorMessage, items.isEmpty {
        VStack(spacing: 16) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.white.opacity(0.8))

          Text(error)
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)

          Button {
            Task {
              await loadInitialFeed()
            }
          } label: {
            Text("Retry")
              .fontWeight(.semibold)
              .padding(.horizontal, 24)
              .padding(.vertical, 10)
              .background(.white.opacity(0.2))
              .clipShape(Capsule())
          }
          .tint(.white)
        }
      } else if items.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "video.slash")
            .font(.largeTitle)
            .foregroundStyle(.white.opacity(0.6))
          Text("No videos found")
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.8))
        }
      } else {
        // Vertical paging feed
        GeometryReader { proxy in
          TabView(selection: $activeIndex) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
              VideoFeedItemView(
                item: item,
                index: index,
                isActive: index == activeIndex,
                isRevealed: revealedItemIDs.contains(item.id),
                playerPool: playerPool,
                onReveal: {
                  revealItem(at: index)
                },
                onProfileTap: { did in
                  path.append(NavigationDestination.profile(did))
                },
                onPostTap: { uri in
                  path.append(NavigationDestination.post(uri))
                }
              )
              .frame(width: proxy.size.width, height: proxy.size.height)
              .rotationEffect(.degrees(-90))
              .tag(index)
            }
          }
          .frame(width: proxy.size.height, height: proxy.size.width)
          .rotationEffect(.degrees(90), anchor: .topLeading)
          .offset(x: proxy.size.width)
          .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .ignoresSafeArea()
      }

      // Top floating navigation overlay
      VStack {
        HStack(alignment: .center) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "chevron.left")
              .font(.system(size: 18, weight: .bold))
              .foregroundStyle(.white)
              .padding(10)
              .background(.black.opacity(0.4))
              .clipShape(Circle())
          }
          .accessibilityLabel("Back")

          Spacer()

          Text("The Vids")
            .font(.headline)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .shadow(radius: 4)

          Spacer()

          Button {
            playerPool.toggleMute()
          } label: {
            Image(systemName: playerPool.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(.white)
              .padding(10)
              .background(.black.opacity(0.4))
              .clipShape(Circle())
          }
          .accessibilityLabel(playerPool.isMuted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)

        Spacer()
      }
    }
    .navigationBarBackButtonHidden(true)
    .toolbar(.hidden, for: .navigationBar)
    .task {
      if items.isEmpty {
        await loadInitialFeed()
      } else {
        updatePlaybackForActiveIndex(activeIndex)
      }
    }
    .onAppear {
      if !items.isEmpty {
        updatePlaybackForActiveIndex(activeIndex)
      }
    }
    .onChange(of: activeIndex) { _, newIndex in
      handleActiveIndexChange(newIndex)
    }
    .onDisappear {
      playerPool.cleanup()
    }
  }

  private func loadInitialFeed() async {
    isInitialLoading = true
    errorMessage = nil

    guard let client = appState.atProtoClient else {
      errorMessage = "Client unavailable"
      isInitialLoading = false
      return
    }

    let feedManager = FeedManager(client: client)

    do {
      guard let uri = try? ATProtocolURI(uriString: feedURI) else {
        errorMessage = "Invalid feed URI: \(feedURI)"
        isInitialLoading = false
        return
      }

      let (feedPosts, nextCursor) = try await feedManager.fetchFeed(
        fetchType: .feed(uri),
        cursor: nil
      )

      let parsedItems = extractVideoItems(from: feedPosts)
      self.items = parsedItems
      self.cursor = nextCursor
      self.hasMore = nextCursor != nil && !feedPosts.isEmpty
      self.isInitialLoading = false

      if !parsedItems.isEmpty {
        self.activeIndex = 0
        updatePlaybackForActiveIndex(0)
      }
    } catch {
      self.errorMessage = error.localizedDescription
      self.isInitialLoading = false
    }
  }

  private func loadNextPage() async {
    guard !isLoading, hasMore, let currentCursor = cursor else { return }
    isLoading = true

    guard let client = appState.atProtoClient else {
      isLoading = false
      return
    }

    let feedManager = FeedManager(client: client)

    do {
      guard let uri = try? ATProtocolURI(uriString: feedURI) else {
        isLoading = false
        return
      }

      let (feedPosts, nextCursor) = try await feedManager.fetchFeed(
        fetchType: .feed(uri),
        cursor: currentCursor
      )

      let newItems = extractVideoItems(from: feedPosts)
      // Append only items not already in the feed
      let existingIDs = Set(items.map(\.id))
      let uniqueNewItems = newItems.filter { !existingIDs.contains($0.id) }

      self.items.append(contentsOf: uniqueNewItems)
      self.cursor = nextCursor
      self.hasMore = nextCursor != nil && !feedPosts.isEmpty
      self.isLoading = false

      // Update prewarming with newly appended items
      updatePrewarming(for: activeIndex)
    } catch {
      self.isLoading = false
    }
  }

  private func extractVideoItems(from feedPosts: [AppBskyFeedDefs.FeedViewPost]) -> [VideoFeedItem] {
    feedPosts.compactMap { feedPost in
      let post = feedPost.post
      guard let embed = post.embed else { return nil }

      if case .appBskyEmbedVideoView(let videoView) = embed,
         let playlistURL = videoView.playlist.url {
        return VideoFeedItem(
          id: post.uri.uriString(),
          post: post,
          videoView: videoView,
          playlistURL: playlistURL
        )
      }
      return nil
    }
  }

  private func handleActiveIndexChange(_ newIndex: Int) {
    guard items.indices.contains(newIndex) else { return }
    updatePlaybackForActiveIndex(newIndex)

    // Load next page when reaching near the end
    if newIndex >= items.count - 3 {
      Task {
        await loadNextPage()
      }
    }
  }

  private func isItemEligibleForPlayback(_ item: VideoFeedItem) -> Bool {
    if revealedItemIDs.contains(item.id) {
      return true
    }
    if case .knownType(let record) = item.post.record,
       let postRecord = record as? AppBskyFeedPost,
       let postLabels = postRecord.labels,
       case .comAtprotoLabelDefsSelfLabels(let selfLabels) = postLabels {
      let hasSelfWarning = selfLabels.values.contains {
        ContentLabels.contentWarningLabels.contains($0.val.lowercased())
      }
      if hasSelfWarning {
        return false
      }
    }
    let visibility = ContentLabelManager<AnyView>.getInitialContentVisibility(labels: item.post.labels)
    return visibility == .show
  }

  private func revealItem(at index: Int) {
    guard items.indices.contains(index) else { return }
    let item = items[index]
    revealedItemIDs.insert(item.id)
    if index == activeIndex {
      updatePlaybackForActiveIndex(index)
    } else {
      updatePrewarming(for: activeIndex)
    }
  }

  private func updatePlaybackForActiveIndex(_ index: Int) {
    guard items.indices.contains(index) else { return }
    updatePrewarming(for: index)
    if isItemEligibleForPlayback(items[index]) {
      playerPool.play(feedIndex: index)
    } else {
      playerPool.pauseAll()
    }
  }

  private func updatePrewarming(for index: Int) {
    let prewarmTargets = items.enumerated().compactMap { (offset, element) -> (index: Int, url: URL)? in
      guard isItemEligibleForPlayback(element) else { return nil }
      return (index: offset, url: element.playlistURL)
    }
    playerPool.prewarm(activeIndex: index, items: prewarmTargets)
  }
}

// MARK: - Video Feed Models

public struct VideoFeedItem: Identifiable, Hashable, Sendable {
  public let id: String
  public let post: AppBskyFeedDefs.PostView
  public let videoView: AppBskyEmbedVideo.View
  public let playlistURL: URL

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }

  public static func == (lhs: VideoFeedItem, rhs: VideoFeedItem) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - Single Video Item View

private struct VideoFeedItemView: View {
  let item: VideoFeedItem
  let index: Int
  let isActive: Bool
  let isRevealed: Bool
  let playerPool: VideoFeedPlayerPool
  let onReveal: () -> Void
  let onProfileTap: (String) -> Void
  let onPostTap: (ATProtocolURI) -> Void
  @Environment(AppState.self) private var appState

  private var postText: String {
    if case .knownType(let record) = item.post.record,
       let postRecord = record as? AppBskyFeedPost {
      return postRecord.text
    }
    return ""
  }
  private var selfLabelValues: [String]? {
    guard case .knownType(let record) = item.post.record,
          let postRecord = record as? AppBskyFeedPost,
          let postLabels = postRecord.labels else {
      return nil
    }
    switch postLabels {
    case .comAtprotoLabelDefsSelfLabels(let selfLabels):
      return selfLabels.values.map { $0.val.lowercased() }
    default:
      return nil
    }
  }


  var body: some View {
    ZStack(alignment: .bottom) {
      // Background Player Layer wrapped in ContentLabelManager
      ContentLabelManager(
        labels: isRevealed ? nil : item.post.labels,
        selfLabelValues: isRevealed ? nil : selfLabelValues,
        contentType: "video"
      ) {
        ZStack {
          PlayerLayerView(
            player: playerPool.player(for: index),
            gravity: .resizeAspectFill,
            shouldLoop: true
          )
          .ignoresSafeArea()
          .onAppear {
            onReveal()
          }
          // Play/Pause tap overlay
          Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
              playerPool.togglePlayPause()
            }

          // Center paused icon indicator
          if isActive && !playerPool.isPlaying {
            Image(systemName: "play.fill")
              .font(.system(size: 54))
              .foregroundStyle(.white.opacity(0.85))
              .shadow(radius: 8)
              .allowsHitTesting(false)
          }
        }
      }
      .ignoresSafeArea()

      // Gradient shadow overlay for legibility
      LinearGradient(
        colors: [.clear, .black.opacity(0.3), .black.opacity(0.75)],
        startPoint: .center,
        endPoint: .bottom
      )
      .ignoresSafeArea()
      .allowsHitTesting(false)

      // Post details & Scrubber
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .bottom, spacing: 12) {
          // Bottom-left: Author and post content
          VStack(alignment: .leading, spacing: 8) {
            // Author info
            Button {
              onProfileTap(item.post.author.did.didString())
            } label: {
              HStack(spacing: 8) {
                AvatarView(
                  did: item.post.author.did.didString(),
                  client: appState.atProtoClient,
                  size: 38
                )

                VStack(alignment: .leading, spacing: 1) {
                  Text(item.post.author.displayName ?? item.post.author.handle.description)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                  Text("@\(item.post.author.handle)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                }
              }
            }
            .buttonStyle(.plain)

            // Post text
            if !postText.isEmpty {
              Button {
                onPostTap(item.post.uri)
              } label: {
                Text(postText)
                  .font(.subheadline)
                  .foregroundStyle(.white)
                  .lineLimit(3)
                  .multilineTextAlignment(.leading)
              }
              .buttonStyle(.plain)
            }
          }

          Spacer()

          // Bottom-right: Actions (Thread, Likes, Reposts)
          VStack(spacing: 16) {
            // Open Thread
            Button {
              onPostTap(item.post.uri)
            } label: {
              VStack(spacing: 4) {
                Image(systemName: "bubble.right.fill")
                  .font(.system(size: 22))
                  .foregroundStyle(.white)
                if let count = item.post.replyCount, count > 0 {
                  Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                }
              }
            }
            .buttonStyle(.plain)

            // Likes
            VStack(spacing: 4) {
              Image(systemName: "heart.fill")
                .font(.system(size: 22))
                .foregroundStyle(item.post.viewer?.like != nil ? .red : .white)
              if let count = item.post.likeCount, count > 0 {
                Text("\(count)")
                  .font(.caption2)
                  .fontWeight(.semibold)
                  .foregroundStyle(.white)
              }
            }

            // Reposts
            VStack(spacing: 4) {
              Image(systemName: "arrow.2.squarepath")
                .font(.system(size: 22))
                .foregroundStyle(item.post.viewer?.repost != nil ? .green : .white)
              if let count = item.post.repostCount, count > 0 {
                Text("\(count)")
                  .font(.caption2)
                  .fontWeight(.semibold)
                  .foregroundStyle(.white)
              }
            }
          }
          .padding(.bottom, 6)
        }
        .padding(.horizontal, 16)

        // Progress Scrubber Bar
        if isActive {
          VideoProgressBar(
            currentTime: playerPool.currentTime,
            duration: playerPool.duration,
            bufferedTime: playerPool.bufferedTime,
            onSeek: { seconds in
              playerPool.seek(to: seconds, at: index)
            }
          )
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
        } else {
          Rectangle()
            .fill(Color.clear)
            .frame(height: 20)
            .padding(.bottom, 24)
        }
      }
    }
  }
}
