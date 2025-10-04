//
//  ResultsView.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import NukeUI

/// View displaying search results
struct ResultsView: View {
    var viewModel: RefinedSearchViewModel
    @Binding var path: NavigationPath
    @Binding var selectedContentType: ContentType
    @Environment(AppState.self) private var appState
    @State private var subscriptionStatus: [String: Bool] = [:]
    private let baseUnit: CGFloat = 3 // Match EnhancedFeedPost spacing units
    
    var body: some View {
        List {
            if let error = viewModel.searchError {
                Section {
                    ErrorStateView(
                        error: error,
                        context: "Search failed",
                        retryAction: {
                            Task { await retrySearch() }
                        }
                    )
                    .listRowInsets(EdgeInsets())
                }
            } else {
                switch selectedContentType {
                case .all:
                    allResultsSections
                case .profiles:
                    profileResultsSection
                case .posts:
                    postResultsSection
                case .feeds:
                    feedResultsSection
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
    
    @ViewBuilder
    private var allResultsSections: some View {
        if viewModel.hasNoResults {
            Section {
                NoResultsView(
                    query: viewModel.searchQuery,
                    type: "results",
                    icon: "magnifyingglass",
                    message: "Try a different search term or check your spelling",
                    actionLabel: "Explore Trending Content",
                    action: { viewModel.resetSearch() }
                )
                .mainContentFrame()
                .listRowInsets(EdgeInsets())
            }
        } else {
            // All view shows preview sections only (no infinite scrolling)
            if !viewModel.profileResults.isEmpty { profileSection(limit: 3, showSeeAll: true) }
            if !viewModel.postResults.isEmpty { postSection(limit: 3, showSeeAll: true) }
            if !viewModel.feedResults.isEmpty { feedSection(limit: 3, showSeeAll: true) }
        }
    }

    private var profileResultsSection: some View {
        Group {
            if viewModel.profileResults.isEmpty {
                Section { emptyResultsView(for: .profiles) }
            } else {
                profileSection(limit: nil, showSeeAll: false)
                loadMoreSectionIfNeeded(cursor: viewModel.profileCursor)
            }
        }
    }

    private var postResultsSection: some View {
        Group {
            if viewModel.postResults.isEmpty {
                Section { emptyResultsView(for: .posts) }
            } else {
                postSection(limit: nil, showSeeAll: false)
                loadMoreSectionIfNeeded(cursor: viewModel.postCursor)
            }
        }
    }

    private var feedResultsSection: some View {
        Group {
            if viewModel.feedResults.isEmpty {
                Section { emptyResultsView(for: .feeds) }
            } else {
                feedSection(limit: nil, showSeeAll: false)
            }
        }
    }

    private func profileSection(limit: Int?, showSeeAll: Bool) -> some View {
        Section(header: Text("Profiles")) {
            let items = limit.map { Array(viewModel.profileResults.prefix($0)) } ?? viewModel.profileResults
            ForEach(items, id: \.did) { profile in
                Button { path.append(NavigationDestination.profile(profile.did.didString())) } label: {
                    VStack(spacing: 0) {
                        ProfileRowView(profile: profile, path: $path)
                            .mainContentFrame()
                            .padding(.horizontal, baseUnit * 1.5)
                            .padding(.top, baseUnit * 3)

                        if profile != items.last {
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
                    if limit == nil && profile == items.last {
                        triggerLoadMoreIfNeeded()
                    }
                }
                .task {
                    // More responsive infinite scrolling for profiles
                    if limit == nil, let lastIndex = items.firstIndex(where: { $0.did == profile.did }),
                       lastIndex >= items.count - 3 {
                        triggerLoadMoreIfNeeded()
                    }
                }
            }
            if showSeeAll, viewModel.profileResults.count > (limit ?? 0) {
                Button { selectedContentType = .profiles } label: {
                    Text("See all \(viewModel.profileResults.count) profiles")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func postSection(limit: Int?, showSeeAll: Bool) -> some View {
        Section(header: Text("Posts")) {
            let items = limit.map { Array(viewModel.postResults.prefix($0)) } ?? viewModel.postResults
            ForEach(items, id: \.uri) { post in
                Button { path.append(NavigationDestination.post(post.uri)) } label: {
                    VStack(spacing: 0) {
                        // Match EnhancedFeedPost outer sizing and padding via PostView + mainContentFrame
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

                        // Full-width divider beyond 600pt constraint
                        if post != items.last {
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
                    if limit == nil && post == items.last { 
                        triggerLoadMoreIfNeeded() 
                    }
                }
                .task {
                    // More responsive infinite scrolling - trigger when we're near the end
                    if limit == nil, let lastIndex = items.firstIndex(where: { $0.uri == post.uri }),
                       lastIndex >= items.count - 3 {
                        triggerLoadMoreIfNeeded()
                    }
                }
            }
            if showSeeAll, viewModel.postResults.count > (limit ?? 0) {
                Button { selectedContentType = .posts } label: {
                    Text("See all \(viewModel.postResults.count) posts")
                        .appFont(AppTextRole.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    private func feedSection(limit: Int?, showSeeAll: Bool) -> some View {
        Section(header: Text("Feeds")) {
            let items = limit.map { Array(viewModel.feedResults.prefix($0)) } ?? viewModel.feedResults
            ForEach(items, id: \.uri) { feed in
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        FeedDiscoveryHeaderView(
                            feed: feed,
                            isSubscribed: subscriptionStatus[feed.uri.uriString()] ?? false,
                            onSubscriptionToggle: {
                                await toggleFeedSubscription(feed)
                                await updateSubscriptionStatus(for: feed.uri)
                            }
                        )
                        .task { await updateSubscriptionStatus(for: feed.uri) }

                        // Make the entire card tappable to preview feed (bigger tap target)
                        EmptyView()
                    }
                    .mainContentFrame()
                    .padding(.horizontal, baseUnit * 1.5)
                    .padding(.top, baseUnit * 3)
                    .contentShape(Rectangle())
                    .onTapGesture { path.append(NavigationDestination.feed(feed.uri)) }

                    if feed != items.last {
                        Rectangle()
                            .fill(Color.separator)
                            .frame(height: 0.5)
                            .platformIgnoresSafeArea(.container, edges: .horizontal)
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
            }
            if showSeeAll, viewModel.feedResults.count > (limit ?? 0) {
                Button { selectedContentType = .feeds } label: {
                    Text("See all \(viewModel.feedResults.count) feeds")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    @ViewBuilder
    private func loadMoreSectionIfNeeded(cursor: String?) -> some View {
        if cursor != nil && !viewModel.isLoadingMoreResults {
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
    // Combined results view showing a mix of all content types
    private var allResultsView: some View {
        VStack(spacing: 16) {
            // Check if we have any results at all
            if viewModel.hasNoResults {
                NoResultsView(
                    query: viewModel.searchQuery,
                    type: "results",
                    icon: "magnifyingglass",
                    message: "Try a different search term or check your spelling",
                    actionLabel: "Explore Trending Content",
                    action: {
                        viewModel.resetSearch()
                    }
                )
            } else {
                // Profiles section (if any)
                if !viewModel.profileResults.isEmpty {
                    EnhancedResultsSection(
                        title: "Profiles",
                        icon: "person",
                        count: viewModel.profileResults.count
                    ) {
                        VStack(spacing: 0) {
                            ForEach(viewModel.profileResults.prefix(3), id: \.did) { profile in
                                Button {
                                    path.append(NavigationDestination.profile(profile.did.didString()))
                                } label: {
                                    ProfileRowView(profile: profile, path: $path)
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 16)
                                }
                                .buttonStyle(.plain)
                                
                                if profile != viewModel.profileResults.prefix(3).last {
                                    EnhancedDivider()
                                }
                            }
                            
                            if viewModel.profileResults.count > 3 {
                                Button {
                                    selectedContentType = .profiles
                                } label: {
                                    Text("See all \(viewModel.profileResults.count) profiles")
                                        .appFont(AppTextRole.subheadline)
                                        .foregroundColor(.accentColor)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Posts section (if any)
                if !viewModel.postResults.isEmpty {
                    EnhancedResultsSection(
                        title: "Posts",
                        icon: "text.bubble",
                        count: viewModel.postResults.count
                    ) {
                        VStack(spacing: 0) {
                            ForEach(viewModel.postResults.prefix(3), id: \.uri) { post in
                                Button {
                                    path.append(NavigationDestination.post(post.uri))
                                } label: {
                                    PostView(post: post, grandparentAuthor: nil, isParentPost: false, isSelectable: false, path: $path, appState: appState)
                                }
                                .buttonStyle(.plain)
                                
                                if post != viewModel.postResults.prefix(3).last {
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                            
                            if viewModel.postResults.count > 3 {
                                Button {
                                    selectedContentType = .posts
                                } label: {
                                    Text("See all \(viewModel.postResults.count) posts")
                                        .appFont(AppTextRole.subheadline)
                                        .foregroundColor(.accentColor)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Feeds section (if any)
                if !viewModel.feedResults.isEmpty {
                    EnhancedResultsSection(
                        title: "Feeds",
                        icon: "rectangle.on.rectangle.angled",
                        count: viewModel.feedResults.count
                    ) {
                        VStack(spacing: 12) {
                            ForEach(viewModel.feedResults.prefix(3), id: \.uri) { feed in
                                VStack(spacing: 8) {
                                    FeedDiscoveryHeaderView(
                                        feed: feed,
                                        isSubscribed: subscriptionStatus[feed.uri.uriString()] ?? false,
                                        onSubscriptionToggle: {
                                            await toggleFeedSubscription(feed)
                                            await updateSubscriptionStatus(for: feed.uri)
                                        }
                                    )
                                    .task {
                                        await updateSubscriptionStatus(for: feed.uri)
                                    }
                                    
                                    Button {
                                        path.append(NavigationDestination.feed(feed.uri))
                                    } label: {
                                        HStack {
                                            Text("Preview Feed")
                                                .appFont(AppTextRole.caption)
                                                .foregroundColor(.accentColor)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .appFont(AppTextRole.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 16)
                                        .background(Color.secondary.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                if feed != viewModel.feedResults.prefix(3).last {
                                    Divider()
                                }
                            }
                            
                            if viewModel.feedResults.count > 3 {
                                Button {
                                    selectedContentType = .feeds
                                } label: {
                                    Text("See all \(viewModel.feedResults.count) feeds")
                                        .appFont(AppTextRole.subheadline)
                                        .foregroundColor(.accentColor)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Starter Packs section (if any)
//                if !viewModel.starterPackResults.isEmpty {
//                    EnhancedResultsSection(
//                        title: "Starter Packs",
//                        icon: "person.3",
//                        count: viewModel.starterPackResults.count
//                    ) {
//                        VStack(spacing: 0) {
//                            ForEach(viewModel.starterPackResults.prefix(3), id: \.uri) { pack in
//                                Button {
//                                    path.append(NavigationDestination.starterPack(pack.uri))
//                                } label: {
//                                    StarterPackRowView(pack: pack)
//                                }
//                                .buttonStyle(.plain)
//                                
//                                if pack != viewModel.starterPackResults.prefix(3).last {
//                                    EnhancedDivider()
//                                }
//                            }
//                            
//                            if viewModel.starterPackResults.count > 3 {
//                                Button {
//                                    selectedContentType = .starterPacks
//                                } label: {
//                                    Text("See all \(viewModel.starterPackResults.count) starter packs")
//                                        .appFont(AppTextRole.subheadline)
//                                        .foregroundColor(.accentColor)
//                                        .padding(.vertical, 12)
//                                }
//                                .buttonStyle(.plain)
//                            }
//                        }
//                    }
//                }
            }
            
            // Spacer to ensure scroll area is large enough
            Spacer(minLength: 50)
        }
        .padding(.vertical, 8)
    }
    
    // Profiles-only results view
    private var profileResultsView: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.profileResults, id: \.did) { profile in
                Button {
                    path.append(NavigationDestination.profile(profile.did.didString()))
                } label: {
                    ProfileRowView(profile: profile, path: $path)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(.plain)
                
                if profile != viewModel.profileResults.last {
                    EnhancedDivider()
                }
            }
            
            if viewModel.isLoadingMoreResults {
                ProgressView()
                    .padding()
            }
        }
        .background(Color.systemBackground)
    }
    
    // Posts-only results view
    private var postResultsView: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.postResults, id: \.uri) { post in
                Button {
                    path.append(NavigationDestination.post(post.uri))
                } label: {
//                    PostPreview(post: post)
                    PostView(post: post, grandparentAuthor: nil, isParentPost: false, isSelectable: false, path: $path, appState: appState)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)

                }
                .buttonStyle(.plain)
                
                if post != viewModel.postResults.last {
                    Divider()
                        .padding(.leading, 68)
                }
            }
            
            if viewModel.isLoadingMoreResults {
                ProgressView()
                    .padding()
            }
        }
        .background(Color.systemBackground)
    }
    
    // Feeds-only results view
    private var feedResultsView: some View {
        LazyVStack(spacing: 12) {
            ForEach(viewModel.feedResults, id: \.uri) { feed in
                VStack(spacing: 8) {
                    // Show discovery header for feeds that might not be subscribed
                    FeedDiscoveryHeaderView(
                        feed: feed,
                        isSubscribed: subscriptionStatus[feed.uri.uriString()] ?? false,
                        onSubscriptionToggle: {
                            await toggleFeedSubscription(feed)
                            await updateSubscriptionStatus(for: feed.uri)
                        }
                    )
                    .task {
                        await updateSubscriptionStatus(for: feed.uri)
                    }
                    
                    // Tap anywhere on the card to preview the feed
                    HStack { Spacer(minLength: 0) }.padding(.horizontal, 2)
                }
                .contentShape(Rectangle())
                .onTapGesture { path.append(NavigationDestination.feed(feed.uri)) }
                
                if feed != viewModel.feedResults.last {
                    Divider()
                        .padding(.vertical, 8)
                }
            }
            
            if viewModel.isLoadingMoreResults {
                ProgressView()
                    .padding()
            }
        }
        .padding(.horizontal)
        .background(Color.systemBackground)
    }
    
    // Starter packs-only results view
    private var starterPackResultsView: some View {
        LazyVStack(spacing: 0) {
            ForEach(viewModel.starterPackResults, id: \.uri) { pack in
                Button {
                    path.append(NavigationDestination.starterPack(pack.uri))
                } label: {
                    StarterPackRowView(pack: pack)
                }
                .buttonStyle(.plain)
                
                if pack != viewModel.starterPackResults.last {
                    EnhancedDivider()
                }
            }
            
            if viewModel.isLoadingMoreResults {
                ProgressView()
                    .padding()
            }
        }
        .background(Color.systemBackground)
    }
    
    private func emptyResultsView(for type: ContentType) -> some View {
        VStack(spacing: 16) {
            Image(systemName: type.emptyIcon)
                .appFont(size: 48)
                .foregroundColor(.secondary)
                .padding(.bottom, 8)
                .symbolEffect(.pulse, options: .repeating)
            
            Text("No \(type.title.lowercased()) found")
                .appFont(AppTextRole.headline)
            
            Text("Try a different search term or check out our suggestions")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button {
                // Return to discovery view
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
    
    /// Check if user is subscribed to a feed
    private func isSubscribedToFeed(_ feedURI: ATProtocolURI) async -> Bool {
        // Check if feed is in user's saved or pinned feeds
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
    
    /// Toggle feed subscription
    private func toggleFeedSubscription(_ feed: AppBskyFeedDefs.GeneratorView) async {
        let feedURIString = feed.uri.uriString()
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            
            if await isSubscribedToFeed(feed.uri) {
                // Remove from feeds
                await MainActor.run {
                    preferences.removeFeed(feedURIString)
                }
                try await appState.preferencesManager.saveAndSyncPreferences(preferences)
            } else {
                // Add to saved feeds
                await MainActor.run {
                    preferences.addFeed(feedURIString, pinned: false)
                }
                try await appState.preferencesManager.saveAndSyncPreferences(preferences)
            }
        } catch {
            // Handle error silently or show user feedback
        }
    }
    
    /// Update subscription status for a specific feed
    private func updateSubscriptionStatus(for feedURI: ATProtocolURI) async {
        let status = await isSubscribedToFeed(feedURI)
        await MainActor.run {
            subscriptionStatus[feedURI.uriString()] = status
        }
    }
    
    /// Retry the search after an error
    private func retrySearch() async {
        guard let client = appState.atProtoClient else { return }
        viewModel.searchError = nil
        await viewModel.refreshSearch(client: client)
    }
}

/// A simplified post preview for search results
// struct PostPreview: View {
//    let post: AppBskyFeedDefs.PostView
//    
//    var body: some View {
//        HStack(alignment: .top, spacing: 12) {
//            // Author avatar
//            AsyncProfileImage(url: URL(string: post.author.avatar?.uriString() ?? ""), size: 44)
//                .padding(.top, 2)
//            
//            VStack(alignment: .leading, spacing: 4) {
//                // Author info
//                HStack {
//                    Text(post.author.displayName ?? "@\(post.author.handle)")
//                        .appFont(AppTextRole.headline)
//                        .lineLimit(1)
//                    
//                    Text("@\(post.author.handle)")
//                        .appFont(AppTextRole.subheadline)
//                        .foregroundColor(.secondary)
//                        .lineLimit(1)
//                    
//                    Spacer()
//                    
//                    // Post time
//                    if case .knownType(let postObj) = post.record,
//                       let feedPost = postObj as? AppBskyFeedPost {
//                        Text(formatTimeAgo(from: feedPost.createdAt.date))
//                            .appFont(AppTextRole.caption)
//                            .foregroundColor(.secondary)
//                    }
//                }
//                
//                // Post content
//                if case .knownType(let postObj) = post.record,
//                   let feedPost = postObj as? AppBskyFeedPost {
//                    Text(feedPost.text)
//                                        .appFont(AppTextRole.body)
//                        .lineLimit(3)
//                        .padding(.vertical, 2)
//                }
//                
//                // Post stats
//                HStack(spacing: 16) {
//                    // Reply count
//                    Label("\(post.replyCount ?? 0)", systemImage: "bubble.right")
//                        .appFont(AppTextRole.caption)
//                        .foregroundColor(.secondary)
//                    
//                    // Repost count
//                    Label("\(post.repostCount ?? 0)", systemImage: "arrow.2.squarepath")
//                        .appFont(AppTextRole.caption)
//                        .foregroundColor(.secondary)
//                    
//                    // Like count
//                    Label("\(post.likeCount ?? 0)", systemImage: "heart")
//                        .appFont(AppTextRole.caption)
//                        .foregroundColor(.secondary)
//                }
//                .padding(.top, 4)
//            }
//        }
//        .padding(.vertical, 10)
//        .padding(.horizontal)
//    }
//    
//    // Format a date to a relative "time ago" string
//    private func formatTimeAgo(from date: Date) -> String {
//        let now = Date()
//        let components = Calendar.current.dateComponents([.second, .minute, .hour, .day, .weekOfYear, .month, .year], from: date, to: now)
//        
//        if let years = components.year, years > 0 {
//            return years == 1 ? "1y" : "\(years)y"
//        }
//        
//        if let months = components.month, months > 0 {
//            return months == 1 ? "1mo" : "\(months)mo"
//        }
//        
//        if let weeks = components.weekOfYear, weeks > 0 {
//            return weeks == 1 ? "1w" : "\(weeks)w"
//        }
//        
//        if let days = components.day, days > 0 {
//            return days == 1 ? "1d" : "\(days)d"
//        }
//        
//        if let hours = components.hour, hours > 0 {
//            return hours == 1 ? "1h" : "\(hours)h"
//        }
//        
//        if let minutes = components.minute, minutes > 0 {
//            return minutes == 1 ? "1m" : "\(minutes)m"
//        }
//        
//        return "now"
//    }
// }
