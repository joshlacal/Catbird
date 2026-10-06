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
  /// Clears the search field and returns to Discovery.
  let onReset: () -> Void
  @Environment(AppState.self) private var appState
  private let baseUnit: CGFloat = 3

  init(
    viewModel: RefinedSearchViewModel,
    path: Binding<NavigationPath>,
    selectedContentType: Binding<ContentType>,
    onReset: @escaping () -> Void
  ) {
    self.viewModel = viewModel
    self._path = path
    self._selectedContentType = selectedContentType
    self.onReset = onReset
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
    .task(id: appState.userDID) { await appState.feedLibraryActions.refresh() }
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
      if viewModel.isSearchInFlight && viewModel.postResults.isEmpty {
        loadingResultsSection
      } else if viewModel.postResults.isEmpty {
        Section { emptyResultsView(for: selectedContentType) }
      } else {
        postSection
        loadMoreSectionIfNeeded(cursor: viewModel.postCursor)
      }
    }
  }

  private var loadingResultsSection: some View {
    Section {
      LoadingRowsView(count: 5)
        .redacted(reason: .placeholder)
        .mainContentFrame()
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .accessibilityLabel("Loading results")
    }
  }

  @ViewBuilder
  private var detectedLanguagesAdmonitionSection: some View {
    // Offering the languages the user already reads is noise; only suggest other languages.
    let readerLanguages = Set(
      (appState.appSettings.contentLanguages + [Locale.current.language.languageCode?.identifier ?? ""])
        .map(Self.baseLanguageCode)
        .filter { !$0.isEmpty }
    )
    let unselected = DetectedQueryLanguagesAdmonition.unselectedLanguages(
      from: viewModel.detectedQueryLanguages,
      selectedLanguage: viewModel.filterState.language
    )
    .filter { !readerLanguages.contains(Self.baseLanguageCode($0)) }
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
      if viewModel.isSearchInFlight && viewModel.profileResults.isEmpty {
        loadingResultsSection
      } else if viewModel.profileResults.isEmpty {
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
      if viewModel.isSearchInFlight && viewModel.feedResults.isEmpty {
        loadingResultsSection
      } else if viewModel.feedResults.isEmpty {
        Section { emptyResultsView(for: .feeds) }
      } else {
        feedSection
        loadMoreSectionIfNeeded(cursor: viewModel.feedCursor)
      }
    }
  }

  private var feedSection: some View {
    Section(header: Text("Feeds")) {
      ForEach(viewModel.feedResults, id: \.uri) { feed in
        VStack(spacing: 0) {
          FeedDiscoveryHeaderView(
            feed: feed,
            onTap: { path.append(NavigationDestination.feed(feed.uri)) }
          )
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
        .onAppear {
          if feed == viewModel.feedResults.last {
            triggerLoadMoreIfNeeded()
          }
        }
      }
    }
  }

  // MARK: - Starter Pack Results Section (G01)

  private var starterPackResultsSection: some View {
    Group {
      if viewModel.isSearchInFlight && viewModel.starterPackResults.isEmpty {
        loadingResultsSection
      } else if viewModel.starterPackResults.isEmpty {
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
            Text("Loading more results…")
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
            Text("Loading…")
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

      Text(emptyResultsTitle(for: type))
        .appFont(AppTextRole.headline)

      Text(hasActiveFilters ? "Try removing some filters." : "Try a different search term or check your spelling.")
        .appFont(AppTextRole.subheadline)
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)

      if hasActiveFilters {
        Button {
          clearFilters()
        } label: {
          Text("Clear Filters")
            .appFont(AppTextRole.subheadline)
            .foregroundColor(.white)
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(
              Capsule()
                .fill(Color.accentColor)
            )
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
      } else {
        Button {
          onReset()
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
        .buttonStyle(.plain)
        .padding(.top, 8)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  private func emptyResultsTitle(for type: ContentType) -> String {
    switch type {
    case .top, .latest: return "No Posts Found"
    case .people: return "No People Found"
    case .feeds: return "No Feeds Found"
    case .starterPacks: return "No Starter Packs Found"
    }
  }

  /// Filters only apply to post results, so they only explain an empty Top or Latest list.
  private var hasActiveFilters: Bool {
    (selectedContentType == .top || selectedContentType == .latest)
      && viewModel.filterState.activeFilterCount > 0
  }

  private func clearFilters() {
    guard let client = appState.atProtoClient else { return }
    viewModel.applyFilterState(SearchFilterState(sort: viewModel.filterState.sort), client: client)
  }

  private static func baseLanguageCode(_ code: String) -> String {
    let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? normalized
  }

  // MARK: - Helper Methods

  private func retrySearch() async {
    guard let client = appState.atProtoClient else { return }
    viewModel.searchError = nil
    viewModel.loadMoreError = nil
    await viewModel.refreshSearch(client: client)
  }
}
