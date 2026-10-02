//
//  TrendingTopicsSection.swift
//  Catbird
//
//  Created on 3/9/25.
//

import SwiftUI
import Petrel

/// A section showing trending topics from the Bluesky network
struct TrendingTopicsSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    let topics: [AppBskyUnspeccedDefs.TrendView]
    let onSelect: (String) -> Void
    let onSeeAll: () -> Void
    let maxItems: Int
    @State private var copilotTopic: AppBskyUnspeccedDefs.TrendView?
    @State private var isShowingCopilot = false
    @State private var pendingDedicatedProposal: CopilotProposal?
    @State private var showHideConfirmation = false
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
            DiscoverySectionHeader("Trending Topics") {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    if topics.count > maxItems {
                        Button(action: onSeeAll) {
                            Label("All Topics", systemImage: "chevron.right")
                                .appFont(AppTextRole.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                    }
                    Menu {
                        Button { showHideConfirmation = true } label: {
                            Label("Hide trending topics…", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Trending topic options")
                }
            }

            if topics.isEmpty {
                emptyStateView
            } else {
                topicsListView
            }
        }
        .sheet(isPresented: $isShowingCopilot) {
            if let topic = copilotTopic {
                let context = CopilotContext.topic(
                    name: topic.displayName,
                    description: TrendingTopicPresentation.description(for: topic),
                    link: topic.link
                )
                CatbirdCopilotSheet(
                    context: context,
                    onDedicatedAction: { proposal in
                        pendingDedicatedProposal = proposal
                    }
                )
            }
        }
        .onChange(of: isShowingCopilot) { wasShowing, isShowing in
            if wasShowing && !isShowing, let proposal = pendingDedicatedProposal {
                pendingDedicatedProposal = nil
                if case .preparePostDraft(let text) = proposal {
                    appState.presentPostComposer(initialText: text)
                }
            }
        }
        .confirmationDialog(
            "Hide trending topics?",
            isPresented: $showHideConfirmation,
            titleVisibility: .visible
        ) {
            Button("Hide", role: .destructive) {
                appState.appSettings.showTrendingTopics = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This hides trending topics for this account in Feeds and Search. You can show trending topics again in Settings → Content & Media.")
        }
    }
    
    private var emptyStateView: some View {
        Text("No trending topics right now. Pull to refresh.")
            .appFont(AppTextRole.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, DesignTokens.Spacing.base)
    }

    private var topicsListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(topics.prefix(maxItems).enumerated()), id: \.element.topic) { index, topic in
                if index > 0 { Divider() }
                topicRow(topic: topic)
            }
        }
        .background(Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme))
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
            
        } label: {
            topicLabel(topic)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copilotTopic = topic
                isShowingCopilot = true
            } label: {
                Label("Ask Catbird", systemImage: "sparkles")
            }
        }
    }
    
    private func topicLabel(_ topic: AppBskyUnspeccedDefs.TrendView) -> some View {
            HStack(alignment: .top, spacing: DesignTokens.Spacing.base) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        if let category = topic.category {
                            Label(formatCategory(category), systemImage: categorySymbol(for: category))
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                        if topic.status == "hot" {
                            Label("Trending", systemImage: "flame.fill")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(topic.displayName)
                        .appFont(AppTextRole.headline)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if let description = TrendingTopicPresentation.description(for: topic) {
                        Text(description)
                            .appFont(AppTextRole.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DesignTokens.Spacing.base) { topicMetadata(topic) }
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) { topicMetadata(topic) }
                    }
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, DesignTokens.Spacing.xs)
            }
            .padding(.vertical, DesignTokens.Spacing.base)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func topicMetadata(_ topic: AppBskyUnspeccedDefs.TrendView) -> some View {
        Text(formatPostCount(topic.postCount)).fixedSize()
        Text(formatTimeSince(topic.startedAt.date)).fixedSize()
    }

    private func categorySymbol(for category: String) -> String {
        let icons = [
            "pop-culture": "music.note.tv", "politics": "building.columns",
            "sports": "figure.basketball", "video-games": "gamecontroller",
            "tech": "laptopcomputer", "business": "chart.bar",
            "science": "atom", "news": "newspaper"
        ]
        return icons[category.lowercased()] ?? "number"
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

/// A common discovery heading with a second row when the title and actions need more room.
struct DiscoverySectionHeader<Actions: View>: View {
  @Environment(\.fontManager) private var fontManager
  let title: String
  let subtitle: String?
  @ViewBuilder let actions: Actions

  init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
    self.title = title
    self.subtitle = subtitle
    self.actions = actions()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: DesignTokens.Spacing.base) {
          heading.fixedSize(horizontal: true, vertical: false)
          Spacer(minLength: 0)
          actions.fixedSize(horizontal: true, vertical: false)
        }
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
          heading
          actions
        }
      }
      if let subtitle {
        Text(subtitle)
          .appFont(AppTextRole.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
  }

  private var heading: some View {
    Text(title)
      .appFont(fontManager.scaledCustomFont(size: 17, weight: .bold, width: 120, relativeTo: .headline))
      .foregroundStyle(.primary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityAddTraits(.isHeader)
  }
}
