//
//  ContextualSuggestedFollowsSheet.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G59).
//

import SwiftUI
import Petrel
import OSLog

public struct ContextualSuggestedFollowsSheet: View {
    let actorDID: String
    let actorHandle: String
    @Binding var path: NavigationPath
    
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    @State private var suggestions: [AppBskyActorDefs.ProfileView] = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ContextualSuggestedFollowsSheet")
    
    public init(actorDID: String, actorHandle: String, path: Binding<NavigationPath>) {
        self.actorDID = actorDID
        self.actorHandle = actorHandle
        self._path = path
    }
    
    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Finding suggested follows...")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if suggestions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No suggestions available")
                            .appFont(AppTextRole.headline)
                        Text("There are no additional suggested follows for @\(actorHandle) right now.")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    suggestionsList
                }
            }
            .navigationTitle("Suggested Follows")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadSuggestions()
            }
        }
    }
    
    // MARK: - Suggestions List
    
    private var suggestionsList: some View {
        List {
            Section(header: Text("People similar to @\(actorHandle)")) {
                ForEach(suggestions, id: \.did) { profile in
                    suggestionRow(profile: profile)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    
    private func suggestionRow(profile: AppBskyActorDefs.ProfileView) -> some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
                path.append(NavigationDestination.profile(profile.did.didString()))
            } label: {
                HStack(spacing: 12) {
                    AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 44)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.displayName ?? "@\(profile.handle)")
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        
                        Text("@\(profile.handle)")
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        
                        if let description = profile.description, !description.isEmpty {
                            Text(description)
                                .appFont(AppTextRole.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            EnhancedFollowButton(profile: profile)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Networking
    
    private func loadSuggestions() async {
        guard let client = appState.atProtoClient else {
            isLoading = false
            return
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let identifier = try ATIdentifier(string: actorDID)
            let params = AppBskyGraphGetSuggestedFollowsByActor.Parameters(actor: identifier)
            let (code, output) = try await client.app.bsky.graph.getSuggestedFollowsByActor(input: params)
            
            guard code == 200, let suggestionsOutput = output else {
                logger.warning("getSuggestedFollowsByActor returned HTTP \(code)")
                return
            }
            
            let currentDID = appState.userDID
            
            // Filter eligible suggestions
            let filtered = suggestionsOutput.suggestions.filter { profile in
                let didString = profile.did.didString()
                // Exclude self
                if didString == currentDID { return false }
                
                guard let viewer = profile.viewer else { return true }
                
                // Exclude already following
                if viewer.following != nil { return false }
                // Exclude muted
                if viewer.muted == true || viewer.mutedByList != nil { return false }
                // Exclude blocked / blocking
                if viewer.blocking != nil || viewer.blockingByList != nil || viewer.blockedBy == true { return false }
                
                return true
            }
            
            self.suggestions = filtered
        } catch {
            logger.error("Failed to load suggested follows for \(actorDID): \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }
    }
}
