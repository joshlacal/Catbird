import Foundation
import OSLog
import Petrel
import NukeUI
import SwiftUI

/// Onboarding step for discovering and following suggested accounts based on selected interests
public struct OnboardingSuggestedAccountsStep: View {
    @Environment(AppState.self) private var appState
    @Environment(\.displayScale) private var displayScale
    let selectedInterests: [String]
    let onContinue: () -> Void
    let onSkip: () -> Void
    
    @State private var suggestedActors: [AppBskyActorDefs.ProfileView] = []
    @State private var followedDIDs: Set<String> = []
    @State private var followInProgressDIDs: Set<String> = []
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var followAllError: String?
    
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
                    ProgressView("Finding accounts for you…")
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
                if let followAllError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(followAllError)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button {
                            self.followAllError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
                
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
                .modifier(SuggestedAccountsListStyle())
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
                
                Button("Skip for Now") {
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
                LazyImage(request: ImageRequestFactory.avatar(url, pointSize: 44, scale: displayScale)) { state in
                    if let image = state.image {
                        image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Circle().fill(Color.secondary.opacity(0.2))
                    }
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
        let signpost = PerformanceSignposts.beginInterval("OnboardingSuggestedReady")
        defer { PerformanceSignposts.endInterval("OnboardingSuggestedReady", signpost) }

        guard let client = appState.atProtoClient else {
            isLoading = false
            errorMessage = "Suggestions aren’t available right now."
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        let interestIDs = selectedInterests.compactMap(BlueskyInterests.normalizedID)
        let sortedInterestIDs = interestIDs.sorted()
        var categories: [String?] = sortedInterestIDs.isEmpty ? [nil] : sortedInterestIDs.map { Optional($0) }
        if !sortedInterestIDs.isEmpty {
            categories.append(nil)
        }
        
        typealias CategoryResult = (index: Int, actors: [AppBskyActorDefs.ProfileView])
        
        let results: [CategoryResult] = await withTaskGroup(of: CategoryResult?.self) { group in
            for (index, category) in categories.enumerated() {
                group.addTask {
                    let limit = (category == nil) ? 30 : 25
                    let params = AppBskyUnspeccedGetSuggestedOnboardingUsers.Parameters(
                        category: category,
                        limit: limit
                    )
                    do {
                        let (code, output) = try await client.app.bsky.unspecced.getSuggestedOnboardingUsers(input: params)
                        if code == 200, let data = output {
                            return (index: index, actors: data.actors)
                        }
                    } catch {
                        // Category failure handled gracefully
                    }
                    return nil
                }
            }
            
            var collected: [CategoryResult] = []
            for await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected.sorted { $0.index < $1.index }
        }
        
        var actors: [AppBskyActorDefs.ProfileView] = []
        var seenDIDs = Set<String>()
        var initialFollowed = Set<String>()
        
        for result in results where result.index < (sortedInterestIDs.isEmpty ? 1 : sortedInterestIDs.count) {
            for actor in result.actors {
                let did = actor.did.didString()
                if did != appState.userDID &&
                    actor.viewer?.blocking == nil &&
                    actor.viewer?.muted != true &&
                    actor.viewer?.blockedBy != true &&
                    !seenDIDs.contains(did) {
                    seenDIDs.insert(did)
                    actors.append(actor)
                    if actor.viewer?.following != nil {
                        initialFollowed.insert(did)
                    }
                }
            }
        }
        
        if actors.count < 5, let globalResult = results.first(where: { $0.index == categories.count - 1 }) {
            for actor in globalResult.actors {
                let did = actor.did.didString()
                if did != appState.userDID &&
                    actor.viewer?.blocking == nil &&
                    actor.viewer?.muted != true &&
                    actor.viewer?.blockedBy != true &&
                    !seenDIDs.contains(did) {
                    seenDIDs.insert(did)
                    actors.append(actor)
                    if actor.viewer?.following != nil {
                        initialFollowed.insert(did)
                    }
                }
            }
        }
        
        if actors.isEmpty {
            self.errorMessage = "Couldn’t load suggested accounts. Try again."
            self.isLoading = false
        } else {
            self.suggestedActors = actors
            self.followedDIDs.formUnion(initialFollowed)
            self.isLoading = false
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
        let actorsToFollow = suggestedActors.filter { !followedDIDs.contains($0.did.didString()) }
        guard !actorsToFollow.isEmpty else { return }
        
        followAllError = nil
        guard let client = appState.atProtoClient else {
            followAllError = "Couldn’t follow accounts. Please try again."
            return
        }
        
        let toFollowDIDs = actorsToFollow.map { $0.did.didString() }
        let toFollowSet = Set(toFollowDIDs)
        followInProgressDIDs.formUnion(toFollowSet)
        followedDIDs.formUnion(toFollowSet)
        
        Task { @MainActor in
            let signpost = PerformanceSignposts.beginInterval("FollowAllDone")
            defer { PerformanceSignposts.endInterval("FollowAllDone", signpost) }
            
            let chunkSize = 50
            let chunks = stride(from: 0, to: actorsToFollow.count, by: chunkSize).map {
                Array(actorsToFollow[$0..<min($0 + chunkSize, actorsToFollow.count)])
            }
            
            for (chunkIndex, chunk) in chunks.enumerated() {
                let chunkDIDs = chunk.map { $0.did.didString() }
                do {
                    let subjectDIDs = chunk.compactMap { try? DID(didString: $0.did.didString()) }
                    let creates = try StarterPackService.shared.buildFollowWrites(subjectDIDs: subjectDIDs, via: nil)
                    let writes = creates.map { ComAtprotoRepoApplyWrites.InputWritesUnion($0) }
                    
                    let input = try ComAtprotoRepoApplyWrites.Input(
                        repo: ATIdentifier(string: appState.userDID),
                        validate: true,
                        writes: writes
                    )
                    
                    let (responseCode, _) = try await client.com.atproto.repo.applyWrites(input: input)
                    guard responseCode == 200 else {
                        throw NSError(
                            domain: "OnboardingSuggestedAccounts",
                            code: responseCode,
                            userInfo: [NSLocalizedDescriptionKey: "applyWrites failed with code \(responseCode)"]
                        )
                    }
                    
                    // Batch succeeded: remove from in-progress
                    followInProgressDIDs.subtract(chunkDIDs)
                } catch {
                    logger.error("Failed batch follow at chunk \(chunkIndex): \(error.localizedDescription)")
                    // Roll back this failed chunk and all remaining chunks
                    for remainingChunk in chunks[chunkIndex...] {
                        let remainingDIDs = remainingChunk.map { $0.did.didString() }
                        followInProgressDIDs.subtract(remainingDIDs)
                        followedDIDs.subtract(remainingDIDs)
                    }
                    followAllError = "Couldn’t follow everyone. Try again."
                    break
                }
            }
            
            // Invalidate following cache once for the entire batch operation
            appState.graphManager.invalidateCache(for: .relationshipChanged, cacheTypes: .following)
        }
    }
}

private struct SuggestedAccountsListStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.listStyle(.insetGrouped)
        #else
        content.listStyle(.inset)
        #endif
    }
}
