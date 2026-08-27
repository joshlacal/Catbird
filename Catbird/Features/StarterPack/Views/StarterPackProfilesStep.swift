//
//  StarterPackProfilesStep.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G57).
//

import SwiftUI
import Petrel
import OSLog

struct StarterPackProfilesStep: View {
    @Binding var draft: StarterPackDraft
    @Environment(AppState.self) private var appState
    
    @State private var searchQuery: String = ""
    @State private var searchResults: [AppBskyActorDefs.ProfileViewBasic] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackProfilesStep")
    
    var body: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search people to add...", text: $searchQuery)
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
                Text("Selected (\(draft.profiles.count)/\(StarterPackDraft.maxProfilesCount))")
                    .appFont(AppTextRole.headline)
                
                Spacer()
                
                if draft.profiles.count < StarterPackDraft.minProfilesCount {
                    Text("Add at least \(StarterPackDraft.minProfilesCount)")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.orange)
                } else if draft.profiles.count == StarterPackDraft.maxProfilesCount {
                    Text("Maximum reached")
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
                selectedProfilesList
            }
        }
    }
    
    // MARK: - Search Results
    
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
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No profiles found")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .listRowBackground(Color.clear)
            } else {
                Section(header: Text("Search Results")) {
                    ForEach(searchResults, id: \.did) { profile in
                        searchResultRow(profile: profile)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func searchResultRow(profile: AppBskyActorDefs.ProfileViewBasic) -> some View {
        let isSelected = draft.profiles.contains(where: { $0.did == profile.did })
        let isSelf = profile.did.didString() == appState.userDID
        let canAdd = draft.profiles.count < StarterPackDraft.maxProfilesCount
        
        return HStack(spacing: 12) {
            AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 40)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName ?? "@\(profile.handle)")
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Text("@\(profile.handle)")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if isSelf {
                Text("You")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            } else if isSelected {
                Button {
                    draft.removeProfile(did: profile.did)
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    _ = draft.addProfile(profile)
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
    
    // MARK: - Selected Profiles
    
    private var selectedProfilesList: some View {
        List {
            if draft.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.3")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No People Added Yet")
                        .appFont(AppTextRole.headline)
                    Text("Search above to add people to this starter pack.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .listRowBackground(Color.clear)
            } else {
                Section(footer: Text("Swipe or tap the trash icon to remove an account.")) {
                    ForEach(draft.profiles, id: \.did) { profile in
                        HStack(spacing: 12) {
                            AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 40)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.displayName ?? "@\(profile.handle)")
                                    .appFont(AppTextRole.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                
                                Text("@\(profile.handle)")
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            
                            Spacer()
                            
                            Button {
                                draft.removeProfile(did: profile.did)
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
                        draft.profiles.remove(atOffsets: indexSet)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    // MARK: - Search Execution
    
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
                let params = AppBskyActorSearchActorsTypeahead.Parameters(q: trimmed, limit: 20)
                let (code, response) = try await client.app.bsky.actor.searchActorsTypeahead(input: params)
                
                guard !Task.isCancelled else { return }
                
                await MainActor.run {
                    if code >= 200 && code < 300, let actors = response?.actors {
                        self.searchResults = actors
                    } else {
                        self.searchResults = []
                    }
                    self.isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                logger.error("Error searching actors: \(error.localizedDescription)")
                await MainActor.run {
                    self.isSearching = false
                    self.searchResults = []
                }
            }
        }
    }
}
