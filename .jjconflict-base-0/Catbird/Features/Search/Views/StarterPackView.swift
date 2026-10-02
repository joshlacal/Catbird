//
//  StarterPackView.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G56).
//

import SwiftUI
import Petrel
import OSLog

/// View for displaying a starter pack's details, member profiles, suggested feeds, and posts.
struct StarterPackView: View {
    enum StarterPackTab: String, CaseIterable, Identifiable {
        case people = "People"
        case feeds = "Feeds"
        case posts = "Posts"
        
        var id: String { rawValue }
    }
    
    let uri: ATProtocolURI
    @State private var starterPack: AppBskyGraphDefs.StarterPackView?
    @State private var isLoading = true
    @State private var error: Error?
    @Binding var path: NavigationPath
    @Environment(AppState.self) private var appState
    
    // Tabs state
    @State private var selectedTab: StarterPackTab = .people
    
    // Profiles state & Pagination
    @State private var allProfiles: [AppBskyGraphDefs.ListItemView] = []
    @State private var cursor: String?
    @State private var isLoadingMore = false
    
    // Follow All State
    @State private var isFollowingAll = false
    @State private var followAllError: String?
    @State private var locallyFollowedDIDs: Set<String> = []
    
    // Action Sheets & Dialogs
    @State private var showingShareSheet = false
    @State private var showingQRCode = false
    @State private var showingEditWizard = false
    @State private var showingCreateListAlert = false
    @State private var showingCreateListSheet = false
    @State private var isCloningMembers = false
    @State private var cloneMembersMessage: String?
    @State private var showingCloneMessageAlert = false
    
    var body: some View {
        Group {
            if isLoading {
                loadingView
            } else if let error = error {
                errorView(error)
            } else if let pack = starterPack {
                packContentView(pack)
            } else {
                notFoundView
            }
        }
        .navigationTitle("Starter Pack")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let pack = starterPack {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingShareSheet = true
                        } label: {
                            Label("Share Starter Pack", systemImage: "square.and.arrow.up")
                        }
                        
                        Button {
                            showingQRCode = true
                        } label: {
                            Label("Show QR Code", systemImage: "qrcode")
                        }
                        
                        if pack.list?.uri != nil {
                            Button {
                                showingCreateListAlert = true
                            } label: {
                                Label("Create List from Starter Pack", systemImage: "list.bullet.rectangle")
                            }
                        }
                        
                        if isOwner(pack) {
                            Divider()
                            Button {
                                showingEditWizard = true
                            } label: {
                                Label("Edit Starter Pack", systemImage: "pencil")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Create List from Starter Pack", isPresented: $showingCreateListAlert) {
            Button("Create List") {
                showingCreateListSheet = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will create a new independent curated list containing all the members in this starter pack. You can edit the list name and description before saving.")
        }
        .alert("List Created", isPresented: $showingCloneMessageAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cloneMembersMessage ?? "")
        }
        .sheet(isPresented: $showingShareSheet) {
            if let pack = starterPack {
                StarterPackShareView(starterPack: pack)
            }
        }
        .sheet(isPresented: $showingQRCode) {
            if let pack = starterPack {
                let handle = pack.creator.handle
                let rkey = pack.uri.recordKey ?? "default"
                let shareURL = URL(string: "https://bsky.app/start/\(handle)/\(rkey)")!
                StarterPackQRCodeCard(starterPack: pack, shareURL: shareURL)
            }
        }
        .sheet(isPresented: $showingEditWizard) {
            if let pack = starterPack {
                StarterPackWizardView(mode: .edit(existingPack: pack)) { _ in
                    Task {
                        await fetchStarterPack()
                    }
                }
            }
        }
        .sheet(isPresented: $showingCreateListSheet) {
            if let pack = starterPack {
                let packName: String = {
                    if case .knownType(let recordValue) = pack.record,
                       let starterpack = recordValue as? AppBskyGraphStarterpack {
                        return starterpack.name
                    }
                    return "Copied List"
                }()
                let packDescription: String = {
                    if case .knownType(let recordValue) = pack.record,
                       let starterpack = recordValue as? AppBskyGraphStarterpack {
                        return starterpack.description ?? ""
                    }
                    return ""
                }()
                
                CreateListView(
                    initialName: packName,
                    initialDescription: packDescription,
                    initialPurpose: .appbskygraphdefscuratelist
                ) { createdList in
                    await handleListCreated(createdList, from: pack)
                }
            }
        }
        .task {
            await fetchStarterPack()
        }
    }
    
    // MARK: - List Cloning Helper
    
    private func handleListCreated(_ createdList: AppBskyGraphDefs.ListView, from pack: AppBskyGraphDefs.StarterPackView) async {
        let userDID = appState.userDID
        guard let sourceListUri = pack.list?.uri,
              let client = appState.atProtoClient,
              !userDID.isEmpty else {
            path.append(NavigationDestination.list(createdList.uri))
            return
        }
        
        isCloningMembers = true
        defer { isCloningMembers = false }
        
        do {
            logger.info("Copying members from starter pack backing list \(sourceListUri.uriString()) to curated list \(createdList.uri.uriString())")
            let copiedCount = try await StarterPackService.shared.copyMembersToCuratedList(
                client: client,
                sourceListUri: sourceListUri,
                targetListUri: createdList.uri,
                accountDID: userDID
            )
            logger.info("Successfully copied \(copiedCount) members")
        } catch {
            logger.error("Failed to copy members to list: \(error.localizedDescription)")
            cloneMembersMessage = "Your list was created, but copying members encountered an error: \(error.localizedDescription)"
            showingCloneMessageAlert = true
        }
        
        path.append(NavigationDestination.list(createdList.uri))
    }
    // MARK: - Loading & Error States
    
    private var loadingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
            
            Text("Loading starter pack...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func errorView(_ error: Error) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .appFont(size: 48)
                .foregroundColor(.orange)
            
            Text("Error loading starter pack")
                .appFont(AppTextRole.headline)
            
            Text(error.localizedDescription)
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                Task {
                    isLoading = true
                    self.error = nil
                    await fetchStarterPack()
                }
            } label: {
                Text("Try Again")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var notFoundView: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .appFont(size: 48)
                .foregroundColor(.secondary)
            
            Text("Starter Pack Not Found")
                .appFont(AppTextRole.headline)
            
            Text("This starter pack might have been deleted or is unavailable.")
                .appFont(AppTextRole.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button {
                path.removeLast()
            } label: {
                Text("Go Back")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundColor(.white)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Main Content View
    
    private func packContentView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        VStack(spacing: 10) {
            // Header with creator info, description, stats, follow all button, and tabs
            VStack(alignment: .leading, spacing: 12) {
                headerView(pack)
                
                if case .knownType(let recordValue) = pack.record,
                   let starterpack = recordValue as? AppBskyGraphStarterpack,
                   let description = starterpack.description,
                   !description.isEmpty {
                    Text(description)
                        .appFont(AppTextRole.subheadline)
                        .padding(.horizontal)
                }
                
                statsView(pack)
                
                followAllButton(pack)
                
                if let error = followAllError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .appFont(AppTextRole.caption)
                            .foregroundColor(.red)
                        Spacer()
                        Button("Dismiss") {
                            followAllError = nil
                        }
                        .appFont(AppTextRole.caption)
                    }
                    .padding(.horizontal)
                }
                
                tabPicker(pack)
            }
            .padding(.top, 8)
            
            // Tab Content
            Group {
                switch selectedTab {
                case .people:
                    peopleTabContent(pack)
                case .feeds:
                    feedsTabContent(pack)
                case .posts:
                    postsTabContent(pack)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Header & Stats
    
    private func headerView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        HStack(spacing: 16) {
            AsyncProfileImage(url: URL(string: pack.creator.avatar?.uriString() ?? ""), size: 54)
                .padding(.leading)
            
            VStack(alignment: .leading, spacing: 4) {
                if case .knownType(let recordValue) = pack.record,
                   let starterpack = recordValue as? AppBskyGraphStarterpack {
                    Text(starterpack.name)
                        .appFont(AppTextRole.title3)
                        .fontWeight(.bold)
                        .lineLimit(1)
                } else {
                    Text("Starter Pack")
                        .appFont(AppTextRole.title3)
                        .fontWeight(.bold)
                }
                
                Text("Created by @\(pack.creator.handle)")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
        }
    }
    
    private func statsView(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        HStack(spacing: 20) {
            VStack {
                let profileCount = pack.list?.listItemCount ?? allProfiles.count
                Text("\(profileCount)")
                    .appFont(AppTextRole.headline)
                
                Text("Profiles")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack {
                Text("\(pack.feeds?.count ?? 0)")
                    .appFont(AppTextRole.headline)
                
                Text("Feeds")
                    .appFont(AppTextRole.caption)
                    .foregroundColor(.secondary)
            }
            
            if let joinedWeekCount = pack.joinedWeekCount {
                VStack {
                    Text("\(joinedWeekCount)")
                        .appFont(AppTextRole.headline)
                    
                    Text("Joined this week")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if let joinedAllTimeCount = pack.joinedAllTimeCount {
                VStack {
                    Text("\(joinedAllTimeCount)")
                        .appFont(AppTextRole.headline)
                    
                    Text("All-time joins")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.systemGray6)
        .cornerRadius(12)
        .padding(.horizontal)
    }
    
    // MARK: - Follow All Button
    
    private func isOwner(_ pack: AppBskyGraphDefs.StarterPackView) -> Bool {
        let userDID = appState.userDID
        guard !userDID.isEmpty else { return false }
        return pack.creator.did.didString() == userDID
    }
    
    private var eligibleMembersCount: Int {
        let currentDID = appState.userDID
        guard !currentDID.isEmpty else { return 0 }
        return allProfiles.filter { item in
            let did = item.subject.did.didString()
            if locallyFollowedDIDs.contains(did) { return false }
            return StarterPackService.shared.isEligibleToFollow(
                subject: item.subject,
                currentAccountDID: currentDID
            )
        }.count
    }
    
    @ViewBuilder
    private func followAllButton(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        if !isOwner(pack) {
            let count = eligibleMembersCount
            let allFollowed = count == 0 && !allProfiles.isEmpty
            
            Button {
                Task {
                    await followAllAction(pack)
                }
            } label: {
                HStack(spacing: 8) {
                    if isFollowingAll {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                        Text("Following...")
                            .fontWeight(.semibold)
                    } else if allFollowed {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                        Text("All Followed")
                            .fontWeight(.semibold)
                    } else {
                        Image(systemName: "person.badge.plus")
                        Text(count > 0 ? "Follow All (\(count))" : "Follow All")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(allFollowed ? Color.gray.opacity(0.3) : Color.accentColor)
                )
                .foregroundColor(allFollowed ? .secondary : .white)
            }
            .buttonStyle(.plain)
            .disabled(isFollowingAll || allFollowed)
            .padding(.horizontal)
        }
    }
    
    private func followAllAction(_ pack: AppBskyGraphDefs.StarterPackView) async {
        let currentDID = appState.userDID
        guard let client = appState.atProtoClient,
              !currentDID.isEmpty else { return }
        isFollowingAll = true
        followAllError = nil
        defer { isFollowingAll = false }
        
        do {
            var membersToFollow = allProfiles
            if let listUri = pack.list?.uri {
                if cursor != nil || (pack.list?.listItemCount ?? 0) > allProfiles.count || allProfiles.isEmpty {
                    let fullList = try await StarterPackService.shared.fetchAllMembers(client: client, listUri: listUri)
                    membersToFollow = fullList
                }
            }
            let eligible = StarterPackService.shared.filterEligibleMembers(
                membersToFollow,
                currentAccountDID: currentDID
            ).filter { !locallyFollowedDIDs.contains($0.subject.did.didString()) }
            
            guard !eligible.isEmpty else { return }
            
            try await StarterPackService.shared.followAll(
                client: client,
                members: eligible,
                starterPack: pack,
                currentAccountDID: currentDID
            )
            
            for item in eligible {
                locallyFollowedDIDs.insert(item.subject.did.didString())
            }
            
            await appState.refreshSocialGraph()
        } catch {
            followAllError = error.localizedDescription
            logger.error("Failed to follow all: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Tab Selector & Tabs
    
    private func availableTabs(_ pack: AppBskyGraphDefs.StarterPackView) -> [StarterPackTab] {
        if pack.list?.uri != nil {
            return [.people, .feeds, .posts]
        } else {
            return [.people, .feeds]
        }
    }
    
    private func tabPicker(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        let tabs = availableTabs(pack)
        return Picker("Tabs", selection: $selectedTab) {
            ForEach(tabs) { tab in
                switch tab {
                case .people:
                    let count = pack.list?.listItemCount ?? allProfiles.count
                    Text("People (\(count))").tag(tab)
                case .feeds:
                    let count = pack.feeds?.count ?? 0
                    Text("Feeds (\(count))").tag(tab)
                case .posts:
                    Text("Posts").tag(tab)
                }
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }
    
    // MARK: - People Tab Content
    
    private func peopleTabContent(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if allProfiles.isEmpty && !isLoadingMore {
                    VStack(spacing: 12) {
                        Image(systemName: "person.2.slash")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No Profiles")
                            .appFont(AppTextRole.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    ForEach(Array(allProfiles.enumerated()), id: \.element.uri) { index, item in
                        memberRow(item: item, index: index)
                    }
                    
                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .padding()
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private func memberRow(item: AppBskyGraphDefs.ListItemView, index: Int) -> some View {
        let subject = item.subject
        let didString = subject.did.didString()
        let isLocallyFollowed = locallyFollowedDIDs.contains(didString)
        let isServerFollowing = subject.viewer?.following != nil
        let isFollowing = isLocallyFollowed || isServerFollowing
        let isSelf = didString == appState.userDID
        
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    path.append(NavigationDestination.profile(didString))
                } label: {
                    HStack(spacing: 12) {
                        AsyncProfileImage(url: URL(string: subject.avatar?.uriString() ?? ""), size: 44)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subject.displayName ?? "@\(subject.handle)")
                                .appFont(AppTextRole.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            
                            Text("@\(subject.handle)")
                                .appFont(AppTextRole.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            
                            if let description = subject.description, !description.isEmpty {
                                Text(description)
                                    .appFont(AppTextRole.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                if !isSelf {
                    Button {
                        Task {
                            await toggleMemberFollow(did: didString, isFollowing: isFollowing)
                        }
                    } label: {
                        Text(isFollowing ? "Following" : "Follow")
                            .appFont(AppTextRole.caption)
                            .fontWeight(.medium)
                            .foregroundColor(isFollowing ? .secondary : .white)
                            .padding(.vertical, 5)
                            .padding(.horizontal, 12)
                            .background(
                                Capsule()
                                    .fill(isFollowing ? Color.gray.opacity(0.2) : Color.accentColor)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            
            if index < allProfiles.count - 1 {
                Divider()
                    .padding(.leading, 68)
            }
        }
        .onAppear {
            if index == allProfiles.count - 3 {
                Task {
                    await loadMoreProfiles()
                }
            }
        }
    }
    
    private func toggleMemberFollow(did: String, isFollowing: Bool) async {
        do {
            if isFollowing {
                try await appState.unfollow(did: did)
                locallyFollowedDIDs.remove(did)
            } else {
                try await appState.follow(did: did)
                locallyFollowedDIDs.insert(did)
            }
        } catch {
            logger.error("Error toggling follow for \(did): \(error.localizedDescription)")
        }
    }
    
    // MARK: - Feeds Tab Content
    
    private func feedsTabContent(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let feeds = pack.feeds, !feeds.isEmpty {
                    ForEach(feeds, id: \.uri) { feed in
                        feedRow(feed: feed, isLast: feed.uri == feeds.last?.uri)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "rectangle.grid.1x2")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("No Suggested Feeds")
                            .appFont(AppTextRole.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private func feedRow(feed: AppBskyFeedDefs.GeneratorView, isLast: Bool) -> some View {
        Button {
            path.append(NavigationDestination.feed(feed.uri))
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if let avatar = feed.avatar {
                        AsyncImage(url: URL(string: avatar.uriString())) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 44, height: 44)
                            .overlay(
                                Image(systemName: "rectangle.grid.1x2")
                                    .foregroundColor(.gray)
                            )
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(feed.displayName)
                            .appFont(AppTextRole.headline)
                            .foregroundColor(.primary)
                        
                        Text("By @\(feed.creator.handle)")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                        
                        if let description = feed.description, !description.isEmpty {
                            Text(description)
                                .appFont(AppTextRole.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .appFont(AppTextRole.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                
                if !isLast {
                    Divider()
                        .padding(.leading, 68)
                }
            }
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Posts Tab Content
    
    @ViewBuilder
    private func postsTabContent(_ pack: AppBskyGraphDefs.StarterPackView) -> some View {
        if let listUri = pack.list?.uri {
            FeedView(
                fetch: .list(listUri),
                path: $path,
                selectedTab: .constant(0)
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36))
                    .foregroundColor(.secondary)
                Text("No Backing List")
                    .appFont(AppTextRole.headline)
                    .foregroundColor(.secondary)
                Text("Posts cannot be loaded because this starter pack has no backing member list.")
                    .appFont(AppTextRole.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // MARK: - Network Fetching
    
    private func fetchStarterPack() async {
        guard let client = appState.atProtoClient else {
            error = NSError(domain: "StarterPackView", code: 0, userInfo: [NSLocalizedDescriptionKey: "Not logged in"])
            isLoading = false
            return
        }
        
        isLoading = true
        error = nil
        allProfiles = []
        cursor = nil
        
        do {
            let input = AppBskyGraphGetStarterPack.Parameters(starterPack: uri)
            let response = try await client.app.bsky.graph.getStarterPack(input: input)
            
            if let packData = response.data {
                self.starterPack = packData.starterPack
                
                if let listUri = packData.starterPack.list?.uri {
                    await loadProfileList(client: client, listUri: listUri, cursor: nil)
                }
            } else {
                self.error = NSError(domain: "StarterPackView", code: 0, userInfo: [NSLocalizedDescriptionKey: "No data returned"])
            }
        } catch {
            self.error = error
        }
        
        isLoading = false
    }
    
    private func loadProfileList(client: ATProtoClient, listUri: ATProtocolURI, cursor: String?) async {
        if cursor == nil {
            allProfiles = []
            self.cursor = nil
        }
        
        do {
            let input = AppBskyGraphGetList.Parameters(
                list: listUri,
                limit: 30,
                cursor: cursor
            )
            let (responseCode, data) = try await client.app.bsky.graph.getList(input: input)
            
            if (200...299).contains(responseCode), let data = data {
                if cursor == nil {
                    allProfiles = data.items
                } else {
                    allProfiles.append(contentsOf: data.items)
                }
                self.cursor = data.cursor
            }
        } catch {
            logger.error("Error loading profile list: \(error.localizedDescription)")
        }
    }
    
    private func loadMoreProfiles() async {
        guard let pack = starterPack,
              let listUri = pack.list?.uri,
              let currentCursor = cursor,
              !isLoadingMore,
              let client = appState.atProtoClient else {
            return
        }
        
        isLoadingMore = true
        await loadProfileList(client: client, listUri: listUri, cursor: currentCursor)
        isLoadingMore = false
    }
}

#Preview("StarterPackView") {
  @Previewable @State var path = NavigationPath()
  NavigationStack(path: $path) {
    StarterPackView(
      uri: try! ATProtocolURI(uriString: "at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.graph.starterpack/example"),
      path: $path
    )
  }
  .previewWithAuthenticatedState()
}
