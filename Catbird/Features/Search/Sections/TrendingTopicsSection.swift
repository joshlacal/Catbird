//
//  TrendingTopicsSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel
import OSLog

/// A section showing trending topics from the Bluesky network
struct TrendingTopicsSection: View {
    @Environment(AppState.self) private var appState
    let topics: [AppBskyUnspeccedDefs.TrendingTopic]
    let onSelect: (String) -> Void
    let onSeeAll: () -> Void
    let maxItems: Int
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TrendingTopicsSection")
    
    init(
        topics: [AppBskyUnspeccedDefs.TrendingTopic],
        onSelect: @escaping (String) -> Void,
        onSeeAll: @escaping () -> Void,
        maxItems: Int = 5
    ) {
        self.topics = topics
        self.onSelect = onSelect
        self.onSeeAll = onSeeAll
        self.maxItems = maxItems
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                
                
                Text("Trending Topics")
                    .font(.headline)
                
                Spacer()
                
                if topics.count > maxItems {
                    Button("See All", action: onSeeAll)
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            if topics.isEmpty {
                emptyStateView
            } else {
                topicsListView
            }
        }
    }
    
    private var emptyStateView: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 6) {
                ProgressView()
                    .padding(.bottom, 4)
                
                Text("Loading trending topics...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            
            Spacer()
        }
    }
    
    private var topicsListView: some View {
        // Use VStack instead of ForEach
        VStack(spacing: 0) {
            // Get limited topics
            let limitedTopics = Array(topics.prefix(maxItems))
            
            // Only show up to maxItems
            Group {
                // Manually create the views to avoid ForEach
                if limitedTopics.count > 0 {
                    topicRow(topic: limitedTopics[0])
                    if limitedTopics.count > 1 {
                        Divider().padding(.leading)
                        topicRow(topic: limitedTopics[1])
                    }
                    if limitedTopics.count > 2 {
                        Divider().padding(.leading)
                        topicRow(topic: limitedTopics[2])
                    }
                    if limitedTopics.count > 3 {
                        Divider().padding(.leading)
                        topicRow(topic: limitedTopics[3])
                    }
                    if limitedTopics.count > 4 {
                        Divider().padding(.leading)
                        topicRow(topic: limitedTopics[4])
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, y: 2)
        .padding(.horizontal)
    }
    
    // Extract the row view to a separate function
    private func topicRow(topic: AppBskyUnspeccedDefs.TrendingTopic) -> some View {
        Button {
            // Create a full URL from the relative path
            if let url = URL(string: "https://bsky.app\(topic.link)") {
                _ = appState.urlHandler.handle(url, tabIndex: 1)
                }

                // Use the URL handler to process the URL
                //            onSelect(topic.displayName ?? topic.topic)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                    Text(topic.displayName ?? topic.topic)
                        .font(.headline)
                        .foregroundColor(.primary)
                    }

                    if let description = topic.description {
                        Text(description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
//                    HStack(spacing: 12) {
//                        Label("\(topic.link) posts", systemImage: "text.bubble")
//                            .font(.caption2)
//                            .foregroundColor(.secondary)
//                    }
//                    .padding(.top, 2)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 30)
            .padding(.horizontal)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func formatPostCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let formatted = Double(count) / 1_000_000.0
            return String(format: "%.1fM", formatted)
        } else if count >= 1_000 {
            let formatted = Double(count) / 1_000.0
            return String(format: "%.1fK", formatted)
        } else {
            return "\(count)"
        }
    }
}
