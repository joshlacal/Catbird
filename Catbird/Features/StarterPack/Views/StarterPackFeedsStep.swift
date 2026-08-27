//
//  StarterPackFeedsStep.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G57).
//

import SwiftUI
import Petrel
import OSLog

struct StarterPackFeedsStep: View {
    @Binding var draft: StarterPackDraft
    @Environment(AppState.self) private var appState
    
    @State private var searchQuery: String = ""
    @State private var searchResults: [AppBskyFeedDefs.GeneratorView] = []
    @State private var popularFeeds: [AppBskyFeedDefs.GeneratorView] = []
    @State private var isSearching: Bool = false
    @State private var isLoadingPopular: Bool = false
    @State private var searchTask: Task<Void, Never>?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackFeedsStep")
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search feeds to add...", text: $searchQuery)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: searchQuery) { _, newValue in
                        performSearch(query: newValue)
                    }
                
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .background(Color.systemGray6)
            .cornerRadius(10)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Header stats
            HStack {
                Text("Selected Feeds (\(draft.feeds.count)/\(StarterPackDraft.maxFeedsCount))")
                    .appFont(AppTextRole.headline)
                
                Spacer()
                
                if draft.feeds.count == StarterPackDraft.maxFeedsCount {
                    Text("Maximum reached")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Optional (up to \(StarterPackDraft.maxFeedsCount))")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            
            // Content
            if !searchQuery.isEmpty {
                searchResultsList
            } else {
                selectedAndPopularList
            }
        }
        .task {
            await loadPopularFeeds()
        }
    }
    
    // MARK: - Search Results List
    
    private var searchResultsList: some View {
        List {
            if isSearching {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else if searchResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.1x2")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No feeds found")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            } else {
                Section(header: Text("Search Results")) {
                    ForEach(searchResults, id: \.uri) { feed in
                        feedSelectionRow(feed: feed)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    // MARK: - Selected and Popular Feeds
    
    private var selectedAndPopularList: some View {
        List {
            if !draft.feeds.isEmpty {
                Section(header: Text("Selected Feeds")) {
                    ForEach(draft.feeds, id: \.uri) { feed in
                        HStack(spacing: 12) {
                            feedAvatar(feed)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.displayName)
                                    .appFont(AppTextRole.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                
                                Text("By @\(feed.creator.handle)")
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Button {
                                draft.removeFeed(uri: feed.uri)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(6)
                                    .background(Circle().fill(Color.systemGray5))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete { indexSet in
                        draft.feeds.remove(atOffsets: indexSet)
                    }
                }
            }
            
            Section(header: Text("Popular Feeds")) {
                if isLoadingPopular {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if popularFeeds.isEmpty {
                    Text("No suggested feeds available.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(popularFeeds, id: \.uri) { feed in
                        feedSelectionRow(feed: feed)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func feedSelectionRow(feed: AppBskyFeedDefs.GeneratorView) -> some View {
        let isSelected = draft.feeds.contains(where: { $0.uri == feed.uri })
        let canAdd = draft.feeds.count < StarterPackDraft.maxFeedsCount
        
        return HStack(spacing: 12) {
            feedAvatar(feed)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.displayName)
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Text("By @\(feed.creator.handle)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                if let description = feed.description, !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if isSelected {
                Button {
                    draft.removeFeed(uri: feed.uri)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    _ = draft.addFeed(feed)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(canAdd ? Color.accentColor : Color.gray)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(!canAdd)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func feedAvatar(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
        Group {
            if let avatar = feed.avatar {
                AsyncImage(url: URL(string: avatar.uriString())) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "rectangle.grid.1x2")
                            .font(.caption)
                            .foregroundColor(.gray)
                    )
            }
        }
    }
    
    // MARK: - Networking
    
    private func loadPopularFeeds() async {
        guard let client = appState.atProtoClient else { return }
        isLoadingPopular = true
        defer { isLoadingPopular = false }
        
        do {
            let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 15)
            let (code, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
            if code == 200, let feeds = response?.feeds {
                self.popularFeeds = feeds
            }
        } catch {
            logger.error("Error loading popular feeds: \(error.localizedDescription)")
        }
    }
    
    private func performSearch(query: String) {
        searchTask?.cancel()
        
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            
            guard let client = appState.atProtoClient else { return }
            
            await MainActor.run {
                isSearching = true
            }
            
            do {
                let params = AppBskyUnspeccedGetPopularFeedGenerators.Parameters(limit: 20, query: trimmed)
                let (code, response) = try await client.app.bsky.unspecced.getPopularFeedGenerators(input: params)
                
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    if code == 200, let feeds = response?.feeds {
                        self.searchResults = feeds
                    } else {
                        self.searchResults = []
                    }
                    self.isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Error searching feeds: \(error.localizedDescription)")
                await MainActor.run {
                    self.isSearching = false
                    self.searchResults = []
                }
            }
        }
    }
}
