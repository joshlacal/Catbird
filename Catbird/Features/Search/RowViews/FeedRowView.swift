////
////  FeedRowView.swift
////  Catbird
////
////  Created on 3/9/25.
////
//
//import SwiftUI
//import Petrel
//
///// Enhanced feed row view with better styling
//struct EnhancedFeedRowView: View {
//    let feed: AppBskyFeedDefs.GeneratorView
//    
//    var body: some View {
//        HStack(spacing: 12) {
//            // Feed avatar with shadow effect
//            AsyncProfileImage(url: URL(string: feed.avatar?.uriString() ?? ""), size: 44)
//                .shadow(color: Color.black.opacity(0.1), radius: 1, y: 1)
//            
//            VStack(alignment: .leading, spacing: 2) {
//                Text(feed.displayName)
//                    .font(.headline)
//                    .lineLimit(1)
//                
//                Text("by @\(feed.creator.handle)")
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                    .lineLimit(1)
//                
//                if let description = feed.description, !description.isEmpty {
//                    Text(description)
//                        .font(.caption)
//                        .foregroundColor(.secondary)
//                        .lineLimit(2)
//                        .padding(.top, 2)
//                }
//                
//                // Show like count if available
//                if let likeCount = feed.likeCount, likeCount > 0 {
//                    HStack(spacing: 4) {
//                        Image(systemName: "heart.fill")
//                            .font(.caption2)
//                            .foregroundColor(.red.opacity(0.8))
//                        
//                        Text("\(formatCount(likeCount)) likes")
//                            .font(.caption2)
//                            .foregroundColor(.secondary)
//                    }
//                    .padding(.top, 2)
//                }
//            }
//            
//            Spacer()
//            
//            Image(systemName: "chevron.right")
//                .font(.caption)
//                .foregroundColor(.secondary)
//        }
//        .padding(.vertical, 8)
//        .padding(.horizontal)
//    }
//    
//    /// Format large numbers with K/M suffixes
//    private func formatCount(_ count: Int) -> String {
//        if count >= 1_000_000 {
//            let formatted = Double(count) / 1_000_000.0
//            return String(format: "%.1fM", formatted)
//        } else if count >= 1_000 {
//            let formatted = Double(count) / 1_000.0
//            return String(format: "%.1fK", formatted)
//        } else {
//            return "\(count)"
//        }
//    }
//}
//
///// A collection of feed rows
//struct FeedRowCollection: View {
//    let feeds: [AppBskyFeedDefs.GeneratorView]
//    let onSelect: (AppBskyFeedDefs.GeneratorView) -> Void
//    
//    var body: some View {
//        VStack(spacing: 0) {
//            ForEach(feeds, id: \.uri) { feed in
//                Button {
//                    onSelect(feed)
//                } label: {
//                    EnhancedFeedRowView(feed: feed)
//                }
//                .buttonStyle(.plain)
//                
//                if feed != feeds.last {
//                    EnhancedDivider()
//                }
//            }
//        }
//        .background(Color(.systemBackground))
//        .cornerRadius(12)
//        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
//        .padding(.horizontal)
//    }
//}
//
///// Fetcher for popular feeds
//extension FeedRowCollection {
//    static func fetchPopularFeeds(client: ATProtoClient) async throws -> [AppBskyFeedDefs.GeneratorView] {
//        do {
//            let response = try await client.app.bsky.unspecced.getPopularFeedGenerators(input:.init(limit: 10))
//            return response.data?.feeds ?? []
//        } catch {
//            print("Error fetching popular feeds: \(error.localizedDescription)")
//            throw error
//        }
//    }
//}
//
