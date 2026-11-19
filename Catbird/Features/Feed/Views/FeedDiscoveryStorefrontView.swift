import Petrel
import SwiftUI

/// App Store-style Storefront for discovering ATProto feeds:
/// 3-row horizontal paging carousels, dynamic zero-maintenance shelves
/// (Popular on Bluesky, Liked by People You Follow, By Catbird, By Category),
/// first-class search returning compact instant-add rows, and a bridge to Scene Explorer.
struct FeedDiscoveryStorefrontView: View {
  @Environment(AppState.self) private var appState
  @Bindable var storefront: FeedStorefrontViewModel
  @Bindable var searchModel: FeedDiscoveryViewModel

  let onSelectFeed: (AppBskyFeedDefs.GeneratorView) -> Void
  let onSeeAllShelf: (FeedShelfDestination) -> Void
  let onOpenFeed: (AppBskyFeedDefs.GeneratorView) -> Void
  let onOpenSceneExplorer: () -> Void

  private var isSearching: Bool {
    !searchModel.normalizedQuery.isEmpty
  }

  var body: some View {
    Group {
      if isSearching {
        searchResultsBody
      } else {
        storefrontBody
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(platformColor: .platformSystemBackground))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("feed.discovery.storefront")
    .searchable(text: $searchModel.query, prompt: "Search feeds")
    .onSubmit(of: .search) { searchModel.submit() }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") {
          if isSearching { searchModel.refresh() } else { storefront.refresh() }
        }
        .disabled(isSearching
          ? (searchModel.isInitialLoading || searchModel.isRefreshing)
          : (storefront.isInitialLoading || storefront.isRefreshing))
      }
    }
  }

  private var storefrontBody: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 24) {
        if let error = appState.feedLibraryActions.refreshError {
          FeedDiscoveryRetryView(message: error) {
            Task { await appState.feedLibraryActions.refresh() }
          }
          .padding(.horizontal, 16)
        }

        categoryFilterStrip

        if let selectedCategory = storefront.selectedCategory {
          selectedCategorySection(selectedCategory)
        } else {
          allShelvesContent
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 84)
    }
    .scrollDismissesKeyboard(.interactively)
    .refreshable { storefront.refresh() }
  }

  private var categoryFilterStrip: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        categoryPill(title: "All", symbol: "sparkles", isSelected: storefront.selectedCategory == nil) {
          withAnimation(.snappy(duration: 0.2)) { storefront.selectedCategory = nil }
        }
        .accessibilityIdentifier("feed.storefront.category.all")

        ForEach(FeedDiscoveryCategory.allCases) { category in
          let selected = storefront.selectedCategory == category
          categoryPill(title: category.shortTitle, symbol: category.symbolName, isSelected: selected) {
            withAnimation(.snappy(duration: 0.2)) {
              storefront.selectedCategory = selected ? nil : category
            }
            if !selected { storefront.loadCategoryIfNeeded(category) }
          }
          .accessibilityIdentifier("feed.storefront.category.\(category.id)")
        }
      }
      .padding(.horizontal, 16)
    }
    .scrollIndicators(.hidden)
  }

  private func categoryPill(
    title: String,
    symbol: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 5) {
        Image(systemName: symbol)
          .font(.caption.weight(.semibold))
        Text(title)
          .appFont(AppTextRole.subheadline)
          .fontWeight(isSelected ? .semibold : .regular)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .foregroundStyle(isSelected ? Color.white : Color.primary)
      .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  @ViewBuilder
  private var allShelvesContent: some View {
    if storefront.isInitialLoading && storefront.popularFeeds.isEmpty {
      ProgressView("Loading feeds…")
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    } else if let error = storefront.initialError, storefront.popularFeeds.isEmpty {
      FeedDiscoveryRetryView(message: error) { storefront.refresh() }
        .padding(.horizontal, 16)
    } else {
      if let error = storefront.refreshError {
        FeedDiscoveryRetryView(message: error) { storefront.refresh() }
          .padding(.horizontal, 16)
      }

      popularShelf
      followLikedShelf
      catbirdShelf
      categoryShelves
      sceneExplorerCalloutCard
        .padding(.horizontal, 16)
    }
  }

  @ViewBuilder
  private var popularShelf: some View {
    if !storefront.popularFeeds.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        FeedShelfHeader(
          title: "Popular on Bluesky",
          subtitle: "Top community feeds right now",
          onSeeAll: { onSeeAllShelf(.popular) }
        )
        FeedStorefrontCarousel(
          items: Array(storefront.popularFeeds.prefix(18)),
          rowsPerColumn: 3,
          feedForItem: { $0 },
          onSelect: onSelectFeed,
          onOpen: onOpenFeed
        )
      }
      .accessibilityIdentifier("feed.storefront.shelf.popular")
    }
  }

  @ViewBuilder
  private var followLikedShelf: some View {
    if !storefront.followLikedFeeds.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        FeedShelfHeader(
          title: storefront.followLikedShelfTitle,
          subtitle: storefront.followLikedShelfSubtitle,
          onSeeAll: storefront.followLikedFeeds.count > 6 ? { onSeeAllShelf(.followLiked) } : nil
        )
        FeedStorefrontCarousel(
          items: Array(storefront.followLikedFeeds.prefix(15)),
          rowsPerColumn: 3,
          feedForItem: \.feed,
          subtitleForItem: \.socialProofSubtitle,
          onSelect: onSelectFeed,
          onOpen: onOpenFeed
        )
      }
      .accessibilityIdentifier("feed.storefront.shelf.followLiked")
    } else if storefront.isLoadingFollowLiked {
      VStack(alignment: .leading, spacing: 10) {
        FeedShelfHeader(
          title: "Liked by People You Follow",
          subtitle: "Checking feeds across your network…"
        )
        ProgressView()
          .controlSize(.small)
          .padding(.horizontal, 16)
      }
    }
  }

  @ViewBuilder
  private var catbirdShelf: some View {
    if !storefront.catbirdFeeds.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        FeedShelfHeader(
          title: "Made by Catbird",
          subtitle: "First-party feeds tuned for discovery"
        )
        FeedStorefrontCarousel(
          items: storefront.catbirdFeeds,
          rowsPerColumn: 3,
          feedForItem: { $0 },
          onSelect: onSelectFeed,
          onOpen: onOpenFeed
        )
      }
      .accessibilityIdentifier("feed.storefront.shelf.catbird")
    }
  }
}

extension FeedDiscoveryStorefrontView {
  private var categoryShelves: some View {
    ForEach(storefront.populatedCategories) { category in
      let categoryFeeds = storefront.feeds(for: category)
      if !categoryFeeds.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          FeedShelfHeader(
            title: category.title,
            onSeeAll: {
              storefront.loadCategoryIfNeeded(category)
              onSeeAllShelf(.category(category))
            }
          )
          FeedStorefrontCarousel(
            items: Array(categoryFeeds.prefix(12)),
            rowsPerColumn: 3,
            feedForItem: { $0 },
            onSelect: onSelectFeed,
            onOpen: onOpenFeed
          )
        }
        .accessibilityIdentifier("feed.storefront.shelf.category.\(category.id)")
      }
    }
  }

  private func selectedCategorySection(_ category: FeedDiscoveryCategory) -> some View {
    let feeds = storefront.feeds(for: category)
    return VStack(alignment: .leading, spacing: 12) {
      FeedShelfHeader(
        title: category.title,
        subtitle: "Tap any feed for live posts and posting pace"
      )
      if feeds.isEmpty && storefront.isLoading(category: category) {
        ProgressView("Loading \(category.title)…")
          .frame(maxWidth: .infinity)
          .padding(.vertical, 48)
      } else if feeds.isEmpty {
        ContentUnavailableView(
          "No \(category.title) feeds yet",
          systemImage: category.symbolName,
          description: Text("Try searching directly or pick another category.")
        )
        .padding(.vertical, 24)
      } else {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
            FeedStorefrontRow(
              feed: feed,
              onSelect: { onSelectFeed(feed) },
              onOpen: { onOpenFeed(feed) }
            )
            .padding(.horizontal, 16)
            if index < feeds.count - 1 { Divider().padding(.leading, 74) }
          }
        }
        if storefront.isLoading(category: category) {
          ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
        } else if storefront.categoryCursors[category] != nil {
          Button("Load More \(category.shortTitle) Feeds") {
            storefront.loadCategoryIfNeeded(category, loadMore: true)
          }
          .buttonStyle(.bordered)
          .frame(maxWidth: .infinity, minHeight: 44)
          .padding(.horizontal, 16)
        }
      }
    }
  }

  private var sceneExplorerCalloutCard: some View {
    Button(action: onOpenSceneExplorer) {
      HStack(spacing: 14) {
        Image(systemName: "sparkles")
          .font(.title2.weight(.semibold))
          .foregroundStyle(Color.accentColor)
          .frame(width: 46, height: 46)
          .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        VStack(alignment: .leading, spacing: 3) {
          Text("Explore Scenes with Catbird Intelligence")
            .appFont(AppTextRole.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
          Text("Map 1,000+ live communities, duel your taste, and build a balanced lineup.")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(14)
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("feed.storefront.openSceneExplorer")
  }
}

extension FeedDiscoveryStorefrontView {
  fileprivate var searchResultsBody: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if searchModel.isInitialLoading {
          ProgressView("Searching feeds…")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 64)
        } else if let error = searchModel.initialError, searchModel.items.isEmpty {
          FeedDiscoveryRetryView(message: error) { searchModel.retry() }
            .padding(16)
        } else if searchModel.items.isEmpty {
          ContentUnavailableView {
            Label("No matching feeds", systemImage: "magnifyingglass")
          } description: {
            Text("No feeds found for “\(searchModel.resultQuery.isEmpty ? searchModel.normalizedQuery : searchModel.resultQuery)”.")
          } actions: {
            Button("Back to Storefront") { searchModel.query = "" }
              .buttonStyle(.bordered)
              .frame(minHeight: 44)
          }
          .padding(.vertical, 48)
        } else {
          if searchModel.isRefreshing {
            ProgressView("Updating results…")
              .controlSize(.small)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 8)
          }
          if let error = searchModel.refreshError {
            FeedDiscoveryRetryView(message: error) { searchModel.retry() }
              .padding(16)
          }
          ForEach(Array(searchModel.items.enumerated()), id: \.element.id) { index, feed in
            FeedStorefrontRow(
              feed: feed,
              onSelect: { onSelectFeed(feed) },
              onOpen: { onOpenFeed(feed) }
            )
            .padding(.horizontal, 16)
            if index < searchModel.items.count - 1 { Divider().padding(.leading, 74) }
          }
          searchPagingFooter.padding(16)
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .accessibilityIdentifier("feed.discovery.searchResults")
  }

  @ViewBuilder
  private var searchPagingFooter: some View {
    if let error = searchModel.pagingError {
      FeedDiscoveryRetryView(message: error) { searchModel.loadMore() }
    } else if searchModel.isLoadingMore {
      ProgressView("Loading more feeds…").frame(maxWidth: .infinity)
    } else if searchModel.cursor != nil {
      Button("Load More Feeds") { searchModel.loadMore() }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(searchModel.isRefreshing || searchModel.normalizedQuery != searchModel.resultQuery)
    }
  }
}
