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
    
    @State private var suggestions: [AppBskyActorDefs.ProfileView]
    @State private var isLoading: Bool
    @State private var errorMessage: String?
    
    private static let logger = Logger(subsystem: "blue.catbird", category: "ContextualSuggestedFollowsSheet")
    
    /// - Parameter initialSuggestions: Suggestions the caller already fetched. When provided,
    ///   the sheet shows them immediately instead of loading its own.
    public init(
        actorDID: String,
        actorHandle: String,
        path: Binding<NavigationPath>,
        initialSuggestions: [AppBskyActorDefs.ProfileView]? = nil
    ) {
        self.actorDID = actorDID
        self.actorHandle = actorHandle
        self._path = path
        self._suggestions = State(initialValue: initialSuggestions ?? [])
        self._isLoading = State(initialValue: initialSuggestions == nil)
    }
    
    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Finding suggested follows…")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, suggestions.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn’t Load Suggestions", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            Task { await loadSuggestions() }
                        }
                    }
                } else if suggestions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Suggestions Right Now")
                            .appFont(AppTextRole.headline)
                        Text("There are no other suggested follows for @\(actorHandle) right now.")
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
                guard isLoading else { return }
                await loadSuggestions()
            }
        }
        .presentationDetents([.medium, .large])
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
        .platformInsetGroupedListStyle()
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
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            suggestions = try await Self.fetchSuggestions(
                client: client,
                actorDID: actorDID,
                currentUserDID: appState.userDID
            )
        } catch {
            Self.logger.error("Failed to load suggested follows for \(actorDID): \(error.localizedDescription)")
            errorMessage = UserFacingError.message(for: error, action: "load suggestions")
        }
    }
    
    /// Fetches people similar to `actorDID`, excluding the current user and anyone already
    /// followed, muted or blocked.
    static func fetchSuggestions(
        client: ATProtoClient,
        actorDID: String,
        currentUserDID: String?
    ) async throws -> [AppBskyActorDefs.ProfileView] {
        let identifier = try ATIdentifier(string: actorDID)
        let params = AppBskyGraphGetSuggestedFollowsByActor.Parameters(actor: identifier)
        let (code, output) = try await client.app.bsky.graph.getSuggestedFollowsByActor(input: params)
        
        guard code == 200, let suggestionsOutput = output else {
            logger.warning("getSuggestedFollowsByActor returned HTTP \(code)")
            throw SuggestedFollowsError.unavailable(code)
        }
        
        return suggestionsOutput.suggestions.filter { profile in
            let didString = profile.did.didString()
            // Exclude self
            if didString == currentUserDID { return false }
            
            guard let viewer = profile.viewer else { return true }
            
            // Exclude already following
            if viewer.following != nil { return false }
            // Exclude muted
            if viewer.muted == true || viewer.mutedByList != nil { return false }
            // Exclude blocked / blocking
            if viewer.blocking != nil || viewer.blockingByList != nil || viewer.blockedBy == true { return false }
            
            return true
        }
    }
}

enum SuggestedFollowsError: Error {
    case unavailable(Int)
}
