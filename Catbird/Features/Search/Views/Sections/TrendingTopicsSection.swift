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
    @Environment(\.colorScheme) private var colorScheme
    
    let topics: [AppBskyUnspeccedDefs.TrendView]
    let onSelect: (String) -> Void
    let onSeeAll: () -> Void
    let maxItems: Int
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TrendingTopicsSection")
    
    init(
        topics: [AppBskyUnspeccedDefs.TrendView],
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
                Label("Trending", systemImage: "chart.line.uptrend.xyaxis")
                    .appFont(.customSystemFont(size: 17, weight: .medium, width: 120, relativeTo: .headline))

                Spacer()
                
                if topics.count > maxItems {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text("See All")
                            Image(systemName: "chevron.right")
                                .appFont(AppTextRole.caption)
                        }
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.accentColor)
                    }
                }
            }
            .padding(.horizontal)
            
            if topics.isEmpty {
                emptyStateView
            } else {
                topicsListView
            }
        }
        // Prefetch summaries for visible topics (maxItems)
        .task(id: topics.prefix(maxItems).map { $0.summaryIdentityKey }.joined(separator: ",")) {
            if #available(iOS 26.0, *) {
                await TopicSummaryService.shared.primeSummaries(for: Array(topics.prefix(maxItems)), appState: appState, max: maxItems)
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
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            
            Spacer()
        }
    }
    
    private var topicsListView: some View {
        VStack(spacing: 0) {
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
        .background(Color.elevatedBackground(appState.themeManager, elevation: .low, currentScheme: colorScheme))
        .cornerRadius(12)
        .shadow(color: Color.dynamicShadow(appState.themeManager, currentScheme: colorScheme), radius: 8, y: 4)
        .padding(.horizontal)
    }
    
    // Extract the row view to a separate function
    private func topicRow(topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        Button {
            // Create a full URL from the relative path
            if topic.link.starts(with: "http"), let fullURL = URL(string: topic.link) {
                _ = appState.urlHandler.handle(fullURL, tabIndex: 1)
            } else if let url = URL(string: "https://bsky.app\(topic.link)") {
                _ = appState.urlHandler.handle(url, tabIndex: 1)
            }
            
            // Uncomment to use onSelect instead of direct URL handling
            // onSelect(topic.displayName ?? topic.topic)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                categoryIcon(for: topic.category)
                    .appFont(AppTextRole.title3)
                    .foregroundColor(categoryColor(for: topic.category))
                    .padding(12)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().stroke(categoryColor(for: topic.category), lineWidth: 1)
                            .fill(categoryColor(for: topic.category).opacity(0.1))
                            .scaleEffect(1.2)
                    )
                    .padding(.top, 10)
                
                VStack(alignment: .leading, spacing: 4) {
                    
                    if let category = topic.category {
                        Text(formatCategory(category))
                            .appFont(AppTextRole.subheadline)
                            .textCase(.uppercase)
                            .textScale(.secondary)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
//                            .padding(.vertical, 2)
//                            .padding(.horizontal, 6)
//                            .background(
//                                Capsule()
//                                    .fill(Color(.systemGray6))
//                            )
                    }
                    
                    HStack(spacing: 8) {
                        Text(topic.displayName)
                            .appFont(.customSystemFont(size: 23, weight: .medium, width: 120, relativeTo: .title3))
                            .padding(.bottom, 3)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .primary, currentScheme: colorScheme))
                        
                        if let status = topic.status, status == "hot" {
                            trendingBadge(status: status)
                        }
                    }
                    
                    HStack(spacing: 12) {
                        Label(formatPostCount(topic.postCount), systemImage: "text.bubble")
                            .appFont(AppTextRole.caption2)
                            .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                        
                        Label(formatTimeSince(topic.startedAt.date), systemImage: "clock")
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                    }
                    .padding(.top, 2)

                    // Topic summary (iOS 26+ via Foundation Models). Hidden if unavailable.
                    if #available(iOS 26.0, *) {
                        TrendingTopicSummaryLine(topic: topic)
                            .id(topic.summaryIdentityKey)
                    }
                }
                
                Spacer()
                
                Image(systemName: "arrow.up.right")
                    .appFont(AppTextRole.footnote)
                    .foregroundColor(.accentColor)
                    .padding(8)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(Rectangle())
    }
    
    private func trendingBadge(status: String) -> some View {
        Text(status.uppercased())
            .appFont(size: 10)
            .foregroundColor(.white)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(
                Capsule()
                    .fill(Color.red)
            )
    }
    
    private func categoryIcon(for category: String?) -> some View {
        guard let category = category else {
            return Image(systemName: "number")
        }
        
        // Dictionary of category icons
        let categoryIcons: [String: String] = [
            "pop-culture": "music.note.tv",
            "politics": "building.columns",
            "sports": "figure.basketball",
            "video-games": "gamecontroller",
            "tech": "laptopcomputer",
            "business": "chart.bar",
            "science": "atom",
            "news": "newspaper",
            "other": "number"
        ]
        
        // Return the icon if it exists, otherwise use a default
        return Image(systemName: categoryIcons[category.lowercased()] ?? "number")
    }
    
    private func categoryColor(for category: String?) -> Color {
        guard let category = category else {
            return .gray
        }
        
        // Dictionary of category colors
        let categoryColors: [String: Color] = [
            "pop-culture": .purple,
            "politics": .blue,
            "sports": .orange,
            "video-games": .green,
            "tech": .cyan,
            "business": .yellow,
            "science": .mint,
            "news": .red,
            "other": .gray
        ]
        
        // Return the color if it exists, otherwise use a default
        return categoryColors[category.lowercased()] ?? .gray
    }
    
    private func formatPostCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            let formatted = Double(count) / 1_000_000.0
            return String(format: "%.1fM posts", formatted)
        } else if count >= 1_000 {
            let formatted = Double(count) / 1_000.0
            return String(format: "%.1fK posts", formatted)
        } else {
            return "\(count) posts"
        }
    }
    
    private func formatTimeSince(_ date: Date) -> String {
        let now = Date()
        let components = Calendar.current.dateComponents([.hour, .minute], from: date, to: now)
        
        if let hours = components.hour, hours > 0 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else if let minutes = components.minute, minutes > 0 {
            return minutes == 1 ? "1 min ago" : "\(minutes) mins ago"
        } else {
            return "just now"
        }
    }
    
    private func formatCategory(_ category: String) -> String {
        // Special cases dictionary
        let specialCases: [String: String] = [
            "pop-culture": "Entertainment",
            "video-games": "Video Games"
        ]
        
        // Check for special cases first
        if let specialCase = specialCases[category.lowercased()] {
            return specialCase
        }
        
        // Otherwise format normally
        let words = category.components(separatedBy: "-")
        let capitalizedWords = words.map { $0.capitalized }
        return capitalizedWords.joined(separator: " ")
    }
}

private extension AppBskyUnspeccedDefs.TrendView {
    var summaryIdentityKey: String { "\(link)|\(displayName)" }
}

// MARK: - Summary Line Subview

@available(iOS 26.0, *)
private struct TrendingTopicSummaryLine: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    let topic: AppBskyUnspeccedDefs.TrendView

    @State private var summary: String = ""
    @State private var isLoading: Bool = false
    @State private var isStreaming: Bool = false

    private var taskID: String { topic.summaryIdentityKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !summary.isEmpty {
                Text(summary)
                    .appFont(AppTextRole.footnote)
                    .foregroundColor(Color.dynamicText(appState.themeManager, style: .secondary, currentScheme: colorScheme))
                    .transition(.opacity)
                    .accessibilityLabel("Topic summary")
                    .animation(.easeInOut(duration: 0.2), value: summary)
            } else if isLoading {
                // Lightweight loading shimmer
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme))
                    .frame(height: 15 * 3) // Approx. 3 lines
                    .redacted(reason: .placeholder)
            }
        }
        .task(id: taskID) {
            // Avoid re-entrancy
            guard !isLoading, summary.isEmpty else { return }
            isLoading = true
            defer { isLoading = false }

            // Poll cache - prewarming should have already generated summaries
            os_log("[SummaryUI] Checking cache for %{public}@", topic.displayName)
            
            // Wait briefly for prewarming to complete, then check cache
            for attempt in 0..<10 {
                if let cachedSummary = await TopicSummaryService.shared.getCachedSummary(for: topic) {
                    await MainActor.run {
                        summary = cachedSummary
                    }
                    os_log("[SummaryUI] Cache hit for %{public}@ on attempt %d", topic.displayName, attempt)
                    return
                }
                
                // Wait 100ms before next attempt (max 1 second total)
                try? await Task.sleep(for: .milliseconds(100))
            }
            
            // If still no cache after polling, fall back to streaming
            os_log("[SummaryUI] Cache miss after polling for %{public}@, falling back to stream", topic.displayName)
            if let stream = await TopicSummaryService.shared.streamSummary(for: topic, appState: appState) {
                isStreaming = true
                do {
                    for try await partialText in stream {
                        await MainActor.run {
                            summary = partialText
                        }
                    }
                } catch {
                    os_log("[SummaryUI] Stream error for %{public}@: %{public}@", topic.displayName, error.localizedDescription)
                }
                isStreaming = false
            }
            
            os_log("[SummaryUI] Row task end for %{public}@ -> %{public}@", topic.displayName, summary.isEmpty ? "<empty>" : summary)
        }
        .padding(.top, 6)
    }
}
