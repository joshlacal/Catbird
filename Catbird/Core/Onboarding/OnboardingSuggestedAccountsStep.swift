import Foundation
import OSLog
import Petrel
import SwiftUI

/// Onboarding step for discovering and following suggested accounts based on selected interests
public struct OnboardingSuggestedAccountsStep: View {
    @Environment(AppState.self) private var appState
    let selectedInterests: [String]
    let onContinue: () -> Void
    let onSkip: () -> Void
    
    @State private var suggestedActors: [AppBskyActorDefs.ProfileView] = []
    @State private var followedDIDs: Set<String> = []
    @State private var followInProgressDIDs: Set<String> = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    
    private let logger = Logger(subsystem: "blue.catbird", category: "OnboardingSuggestedAccounts")
    
    public init(
        selectedInterests: [String],
        onContinue: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.selectedInterests = selectedInterests
        self.onContinue = onContinue
        self.onSkip = onSkip
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Follow Suggested Accounts")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("Here are popular accounts matching your interests to help build your feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            // Content
            if isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView("Finding accounts for you...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    
                    Button("Try Again") {
                        Task {
                            await loadSuggestedAccounts()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if suggestedActors.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "person.2.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    
                    Text("No suggestions available right now")
                        .font(.headline)
                    
                    Text("You can always discover and follow creators later in Search.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        ForEach(suggestedActors, id: \.did) { actor in
                            suggestedActorRow(actor)
                        }
                    } header: {
                        HStack {
                            Text("\(suggestedActors.count) SUGGESTED")
                            Spacer()
                            Button("Follow All") {
                                followAll()
                            }
                            .font(.caption.bold())
                            .foregroundStyle(.accent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            
            // Bottom Actions
            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text(followedDIDs.isEmpty ? "Continue" : "Continue (\(followedDIDs.count) followed)")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                Button("Skip for now") {
                    onSkip()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.ultraThinMaterial)
        }
        .task {
            await loadSuggestedAccounts()
        }
    }
    
    // MARK: - Row View
    
    private func suggestedActorRow(_ actor: AppBskyActorDefs.ProfileView) -> some View {
        let did = actor.did.didString()
        let isFollowing = followedDIDs.contains(did)
        let isProcessing = followInProgressDIDs.contains(did)
        
        return HStack(spacing: 12) {
            // Avatar
            if let avatarURLString = actor.avatar?.uriString(), let url = URL(string: avatarURLString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.2))
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(actor.displayName?.prefix(1) ?? actor.handle.value.prefix(1))
                            .font(.headline)
                            .foregroundStyle(.accent)
                    )
            }
            
            // Info
            VStack(alignment: .leading, spacing: 2) {
                if let displayName = actor.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                }
                Text("@\(actor.handle.value)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                
                if let description = actor.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            
            Spacer()
            
            // Follow Button
            Button {
                toggleFollow(for: actor)
            } label: {
                if isProcessing {
                    ProgressView()
                        .frame(width: 76, height: 32)
                } else {
                    Text(isFollowing ? "Following" : "Follow")
                        .font(.caption.bold())
                        .frame(width: 76, height: 32)
                        .background(isFollowing ? Color.secondary.opacity(0.15) : Color.accentColor)
                        .foregroundColor(isFollowing ? .primary : .white)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isProcessing || isFollowing)
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Network Methods
    
    private func loadSuggestedAccounts() async {
        guard let client = appState.atProtoClient else {
            isLoading = false
            errorMessage = "Service unavailable"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        var actors: [AppBskyActorDefs.ProfileView] = []
        var seenDIDs = Set<String>()
        
        do {
            let categories = selectedInterests.isEmpty ? [nil] : selectedInterests.map { Optional($0.lowercased()) }
            
            for category in categories {
                let params = AppBskyUnspeccedGetSuggestedOnboardingUsers.Parameters(
                    category: category,
                    limit: 25
                )
                let (code, output) = try await client.app.bsky.unspecced.getSuggestedOnboardingUsers(input: params)
                if code == 200, let data = output {
                    for actor in data.actors {
                        let did = actor.did.didString()
                        if did != appState.userDID &&
                            actor.viewer?.blocking == nil &&
                            actor.viewer?.muted != true &&
                            actor.viewer?.blockedBy != true &&
                            !seenDIDs.contains(did) {
                            seenDIDs.insert(did)
                            actors.append(actor)
                            if actor.viewer?.following != nil {
                                followedDIDs.insert(did)
                            }
                        }
                    }
                }
            }
            
            // Fallback to global suggestions if needed
            if actors.count < 5 {
                let globalParams = AppBskyUnspeccedGetSuggestedOnboardingUsers.Parameters(category: nil, limit: 30)
                let (code, output) = try await client.app.bsky.unspecced.getSuggestedOnboardingUsers(input: globalParams)
                if code == 200, let data = output {
                    for actor in data.actors {
                        let did = actor.did.didString()
                        if did != appState.userDID &&
                            actor.viewer?.blocking == nil &&
                            actor.viewer?.muted != true &&
                            actor.viewer?.blockedBy != true &&
                            !seenDIDs.contains(did) {
                            seenDIDs.insert(did)
                            actors.append(actor)
                            if actor.viewer?.following != nil {
                                followedDIDs.insert(did)
                            }
                        }
                    }
                }
            }
            
            await MainActor.run {
                self.suggestedActors = actors
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                logger.error("Failed to load suggested onboarding users: \(error)")
                self.errorMessage = "Unable to load suggested accounts right now."
                self.isLoading = false
            }
        }
    }
    
    private func toggleFollow(for actor: AppBskyActorDefs.ProfileView) {
        let did = actor.did.didString()
        guard !followedDIDs.contains(did) else { return }
        
        followInProgressDIDs.insert(did)
        followedDIDs.insert(did)
        
        Task {
            do {
                let success = try await appState.follow(did: did)
                await MainActor.run {
                    followInProgressDIDs.remove(did)
                    if !success {
                        followedDIDs.remove(did)
                    }
                }
            } catch {
                await MainActor.run {
                    followInProgressDIDs.remove(did)
                    followedDIDs.remove(did)
                    logger.error("Failed to follow user \(did): \(error)")
                }
            }
        }
    }
    
    private func followAll() {
        for actor in suggestedActors {
            let did = actor.did.didString()
            if !followedDIDs.contains(did) {
                toggleFollow(for: actor)
            }
        }
    }
}
