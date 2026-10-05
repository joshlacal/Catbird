//
//  TopicFeedView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import OSLog
import Petrel
import SwiftUI

/// Screen for viewing posts associated with a specific topic (queried via searchPostsV2).
public struct TopicFeedView: View {
  public let topic: String
  @Binding var path: NavigationPath
  @Environment(AppState.self) private var appState

  public enum Tab: String, CaseIterable, Identifiable {
    case top = "Top"
    case latest = "Latest"

    public var id: String { rawValue }
    var sortKey: String {
      switch self {
      case .top: return "top"
      case .latest: return "latest"
      }
    }
  }

  @State private var selectedTab: Tab = .top
  @State private var topTabState = TopicTabState(sort: "top")
  @State private var latestTabState = TopicTabState(sort: "latest")

  init(topic: String, path: Binding<NavigationPath>) {
    self.topic = topic
    self._path = path
  }

  private var shareURL: URL {
    let encodedTopic = topic.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? topic
    return URL(string: "https://bsky.app/topic/\(encodedTopic)") ?? URL(string: "https://bsky.app")!
  }

  public var body: some View {
    VStack(spacing: 0) {
      Picker("Sort", selection: $selectedTab) {
        ForEach(Tab.allCases) { tab in
          Text(tab.rawValue).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal)
      .padding(.vertical, 8)

      ZStack {
        // Top tab
        TopicTabContentView(
          topic: topic,
          state: topTabState,
          path: $path,
          appState: appState
        )
        .opacity(selectedTab == .top ? 1 : 0)
        .allowsHitTesting(selectedTab == .top)

        // Latest tab
        TopicTabContentView(
          topic: topic,
          state: latestTabState,
          path: $path,
          appState: appState
        )
        .opacity(selectedTab == .latest ? 1 : 0)
        .allowsHitTesting(selectedTab == .latest)
      }
    }
    .navigationTitle(topic)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        ShareLink(item: shareURL)
      }
    }
    .task {
      if !topTabState.hasLoadedInitial {
        await topTabState.loadInitial(topic: topic, appState: appState)
      }
      if !latestTabState.hasLoadedInitial {
        await latestTabState.loadInitial(topic: topic, appState: appState)
      }
    }
  }
}

// MARK: - Tab Content View

private struct TopicTabContentView: View {
  let topic: String
  @Bindable var state: TopicTabState
  @Binding var path: NavigationPath
  let appState: AppState

  var body: some View {
    Group {
      if state.isLoading && state.posts.isEmpty {
        VStack {
          Spacer()
          ProgressView()
            .scaleEffect(1.3)
          Spacer()
        }
      } else if let error = state.errorMessage, state.posts.isEmpty {
        VStack(spacing: 16) {
          Spacer()
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
          Text(error)
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
          Button("Try Again") {
            Task {
              await state.refresh(topic: topic, appState: appState)
            }
          }
          .buttonStyle(.borderedProminent)
          Spacer()
        }
      } else if state.posts.isEmpty && state.hasLoadedInitial {
        VStack(spacing: 12) {
          Spacer()
          Image(systemName: "text.bubble")
            .font(.system(size: 44))
            .foregroundStyle(.secondary)
          Text("No posts found for “\(topic)”")
            .appFont(AppTextRole.headline)
            .foregroundStyle(.primary)
          Text("Try checking back later or explore other topics.")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
          Spacer()
        }
      } else {
        List {
          if let error = state.errorMessage {
            HStack {
              Text(error)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("Try Again") {
                Task {
                  await state.loadMore(topic: topic, appState: appState)
                }
              }
              .appFont(AppTextRole.caption)
            }
            .listRowSeparator(.hidden)
          }

          ForEach(state.posts, id: \.uri) { post in
            NavigationLink(value: NavigationDestination.post(post.uri)) {
              PostView(
                post: post,
                grandparentAuthor: nil,
                isParentPost: false,
                isSelectable: true,
                path: $path,
                appState: appState
              )
              .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .onAppear {
              if post.uri == state.posts.last?.uri, state.cursor != nil, !state.isLoadingMore {
                Task {
                  await state.loadMore(topic: topic, appState: appState)
                }
              }
            }
          }

          if state.isLoadingMore {
            HStack {
              Spacer()
              ProgressView()
                .padding(.vertical, 8)
              Spacer()
            }
            .listRowSeparator(.hidden)
          }
        }
        .listStyle(.plain)
        .refreshable {
          await state.refresh(topic: topic, appState: appState)
        }
      }
    }
  }
}

// MARK: - Tab State Model

@MainActor
@Observable
final class TopicTabState {
  let sort: String
  var posts: [AppBskyFeedDefs.PostView] = []
  var cursor: String? = nil
  var isLoading: Bool = false
  var isLoadingMore: Bool = false
  var errorMessage: String? = nil
  var hasLoadedInitial: Bool = false

  @ObservationIgnored private let contentFilterService = ContentFilterService()
  @ObservationIgnored private let logger = Logger(subsystem: "blue.catbird", category: "TopicFeed")

  init(sort: String) {
    self.sort = sort
  }

  func loadInitial(topic: String, appState: AppState) async {
    guard !isLoading, !hasLoadedInitial else { return }
    isLoading = true
    errorMessage = nil

    if let page = await fetchPage(topic: topic, cursor: nil, appState: appState) {
      self.posts = page.posts
      self.cursor = page.cursor
      self.hasLoadedInitial = true
    }
    self.isLoading = false
  }

  func refresh(topic: String, appState: AppState) async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil

    if let page = await fetchPage(topic: topic, cursor: nil, appState: appState) {
      self.posts = page.posts
      self.cursor = page.cursor
      self.hasLoadedInitial = true
    }
    self.isLoading = false
  }

  func loadMore(topic: String, appState: AppState) async {
    guard let currentCursor = cursor, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    errorMessage = nil

    if let page = await fetchPage(topic: topic, cursor: currentCursor, appState: appState) {
      let existingURIs = Set(self.posts.map { $0.uri.uriString() })
      let newPosts = page.posts.filter { !existingURIs.contains($0.uri.uriString()) }
      self.posts.append(contentsOf: newPosts)
      self.cursor = page.cursor
    }
    self.isLoadingMore = false
  }

  /// Fetches one page and drops posts the viewer has muted, blocked or hidden, the
  /// same way search results are filtered. Sets `errorMessage` and returns nil on failure.
  private func fetchPage(
    topic: String, cursor: String?, appState: AppState
  ) async -> (posts: [AppBskyFeedDefs.PostView], cursor: String?)? {
    guard let client = appState.atProtoClient else {
      errorMessage = "Couldn’t load posts. Sign in again and try again."
      return nil
    }

    do {
      let (responseCode, data) = try await client.app.bsky.feed.searchPostsV2(
        input: .init(
          cursor: cursor,
          limit: 25,
          query: topic,
          sort: sort
        )
      )
      guard (200...299).contains(responseCode), let data else {
        logger.error("Topic search failed with status \(responseCode)")
        errorMessage = "Couldn’t load posts. Pull to try again."
        return nil
      }
      let settings = await appState.buildFilterSettings()
      let visible = await contentFilterService.filterPostViews(data.posts, settings: settings)
      return (visible, data.cursor)
    } catch {
      logger.error("Topic search failed: \(error.localizedDescription)")
      errorMessage = UserFacingError.message(for: error, action: "load posts")
      return nil
    }
  }
}
