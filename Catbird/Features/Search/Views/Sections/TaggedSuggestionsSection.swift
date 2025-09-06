//
//  TaggedSuggestionsSection.swift
//  Catbird
//
//  Created on 3/9/25.
//
import SwiftUI
import Petrel
import OSLog

/// A model to store tagged suggestions data
struct TaggedSuggestion: Identifiable {
    let id: String
    let tag: String
    let profiles: [AppBskyActorDefs.ProfileViewDetailed]
    
    init(tag: String, profiles: [AppBskyActorDefs.ProfileViewDetailed]) {
        self.id = tag
        self.tag = tag
        self.profiles = profiles
    }
}

/// A section showing collections of suggested profiles organized by tags
struct TaggedSuggestionsSection: View {
    let suggestions: [TaggedSuggestion]
    let onSelectProfile: (String) -> Void
    let onRefresh: (() -> Void)? // Optional refresh callback
    @Binding var path: NavigationPath
    
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @Environment(AppState.self) private var appState
    
    private let logger = Logger(subsystem: "blue.catbird", category: "TaggedSuggestionsSection")
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Discover")
                    .appFont(AppTextRole.headline)
                
                Spacer()
                
                if let onRefresh = onRefresh {
                    Button(action: {
                        isRefreshing = true
                        errorMessage = nil
                        onRefresh()
                        
                        // Auto-reset refreshing state after 2 seconds if not reset by parent
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            isRefreshing = false
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                            .imageScale(.medium)
                            .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                            .animation(isRefreshing ? Animation.linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isRefreshing)
                    }
                    .disabled(isRefreshing)
                }
            }
            .padding(.horizontal)
            
            if let error = errorMessage {
                errorView(message: error)
            } else if suggestions.isEmpty {
                emptyStateView
            } else {
                suggestionsListView
            }
        }
    }
    
    private var emptyStateView: some View {
        HStack {
            Spacer()
            
            VStack(spacing: 6) {
                ProgressView()
                    .padding(.bottom, 4)
                
                Text("Loading suggestions...")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 12)
            
            Spacer()
        }
    }
    
    private func errorView(message: String) -> some View {
        HStack {
            Spacer()
            
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .imageScale(.large)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 2)
                
                Text("Error loading suggestions")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                
                Text(message)
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                
                if let onRefresh = onRefresh {
                    Button("Try Again") {
                        errorMessage = nil
                        onRefresh()
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.vertical, 16)
            
            Spacer()
        }
    }
    
    private var suggestionsListView: some View {
        VStack(spacing: 24) {
            ForEach(suggestions) { suggestion in
                tagSection(suggestion)
            }
        }
    }
    
    private func tagSection(_ suggestion: TaggedSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(suggestion.tag.capitalized)
                    .appFont(AppTextRole.headline)
                
                Spacer()
                
                NavigationLink(destination: AllTaggedProfilesView(tag: suggestion.tag, profiles: suggestion.profiles, onSelectProfile: onSelectProfile, path: $path)) {
                    Text("See All")
                        .appFont(AppTextRole.subheadline)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            if suggestion.profiles.isEmpty {
                emptyTagView(tag: suggestion.tag)
            } else {
                profilesScrollView(suggestion)
            }
        }
    }
    
    private func emptyTagView(tag: String) -> some View {
        HStack {
            Spacer()
            
            Text("No profiles found for \(tag)")
                .appFont(AppTextRole.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 12)
            
            Spacer()
        }
    }
    
    private func profilesScrollView(_ suggestion: TaggedSuggestion) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(suggestion.profiles, id: \.did) { profile in
//                    ProfileCard(
//                        profile: profile,
//                        onSelect: { onSelectProfile(profile.did) }
//                    )
                    ProfileRowView(profile: profile, path: $path)
                        .onTapGesture {
                            onSelectProfile(profile.did.didString())
                        }
                }
            }
            .padding(.horizontal)
        }
    }
    
    /// Fetch tagged suggestions from the server with optimized profile fetching
    static func fetchTaggedSuggestions(client: ATProtoClient) async throws -> [TaggedSuggestion] {
        let logger = Logger(subsystem: "blue.catbird", category: "TaggedSuggestionsSection")
        
        do {
            let response = try await client.app.bsky.unspecced.getTaggedSuggestions(input: .init())
            
            guard let suggestions = response.data?.suggestions else {
                logger.error("No suggestions returned")
                throw FetchError.noData("No suggestions returned from server")
            }
            
            // Group suggestions by tag
            var suggestionsByTag: [String: [ATIdentifier]] = [:]
            
            for suggestion in suggestions {
                let tag = suggestion.tag
                let subjectDid = try extractDidFromURI(suggestion.subject.uriString())
                
                if suggestionsByTag[tag] == nil {
                    suggestionsByTag[tag] = []
                }
                
                // Store DIDs to fetch in batches
                suggestionsByTag[tag]?.append(subjectDid)
            }
            
            // Fetch profiles in parallel by tag
            let taggedSuggestions = await withTaskGroup(of: (String, [AppBskyActorDefs.ProfileViewDetailed]).self) { group in
                for (tag, dids) in suggestionsByTag {
                    group.addTask {
                        // Fetch profiles for this tag
                        let profiles = try? await fetchProfilesForDIDs(client: client, dids: dids)
                        return (tag, profiles ?? [])
                    }
                }
                
                // Collect results
                var results: [TaggedSuggestion] = []
                for await (tag, profiles) in group {
                    if !profiles.isEmpty {
                        results.append(TaggedSuggestion(tag: tag, profiles: profiles))
                    }
                }
                
                return results.sorted { $0.tag < $1.tag }
            }
            
            return taggedSuggestions
        } catch {
            logger.error("Failed to fetch tagged suggestions: \(error.localizedDescription)")
            throw error
        }
    }
    
    // Optimized batch fetching of profiles
    private static func fetchProfilesForDIDs(client: ATProtoClient, dids: [ATIdentifier]) async throws -> [AppBskyActorDefs.ProfileViewDetailed] {
        guard !dids.isEmpty else { return [] }
        
        let logger = Logger(subsystem: "blue.catbird", category: "TaggedSuggestionsSection")
        
        // Limit batch size to avoid request size limitations
        let batchSize = 25
        var allProfiles: [AppBskyActorDefs.ProfileViewDetailed] = []
        
        // Process in batches
        for i in stride(from: 0, to: dids.count, by: batchSize) {
            let end = min(i + batchSize, dids.count)
            let batch = Array(dids[i..<end])
            
            do {
                // Use getProfiles to fetch multiple profiles at once
                let input = AppBskyActorGetProfiles.Parameters(actors: batch)
                let (_, response) = try await client.app.bsky.actor.getProfiles(input: input)
                
                if let profiles = response?.profiles {
                    allProfiles.append(contentsOf: profiles)
                }
            } catch {
                logger.error("Error fetching batch of profiles: \(error.localizedDescription)")
                // Continue with next batch rather than failing completely
            }
        }
        
        return allProfiles
    }
    
    // Helper function to extract DID from URI string
    private static func extractDidFromURI(_ uriString: String) throws -> ATIdentifier {
        // Extract DID based on AT Protocol URI format
        if uriString.hasPrefix("at://") {
            let components = uriString.dropFirst(5).components(separatedBy: "/")
            if !components.isEmpty {
                return try ATIdentifier(string: components[0])
            }
        }
        return try ATIdentifier(string: uriString)
    }
    
    // Custom error types for better error handling
    enum FetchError: Error, LocalizedError {
        case noData(String)
        case networkError(Error)
        case profileFetchError(String)
        
        var errorDescription: String? {
            switch self {
            case .noData(let message):
                return message
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            case .profileFetchError(let message):
                return "Profile fetch error: \(message)"
            }
        }
    }
}

/// A reusable profile card component
// struct ProfileCard: View {
//    let profile: AppBskyActorDefs.ProfileViewBasic
//    let onSelect: () -> Void
//    
//    var body: some View {
//        Button(action: onSelect) {
//            VStack(alignment: .center, spacing: 8) {
//                // Profile avatar with indicator if verified
//                ZStack(alignment: .bottomTrailing) {
//                    AsyncProfileImage(
//                        url: URL(string: profile.avatar?.uriString() ?? ""),
//                        size: 70
//                    )
//                    .shadow(color: Color.black.opacity(0.1), radius: 2, y: 1)
//                    .overlay(
//                        Circle()
//                            .stroke(Color.accentColor, lineWidth: 1.5)
//                            .opacity(0.3)
//                    )
//                    
//                    // Show verification badge if applicable
//                    if profile.viewer?.verification?.isVerified == true {
//                        Image(systemName: "checkmark.seal.fill")
//                            .foregroundColor(.blue)
//                            .background(
//                                Circle()
//                                    .fill(Color.white)
//                                    .frame(width: 16, height: 16)
//                            )
//                            .offset(x: 2, y: 2)
//                    }
//                }
//                
//                // Profile name
//                Text(profile.displayName ?? "@\(profile.handle)")
//                    .appFont(AppTextRole.subheadline)
//                    .fontWeight(.medium)
//                    .lineLimit(1)
//                    .frame(width: 90)
//                
//                // Handle with truncation
//                Text("@\(profile.handle)")
//                    .appFont(AppTextRole.caption)
//                    .foregroundColor(.secondary)
//                    .lineLimit(1)
//                    .frame(width: 90)
//                
//                // Follower count if available
//                if let followers = profile.viewer?.followersCount {
//                    Text("\(followers) followers")
//                        .appFont(AppTextRole.caption2)
//                        .foregroundColor(.secondary)
//                        .lineLimit(1)
//                        .frame(width: 90)
//                }
//            }
//            .frame(width: 100)
//        }
//        .buttonStyle(.plain)
//        .foregroundColor(.primary)
//    }
// }

/// View for displaying all profiles in a specific tag
struct AllTaggedProfilesView: View {
    @Environment(AppState.self) private var appState
    let tag: String
    let profiles: [AppBskyActorDefs.ProfileViewDetailed]
    let onSelectProfile: (String) -> Void
    @Binding var path: NavigationPath
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160), spacing: 16)
            ], spacing: 16) {
                ForEach(profiles, id: \.did) { profile in
//                    ProfileCard(
//                        profile: profile,
//                        onSelect: { onSelectProfile(profile.did) }
//                    )
                    ProfileRowView(profile: profile, path: $path)
                        .frame(height: 160)
                        .onTapGesture {
                            onSelectProfile(profile.did.didString())
                        }
                }
            }
            .padding()
        }
        .navigationTitle(tag.capitalized)
    }
}
