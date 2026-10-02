import SwiftData
import SwiftUI

struct ProfileCachedPostsList: View {
    let feedKey: String
    let contentMaxWidth: CGFloat
    let isLoadingMore: Bool
    let loadMore: @MainActor () async -> Void
    @Binding var path: NavigationPath

    @Query private var cached: [CachedFeedViewPost]

    init(
        feedKey: String,
        contentMaxWidth: CGFloat,
        isLoadingMore: Bool,
        loadMore: @escaping @MainActor () async -> Void,
        path: Binding<NavigationPath>
    ) {
        self.feedKey = feedKey
        self.contentMaxWidth = contentMaxWidth
        self.isLoadingMore = isLoadingMore
        self.loadMore = loadMore
        _path = path
        _cached = Query(
            filter: #Predicate<CachedFeedViewPost> { post in
                post.feedType == feedKey
            }
        )
    }

    private var sortedCached: [CachedFeedViewPost] {
        cached.sorted { lhs, rhs in
            if let lhsOrder = lhs.feedOrder, let rhsOrder = rhs.feedOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.feedOrder != nil {
                return true
            }
            if rhs.feedOrder != nil {
                return false
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var body: some View {
        Group {
            ForEach(sortedCached) { cachedPost in
                VStack(spacing: 0) {
                    EnhancedFeedPost(
                        cachedPost: cachedPost,
                        path: $path
                    )
                    .frame(maxWidth: contentMaxWidth, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .center)

                    Divider()
                        .padding(.top, 8)
                }
                .contentShape(Rectangle())
                .onAppear {
                    if cachedPost == sortedCached.last && !isLoadingMore {
                        Task { await loadMore() }
                    }
                }
            }

            if isLoadingMore {
                ProgressView()
                    .padding()
                    .frame(maxWidth: contentMaxWidth, alignment: .center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}
