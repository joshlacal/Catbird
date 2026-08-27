//
//  TopicFeedView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 8/24/26.
//

import Petrel
import SwiftUI

/// Screen for viewing posts associated with a specific topic (queried via searchPostsV2).
public struct TopicFeedView: View {
  public let topic: String
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

  public init(topic: String) {
    self.topic = topic
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
          appState: appState
        )
        .opacity(selectedTab == .top ? 1 : 0)
        .allowsHitTesting(selectedTab == .top)

        // Latest tab
        TopicTabContentView(
          topic: topic,
          state: latestTabState,
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
        await topTabState.loadInitial(topic: topic, client: appState.atProtoClient)
      }
      if !latestTabState.hasLoadedInitial {
        await latestTabState.loadInitial(topic: topic, client: appState.atProtoClient)
      }
    }
  }
}

// MARK: - Tab Content View

private struct TopicTabContentView: View {
  let topic: String
  @Bindable var state: TopicTabState
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
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
          Button("Retry") {
            Task {
              await state.refresh(topic: topic, client: appState.atProtoClient)
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
          Text("No posts found for \"\(topic)\"")
            .font(.headline)
            .foregroundStyle(.primary)
          Text("Try checking back later or explore other topics.")
            .font(.subheadline)
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
                .font(.caption)
                .foregroundStyle(.red)
              Spacer()
              Button("Retry") {
                Task {
                  await state.loadMore(topic: topic, client: appState.atProtoClient)
                }
              }
              .font(.caption.weight(.semibold))
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
                path: .constant(NavigationPath()),
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
                  await state.loadMore(topic: topic, client: appState.atProtoClient)
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
          await state.refresh(topic: topic, client: appState.atProtoClient)
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

  init(sort: String) {
    self.sort = sort
  }

  func loadInitial(topic: String, client: ATProtoClient?) async {
    guard !isLoading, !hasLoadedInitial else { return }
    isLoading = true
    errorMessage = nil

    guard let client else {
      errorMessage = "Client unavailable"
      isLoading = false
      return
    }

    do {
      let (responseCode, data) = try await client.app.bsky.feed.searchPostsV2(
        input: .init(
          limit: 25,
          query: topic,
          sort: sort
        )
      )
      guard (200...299).contains(responseCode), let data else {
        self.errorMessage = "Failed to load topic posts (HTTP \(responseCode))"
        self.isLoading = false
        return
      }
      self.posts = data.posts
      self.cursor = data.cursor
      self.hasLoadedInitial = true
    } catch {
      self.errorMessage = error.localizedDescription
    }
    self.isLoading = false
  }

  func refresh(topic: String, client: ATProtoClient?) async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil

    guard let client else {
      errorMessage = "Client unavailable"
      isLoading = false
      return
    }

    do {
      let (responseCode, data) = try await client.app.bsky.feed.searchPostsV2(
        input: .init(
          limit: 25,
          query: topic,
          sort: sort
        )
      )
      guard (200...299).contains(responseCode), let data else {
        self.errorMessage = "Failed to refresh topic posts (HTTP \(responseCode))"
        self.isLoading = false
        return
      }
      self.posts = data.posts
      self.cursor = data.cursor
      self.hasLoadedInitial = true
    } catch {
      self.errorMessage = error.localizedDescription
    }
    self.isLoading = false
  }

  func loadMore(topic: String, client: ATProtoClient?) async {
    guard let currentCursor = cursor, !isLoading, !isLoadingMore else { return }
    isLoadingMore = true
    errorMessage = nil

    guard let client else {
      errorMessage = "Client unavailable"
      isLoadingMore = false
      return
    }

    do {
      let (responseCode, data) = try await client.app.bsky.feed.searchPostsV2(
        input: .init(
          cursor: currentCursor,
          limit: 25,
          query: topic,
          sort: sort
        )
      )
      guard (200...299).contains(responseCode), let data else {
        self.errorMessage = "Failed to load more posts (HTTP \(responseCode))"
        self.isLoadingMore = false
        return
      }
      let existingURIs = Set(self.posts.map { $0.uri.uriString() })
      let newPosts = data.posts.filter { !existingURIs.contains($0.uri.uriString()) }
      self.posts.append(contentsOf: newPosts)
      self.cursor = data.cursor
    } catch {
      self.errorMessage = error.localizedDescription
    }
    self.isLoadingMore = false
  }
}
