import Foundation
import OSLog
import Petrel
import SwiftUI

/// Logged-out landing screen for starter pack links, populating details anonymously and bridging to sign-up
public struct StarterPackLandingView: View {
    let flowID: UUID
    let starterPackURI: ATProtocolURI
    var onDismiss: (() -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStateManager.self) private var appStateManager
    @State private var starterPack: AppBskyGraphDefs.StarterPackView?
    @State private var sampledMembers: [AppBskyGraphDefs.ListItemView] = []
    @State private var totalMemberCount: Int = 0
    @State private var isLoading: Bool = true
    @State private var errorMessage: String?
    @State private var showSignupSheet: Bool = false
    @State private var showLoginSheet: Bool = false
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackLandingView")
    
    public init(flowID: UUID = UUID(), starterPackURI: ATProtocolURI, onDismiss: (() -> Void)? = nil) {
        self.flowID = flowID
        self.starterPackURI = starterPackURI
        self.onDismiss = onDismiss
    }
    
    public init?(flowID: UUID = UUID(), uriString: String, onDismiss: (() -> Void)? = nil) {
        guard let uri = try? ATProtocolURI(uriString: uriString) else { return nil }
        self.flowID = flowID
        self.starterPackURI = uri
        self.onDismiss = onDismiss
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    ProgressView("Loading starter pack...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let error = errorMessage {
                    unavailableView(message: error)
                } else if let pack = starterPack {
                    contentView(pack)
                }
            }
            .navigationTitle("Starter Pack")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        handleDismiss()
                    }
                }
            }
            .sheet(isPresented: $showSignupSheet) {
                LoginView(initialAuthMode: .signup)
                    .environment(appStateManager)
            }
            .sheet(isPresented: $showLoginSheet) {
                LoginView(initialAuthMode: .login)
                    .environment(appStateManager)
            }
            .onChange(of: appStateManager.lifecycle) { _, newLifecycle in
                if newLifecycle.isAuthenticated {
                    handleDismiss()
                }
            }
            .task {
                StarterPackOnboardingManager.shared.setActiveFlowID(flowID)
                await fetchStarterPack()
            }
        }
    }
    
    // MARK: - Main Content View
    
    private func contentView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    // Creator Info
                    HStack(spacing: 8) {
                        if let avatar = pack.creator.avatar?.uriString(), let url = URL(string: avatar) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.secondary.opacity(0.2))
                            }
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        }
                        
                        Text("Curated by \(pack.creator.displayName ?? "@" + pack.creator.handle.description)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    
                    let (packName, packDesc): (String, String?) = {
                        if case .knownType(let recordValue) = pack.record,
                           let starterpack = recordValue as? AppBskyGraphStarterpack {
                            return (starterpack.name, starterpack.description)
                        }
                        return ("Starter Pack", nil)
                    }()
                    
                    Text(packName)
                        .font(.title)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    if let description = packDesc, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .padding(.top, 16)
                // Stats Card
                HStack(spacing: 32) {
                    VStack(spacing: 4) {
                        Text("\(totalMemberCount)")
                            .font(.title2.bold())
                        Text("People")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    if let feeds = pack.feeds, !feeds.isEmpty {
                        Divider().frame(height: 32)
                        VStack(spacing: 4) {
                            Text("\(feeds.count)")
                                .font(.title2.bold())
                            Text("Feeds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    if let joinedCount = pack.joinedAllTimeCount {
                        Divider().frame(height: 32)
                        VStack(spacing: 4) {
                            Text("\(joinedCount)")
                                .font(.title2.bold())
                            Text("Joined")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                
                // Sampled Members Section
                if !sampledMembers.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Included Accounts")
                            .font(.headline)
                            .padding(.horizontal, 24)
                        
                        LazyVStack(spacing: 8) {
                            ForEach(sampledMembers, id: \.uri) { item in
                                memberRow(item.subject)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }
                
                // Feeds Section
                if let feeds = pack.feeds, !feeds.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Included Feeds")
                            .font(.headline)
                            .padding(.horizontal, 24)
                        
                        ForEach(feeds, id: \.uri) { feed in
                            feedRow(feed)
                        }
                        .padding(.horizontal, 24)
                    }
                }
                
                // Action Buttons
                VStack(spacing: 12) {
                    Button(action: joinStarterPackAction) {
                        Text("Join this starter pack")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    Button(action: signinWithPackAction) {
                        Text("Already have an account? Sign in")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    .padding(.top, 2)
                    
                    Button(action: signupWithoutPackAction) {
                        Text("Create an account without this starter pack")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
    }
    
    // MARK: - Row Views
    
    private func memberRow(_ member: AppBskyActorDefs.ProfileView) -> some View {
        HStack(spacing: 12) {
            if let avatar = member.avatar?.uriString(), let url = URL(string: avatar) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Color.secondary.opacity(0.2))
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Text(member.displayName?.prefix(1) ?? member.handle.description.prefix(1))
                            .font(.caption.bold())
                    )
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName ?? member.handle.description)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("@\(member.handle.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    private func feedRow(_ feed: AppBskyFeedDefs.GeneratorView) -> some View {
        HStack(spacing: 12) {
            if let avatar = feed.avatar?.uriString(), let url = URL(string: avatar) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .overlay(Image(systemName: "number").foregroundStyle(.accent))
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(feed.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                if let creator = feed.creator.displayName {
                    Text("by \(creator)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Unavailable View
    
    private func unavailableView(message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("Starter Pack Unavailable")
                .font(.title2.bold())
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            VStack(spacing: 12) {
                Button(action: signupWithoutPackAction) {
                    Text("Create an account without this starter pack")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                Button("Back") {
                    handleDismiss()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            
            Spacer()
        }
    }
    
    // MARK: - Actions
    
    private func handleDismiss() {
        if !appStateManager.lifecycle.isAuthenticated {
            StarterPackOnboardingManager.shared.clearPendingContext()
        }
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
    
    private func joinStarterPackAction() {
        guard let pack = starterPack else { return }
        let packName: String = {
            if case .knownType(let recordValue) = pack.record,
               let starterpack = recordValue as? AppBskyGraphStarterpack {
                return starterpack.name
            }
            return "Starter Pack"
        }()
        
        let pending = StarterPackPendingContext(
            flowID: flowID,
            uri: pack.uri.uriString(),
            cid: pack.cid.string,
            name: packName,
            creatorDID: pack.creator.did.didString()
        )
        StarterPackOnboardingManager.shared.setPendingContext(pending)
        logger.info("Saved pending starter pack context for join: \(pack.uri.uriString()) (flow: \(self.flowID.uuidString))")
        showSignupSheet = true
    }
    private func signinWithPackAction() {
        guard let pack = starterPack else { return }
        let packName: String = {
            if case .knownType(let recordValue) = pack.record,
               let starterpack = recordValue as? AppBskyGraphStarterpack {
                return starterpack.name
            }
            return "Starter Pack"
        }()
        
        let pending = StarterPackPendingContext(
            flowID: flowID,
            uri: pack.uri.uriString(),
            cid: pack.cid.string,
            name: packName,
            creatorDID: pack.creator.did.didString()
        )
        StarterPackOnboardingManager.shared.setPendingContext(pending)
        logger.info("Saved pending starter pack context for sign-in: \(pack.uri.uriString()) (flow: \(self.flowID.uuidString))")
    }

    private func signupWithoutPackAction() {
        StarterPackOnboardingManager.shared.clearPendingContext()
        logger.info("Cleared pending starter pack context; proceeding to standard signup")
        showSignupSheet = true
    }
    
    // MARK: - Data Fetching
    
    private func fetchStarterPack() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let unauthClient = await ATProtoClient(baseURL: URL(string: "https://public.api.bsky.app")!)
            let params = AppBskyGraphGetStarterPack.Parameters(starterPack: starterPackURI)
            let (code, output) = try await unauthClient.app.bsky.graph.getStarterPack(input: params)
            
            guard code == 200, let packData = output else {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = "This starter pack is unavailable or may have been deleted."
                    StarterPackOnboardingManager.shared.clearPendingContext()
                }
                return
            }
            
            var members: [AppBskyGraphDefs.ListItemView] = []
            var count = 0
            
            if let listUri = packData.starterPack.list?.uri {
                let listParams = AppBskyGraphGetList.Parameters(list: listUri, limit: 12, cursor: nil)
                let (listCode, listOutput) = try await unauthClient.app.bsky.graph.getList(input: listParams)
                if listCode == 200, let listData = listOutput {
                    members = listData.items
                    count = packData.starterPack.list?.listItemCount ?? listData.items.count
                }
            }
            
            await MainActor.run {
                self.starterPack = packData.starterPack
                self.sampledMembers = members
                self.totalMemberCount = count
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.logger.error("Failed to fetch starter pack: \(error)")
                self.errorMessage = "Unable to load starter pack details. Please check your internet connection."
                self.isLoading = false
                StarterPackOnboardingManager.shared.clearPendingContext()
            }
        }
    }
}
