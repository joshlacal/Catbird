import Petrel
import SwiftUI

/// Destination identifiers for "See All" vertical shelf views.
enum FeedShelfDestination: Hashable {
  case popular
  case followLiked
  case category(FeedDiscoveryCategory)

  var title: String {
    switch self {
    case .popular:
      String(localized: "Popular on Bluesky", comment: "Feed discovery shelf title for popular community feeds")
    case .followLiked:
      String(localized: "Liked by People You Follow", comment: "Feed discovery shelf title showing feeds liked by followed accounts")
    case .category(let category):
      category.title
    }
  }
}

/// Full vertical list pushed from any Storefront shelf's "See All" button.
struct FeedShelfListView: View {
  let destination: FeedShelfDestination
  @Bindable var storefront: FeedStorefrontViewModel
  let onSelectFeed: (AppBskyFeedDefs.GeneratorView) -> Void
  let onOpenFeed: (AppBskyFeedDefs.GeneratorView) -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        switch destination {
        case .popular:
          feedRows(storefront.popularFeeds)
          if let error = storefront.pagingError {
            FeedDiscoveryRetryView(message: error) { storefront.loadMorePopular() }
              .padding(16)
          } else if storefront.isLoadingMorePopular {
            ProgressView("Loading more feeds…")
              .frame(maxWidth: .infinity)
              .padding(16)
          } else if storefront.popularCursor != nil {
            Button("Load More Feeds") { storefront.loadMorePopular() }
              .buttonStyle(.catbird(.tonal, fullWidth: true))
              .padding(16)
          }

        case .followLiked:
          ForEach(Array(storefront.followLikedFeeds.enumerated()), id: \.element.id) { index, item in
            FeedStorefrontRow(
              feed: item.feed,
              customSubtitle: item.socialProofSubtitle,
              onSelect: { onSelectFeed(item.feed) },
              onOpen: { onOpenFeed(item.feed) }
            )
            .padding(.horizontal, 16)
            if index < storefront.followLikedFeeds.count - 1 {
              Divider()
                .padding(.leading, 74)
            }
          }

        case .category(let category):
          let feeds = storefront.feeds(for: category)
          feedRows(feeds)
          if storefront.isLoading(category: category) {
            ProgressView("Loading \(category.title)…")
              .frame(maxWidth: .infinity)
              .padding(16)
          } else if storefront.categoryCursors[category] != nil {
            Button("Load More \(category.shortTitle) Feeds") {
              storefront.loadCategoryIfNeeded(category, loadMore: true)
            }
            .buttonStyle(.catbird(.tonal, fullWidth: true))
            .padding(16)
          }
        }
      }
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .navigationTitle(destination == .followLiked ? storefront.followLikedShelfTitle : destination.title)
    .task {
      if case .category(let category) = destination {
        storefront.loadCategoryIfNeeded(category)
      }
    }
  }

  private func feedRows(_ feeds: [AppBskyFeedDefs.GeneratorView]) -> some View {
    ForEach(Array(feeds.enumerated()), id: \.element.id) { index, feed in
      FeedStorefrontRow(
        feed: feed,
        onSelect: { onSelectFeed(feed) },
        onOpen: { onOpenFeed(feed) }
      )
      .padding(.horizontal, 16)
      if index < feeds.count - 1 {
        Divider()
          .padding(.leading, 74)
      }
    }
  }
}
