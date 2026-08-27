//
//  ResultsView.swift
//  Catbird
//
//  Created on 3/9/25.
//  Updated for WS-A G01 Segmentation (Top, Latest, People, Feeds, Starter Packs).
//

import NukeUI
import Petrel
import SwiftUI

/// View displaying segmented search results (G01).
struct ResultsView: View {
  var viewModel: RefinedSearchViewModel
  @Binding var path: NavigationPath
  @Binding var selectedContentType: ContentType
  @Environment(AppState.self) private var appState
  @State private var subscriptionStatus: [String: Bool] = [:]
  private let baseUnit: CGFloat = 3

  init(
    viewModel: RefinedSearchViewModel,
    path: Binding<NavigationPath>,
    selectedContentType: Binding<ContentType>
  ) {
    self.viewModel = viewModel
    self._path = path
    self._selectedContentType = selectedContentType
  }

  public var body: some View {
    List {
      if let error = viewModel.searchError {
        Section {
          SearchErrorView(
            error: error,
            query: viewModel.searchQuery,
            retryAction: {
              Task { await retrySearch() }
            }
          )
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      } else {
        switch selectedContentType {
        case .top, .latest:
          postResultsSection
        case .people:
          profileResultsSection
        case .feeds:
          feedResultsSection
        case .starterPacks:
          starterPackResultsSection
        }
      }
    }
    .listStyle(.plain)
    .refreshable {
      if let client = appState.atProtoClient {
        await viewModel.refreshSearch(client: client)
      }
    }
  }

  // MARK: - Post Results Section (Top / Latest)

  private var postResultsSection: some View {
    Group {
      detectedLanguagesAdmonitionSection
      if viewModel.postResults.isEmpty {
        Section { emptyResultsView(for: selectedContentType) }
      } else {
        postSection
        loadMoreSectionIfNeeded(cursor: viewModel.postCursor)
      }
    }
  }

  @ViewBuilder
  private var detectedLanguagesAdmonitionSection: some View {
    let unselected = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: viewModel.detectedQueryLanguages,
      selectedLanguage: viewModel.filterState.language
    )
    if !unselected.isEmpty {
      Section {
        DetectedQueryLanguagesAdmonition(
          detectedLanguages: unselected,
          onSelectLanguage: { langCode in
            if let client = appState.atProtoClient {
              viewModel.selectDetectedLanguage(langCode, client: client)
            }
          }
        )
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
      }
    }
  }

  private var postSection: some View {
    Section(header: Text(selectedContentType == .top ? "Top Posts" : "Latest Posts")) {
      ForEach(viewModel.postResults, id: \.uri) { post in
        Button { path.append(NavigationDestination.post(post.uri)) } label: {
          VStack(spacing: 0) {
            PostView(
              post: post,
              grandparentAuthor: nil,
              isParentPost: false,
              isSelectable: false,
              path: $path,
              appState: appState
            )
            .mainContentFrame()
            .padding(.horizontal, baseUnit * 1.5)
            .padding(.top, baseUnit * 3)

            if post != viewModel.postResults.last {
              Rectangle()
                .fill(Color.separator)
                .frame(height: 0.5)
                .platformIgnoresSafeArea(.container, edges: .horizontal)
            }
          }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .onAppear {
          if post == viewModel.postResults.last {
            triggerLoadMoreIfNeeded()
          }
        }
        .task {
          if let lastIndex = viewModel.postResults.firstIndex(where: { $0.uri == post.uri }),
             lastIndex >= viewModel.postResults.count - 3 {
            triggerLoadMoreIfNeeded()
          }
        }
      }
    }
  }

  // MARK: - Profile Results Section (People)

  private var profileResultsSection: some View {
    Group {
      if viewModel.profileResults.isEmpty {
        Section { emptyResultsView(for: .people) }
      } else {
        profileSection
        loadMoreSectionIfNeeded(cursor: viewModel.profileCursor)
      }
    }
  }

  private var profileSection: some View {
    Section(header: Text("People")) {
      ForEach(viewModel.profileResults, id: \.did) { profile in
        Button { path.append(NavigationDestination.profile(profile.did.didString())) } label: {
          VStack(spacing: 0) {
            ProfileRowView(profile: profile, path: $path)
              .mainContentFrame()
              .padding(.horizontal, baseUnit * 1.5)
              .padding(.top, baseUnit * 3)

            if profile != viewModel.profileResults.last {
              Rectangle()
                .fill(Color.separator)
                .frame(height: 0.5)
                .platformIgnoresSafeArea(.container, edges: .horizontal)
            }
          }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .onAppear {
          if profile == viewModel.profileResults.last {
            triggerLoadMoreIfNeeded()
          }
        }
        .task {
          if let lastIndex = viewModel.profileResults.firstIndex(where: { $0.did == profile.did }),
             lastIndex >= viewModel.profileResults.count - 3 {
            triggerLoadMoreIfNeeded()
          }
        }
      }
    }
  }

  // MARK: - Feed Results Section

  private var feedResultsSection: some View {
    Group {
      if viewModel.feedResults.isEmpty {
        Section { emptyResultsView(for: .feeds) }
      } else {
        feedSection
      }
    }
  }

  private var feedSection: some View {
    Section(header: Text("Feeds")) {
      ForEach(viewModel.feedResults, id: \.uri) { feed in
        VStack(spacing: 0) {
          FeedDiscoveryHeaderView(
            feed: feed,
            isSubscribed: subscriptionStatus[feed.uri.uriString()] ?? false,
            onSubscriptionToggle: {
              await toggleFeedSubscription(feed)
              await updateSubscriptionStatus(for: feed.uri)
            },
            onTap: { path.append(NavigationDestination.feed(feed.uri)) }
          )
          .task { await updateSubscriptionStatus(for: feed.uri) }
          .mainContentFrame()
          .padding(.horizontal, baseUnit * 1.5)
          .padding(.top, baseUnit * 3)

          if feed != viewModel.feedResults.last {
            Rectangle()
              .fill(Color.separator)
              .frame(height: 0.5)
              .platformIgnoresSafeArea(.container, edges: .horizontal)
          }
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
      }
    }
  }

  // MARK: - Starter Pack Results Section (G01)

  private var starterPackResultsSection: some View {
    Group {
      if viewModel.starterPackResults.isEmpty {
        Section { emptyResultsView(for: .starterPacks) }
      } else {
        starterPackSection
        loadMoreSectionIfNeeded(cursor: viewModel.starterPackCursor)
      }
    }
  }

  private var starterPackSection: some View {
    Section(header: Text("Starter Packs")) {
      ForEach(viewModel.starterPackResults, id: \.uri) { pack in
        Button {
          path.append(NavigationDestination.starterPack(pack.uri))
        } label: {
          VStack(spacing: 0) {
            StarterPackRowView(pack: pack)
              .mainContentFrame()
              .padding(.horizontal, baseUnit * 1.5)
              .padding(.top, baseUnit * 3)

            if pack != viewModel.starterPackResults.last {
              Rectangle()
                .fill(Color.separator)
                .frame(height: 0.5)
                .platformIgnoresSafeArea(.container, edges: .horizontal)
            }
          }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .onAppear {
          if pack == viewModel.starterPackResults.last {
            triggerLoadMoreIfNeeded()
          }
        }
        .task {
          if let lastIndex = viewModel.starterPackResults.firstIndex(where: { $0.uri == pack.uri }),
             lastIndex >= viewModel.starterPackResults.count - 3 {
            triggerLoadMoreIfNeeded()
          }
        }
      }
    }
  }

  // MARK: - Pagination Indicator

  @ViewBuilder
  private func loadMoreSectionIfNeeded(cursor: String?) -> some View {
    if viewModel.loadMoreError != nil {
      Section {
        VStack(spacing: 8) {
          Text("Failed to load more results")
            .appFont(AppTextRole.subheadline.weight(.medium))
            .foregroundColor(.secondary)
          Button {
            triggerLoadMoreIfNeeded()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: "arrow.counterclockwise")
              Text("Retry")
            }
            .appFont(AppTextRole.caption.weight(.medium))
            .foregroundColor(.accentColor)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(
              Capsule()
                .fill(Color.accentColor.opacity(0.12))
            )
          }
          .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
      }
    } else if cursor != nil && !viewModel.isLoadingMoreResults {
      Section {
        HStack {
          Spacer()
          VStack(spacing: 8) {
            ProgressView()
            Text("Loading more results...")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
        }
        .padding(.vertical, 16)
        .onAppear { triggerLoadMoreIfNeeded() }
        .listRowInsets(EdgeInsets())
      }
    } else if viewModel.isLoadingMoreResults {
      Section {
        HStack {
          Spacer()
          VStack(spacing: 8) {
            ProgressView()
            Text("Loading...")
              .appFont(AppTextRole.caption)
              .foregroundColor(.secondary)
          }
          Spacer()
        }
        .padding(.vertical, 16)
        .listRowInsets(EdgeInsets())
      }
    }
  }

  private func triggerLoadMoreIfNeeded() {
    guard !viewModel.isLoadingMoreResults, let client = appState.atProtoClient else { return }
    Task { await viewModel.loadMoreResults(client: client) }
  }

  // MARK: - Empty State

  private func emptyResultsView(for type: ContentType) -> some View {
    VStack(spacing: 16) {
      Image(systemName: type.emptyIcon)
        .appFont(size: 48)
        .foregroundColor(.secondary)
        .padding(.bottom, 8)
        .symbolEffect(.pulse, options: .repeating)

      Text("No \(type.title.lowercased()) found")
        .appFont(AppTextRole.headline)

      Text("Try a different search term or check your spelling")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      Button {
        viewModel.resetSearch()
      } label: {
        Text("Explore Trending Content")
          .appFont(AppTextRole.subheadline)
          .foregroundColor(.white)
          .padding(.vertical, 8)
          .padding(.horizontal, 16)
          .background(
            Capsule()
              .fill(Color.accentColor)
          )
      }
      .padding(.top, 8)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  // MARK: - Helper Methods

  private func isSubscribedToFeed(_ feedURI: ATProtocolURI) async -> Bool {
    let feedURIString = feedURI.uriString()
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      let pinnedFeeds = preferences.pinnedFeeds
      let savedFeeds = preferences.savedFeeds
      return pinnedFeeds.contains(feedURIString) || savedFeeds.contains(feedURIString)
    } catch {
      return false
    }
  }

  private func toggleFeedSubscription(_ feed: AppBskyFeedDefs.GeneratorView) async {
    let feedURIString = feed.uri.uriString()
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      if await isSubscribedToFeed(feed.uri) {
        await MainActor.run {
          preferences.removeFeed(feedURIString)
        }
        try await appState.preferencesManager.saveAndSyncPreferences(preferences)
      } else {
        await MainActor.run {
          preferences.addFeed(feedURIString, pinned: false)
        }
        try await appState.preferencesManager.saveAndSyncPreferences(preferences)
      }
    } catch {
      // Handle error silently
    }
  }

  private func updateSubscriptionStatus(for feedURI: ATProtocolURI) async {
    let status = await isSubscribedToFeed(feedURI)
    await MainActor.run {
      subscriptionStatus[feedURI.uriString()] = status
    }
  }

  private func retrySearch() async {
    guard let client = appState.atProtoClient else { return }
    viewModel.searchError = nil
    viewModel.loadMoreError = nil
    await viewModel.refreshSearch(client: client)
  }
}
