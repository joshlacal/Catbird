//
//  ShareToChatActivity.swift
//  Catbird
//
//  Created for sharing posts to Bluesky chat conversations
//

#if os(iOS)
import UIKit
import SwiftUI
import Petrel
import OSLog

/// Custom UIActivity for sharing posts to chat
class ShareToChatActivity: UIActivity {
    
    private let post: AppBskyFeedDefs.PostView
    private let appState: AppState
    
    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
        self.post = post
        self.appState = appState
        super.init()
    }
    
    override var activityType: UIActivity.ActivityType? {
        return UIActivity.ActivityType("com.catbird.share-to-chat")
    }
    
    override var activityTitle: String? {
        return "Share to Chat"
    }
    
    override var activityImage: UIImage? {
        return UIImage(systemName: "bubble.left.and.bubble.right")
    }
    
    override class var activityCategory: UIActivity.Category {
        return .action
    }
    
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        return appState.isAuthenticated
    }
    
    override func prepare(withActivityItems activityItems: [Any]) {
        // Find the ShareablePost item
        for item in activityItems {
            if let shareablePost = item as? ShareablePost {
                // Store for later use
                break
            }
        }
    }
    
    override func perform() {
        activityDidFinish(true)
    }
    
    override var activityViewController: UIViewController? {
        let chatSelectionView = ModernChatSelectionView(post: post, appState: appState) { [weak self] in
            self?.activityDidFinish(true)
        }
        .environment(appState)
        
        let hostingController = UIHostingController(rootView: chatSelectionView)
        hostingController.modalPresentationStyle = .pageSheet
        
        if let sheet = hostingController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
        
        return hostingController
    }
}

/// Wrapper for sharing post data
class ShareablePost: NSObject, UIActivityItemSource {
    let post: AppBskyFeedDefs.PostView
    
    init(post: AppBskyFeedDefs.PostView) {
        self.post = post
        super.init()
    }
    
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        let username = post.author.handle
        let recordKey = post.uri.recordKey ?? ""
        return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)") ?? ""
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        if activityType?.rawValue == "com.catbird.share-to-chat" {
            return post
        }
        
        let username = post.author.handle
        let recordKey = post.uri.recordKey ?? ""
        return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)")
    }
}

// MARK: - Modern iOS 18 Chat Selection View

@available(iOS 18.0, *)
struct ModernChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void
    
    @State private var searchText = ""
    @State private var messageText = ""
    @State private var selectedRecipient: RecipientSelection? = nil
    @State private var isSending = false
    @State private var isSearching = false
    @State private var searchResults: [AppBskyActorDefs.ProfileView] = []
    @State private var showingPostPreview = false
    @State private var keyboardHeight: CGFloat = 0
    @FocusState private var isMessageFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    private let logger = Logger(subsystem: "blue.catbird", category: "ShareToChat")
    
    enum RecipientSelection: Equatable {
        case conversation(ChatBskyConvoDefs.ConvoView)
        case profile(AppBskyActorDefs.ProfileView)
        
        var displayName: String {
            switch self {
            case .conversation(let convo):
                if let member = convo.members.first {
                    return member.displayName ?? "@\(member.handle)"
                }
                return "Unknown"
            case .profile(let profile):
                return profile.displayName ?? "@\(profile.handle)"
            }
        }
        
        var handle: String {
            switch self {
            case .conversation(let convo):
                if let member = convo.members.first {
                    return "@\(member.handle)"
                }
                return ""
            case .profile(let profile):
                return "@\(profile.handle)"
            }
        }
        
        var avatarURL: String? {
            switch self {
            case .conversation(let convo):
                return convo.members.first?.avatar?.uriString()
            case .profile(let profile):
                return profile.avatar?.uriString()
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.primaryBackground(themeManager: appState.themeManager, currentScheme: colorScheme)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // Modern search bar
                    searchBar
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    // Selected recipient chip
                    if let recipient = selectedRecipient {
                        selectedRecipientView(recipient)
                            .transition(.asymmetric(
                                insertion: .push(from: .bottom).combined(with: .opacity),
                                removal: .push(from: .top).combined(with: .opacity)
                            ))
                    }
                    
                    // Message composer
                    if selectedRecipient != nil {
                        messageComposer
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    
                    // Recipients list
                    recipientsList
                }
            }
            .navigationTitle("Share to Chat")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        onDismiss()
                    }
                    .disabled(isSending)
                }
                
                ToolbarItem(placement: .primaryAction) {
                    if selectedRecipient != nil {
                        sendButton
                    }
                }
            }
            .sheet(isPresented: $showingPostPreview) {
                PostPreviewSheet(post: post)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
            .animation(.smooth(duration: 0.3), value: selectedRecipient)
            .animation(.smooth(duration: 0.2), value: searchText)
        }
        .onChange(of: searchText) { _, newValue in
            performSearch(newValue)
        }
        .onAppear {
            isMessageFieldFocused = false
        }
    }
    
    // MARK: - View Components
    
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .fontWeight(.medium)
            
            TextField("Search people or conversations", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
            
            if !searchText.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        searchText = ""
                        searchResults = []
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }
    
    private func selectedRecipientView(_ recipient: RecipientSelection) -> some View {
        HStack(spacing: 12) {
            // Avatar
            Group {
                if let avatarURL = recipient.avatarURL,
                   let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Circle()
                            .fill(.quaternary)
                    }
                } else {
                    Circle()
                        .fill(.quaternary)
                        .overlay {
                            Text(recipient.displayName.prefix(1))
                                .font(.callout.bold())
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            
            VStack(alignment: .leading, spacing: 2) {
                Text(recipient.displayName)
                    .font(.subheadline.weight(.medium))
                Text(recipient.handle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    selectedRecipient = nil
                    isMessageFieldFocused = false
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.medium)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
    
    private var messageComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Message")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                // Post preview button
                Button {
                    showingPostPreview = true
                } label: {
                    Label("Preview", systemImage: "eye")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.accent)
                }
                
                Text("\(messageText.count)/1000")
                    .font(.caption2)
                    .foregroundStyle(messageText.count > 900 ? .red : Color.dynamicTertiaryBackground(appState.themeManager, currentScheme: colorScheme))
                    .contentTransition(.numericText())
            }
            
            TextEditor(text: $messageText)
                .focused($isMessageFieldFocused)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .frame(minHeight: 80, maxHeight: 120)
                .onChange(of: messageText) { _, newValue in
                    if newValue.count > 1000 {
                        messageText = String(newValue.prefix(1000))
                    }
                }
            
            Text("The post will be attached automatically")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
    
    private var sendButton: some View {
        Button {
            sendMessage()
        } label: {
            if isSending {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text("Send")
                    .fontWeight(.semibold)
            }
        }
        .disabled(isSending)
    }
    
    private var recipientsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Search results
                if !searchText.isEmpty && !searchResults.isEmpty {
                    ForEach(searchResults, id: \.did) { profile in
                        ModernRecipientRow(
                            title: profile.displayName ?? profile.handle.description,
                            subtitle: "@\(profile.handle)",
                            avatarURL: profile.avatar?.uriString(),
                            isSelected: false,
                            showDivider: profile.did != searchResults.last?.did
                        ) {
                            selectProfile(profile)
                        }
                    }
                }
                
                // Existing conversations
                if searchText.isEmpty || (!searchText.isEmpty && !filteredConversations.isEmpty) {
                    if !searchText.isEmpty && !searchResults.isEmpty {
                        sectionHeader("Conversations")
                    }
                    
                    ForEach(filteredConversations) { conversation in
                        if let otherMember = conversation.members.first(where: { $0.did.didString() != appState.currentUserDID }) {
                            ModernRecipientRow(
                                title: otherMember.displayName ?? otherMember.handle.description,
                                subtitle: "@\(otherMember.handle)",
                                avatarURL: otherMember.avatar?.uriString(),
                                isSelected: false,
                                showDivider: conversation.id != filteredConversations.last?.id
                            ) {
                                selectConversation(conversation)
                            }
                        }
                    }
                }
                
                // Empty state
                if filteredConversations.isEmpty && searchResults.isEmpty {
                    emptyState
                }
            }
            .animation(.default, value: searchResults)
            .animation(.default, value: filteredConversations)
        }
        .scrollDismissesKeyboard(.interactively)
    }
    
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.background)
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text(searchText.isEmpty ? "Start typing to search for people" : "No matches found for '\(searchText)'")
        }
        .padding(.vertical, 60)
    }
    
    // MARK: - Helper Methods
    
    private var filteredConversations: [ChatBskyConvoDefs.ConvoView] {
        let conversations = appState.chatManager.acceptedConversations
        
        if searchText.isEmpty {
            return conversations
        }
        
        return conversations.filter { conversation in
            guard let otherMember = conversation.members.first(where: { $0.did.didString() != appState.currentUserDID }) else {
                return false
            }
            
            let displayName = otherMember.displayName ?? ""
            let handle = otherMember.handle.description
            
            return displayName.localizedCaseInsensitiveContains(searchText) ||
                   handle.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func selectProfile(_ profile: AppBskyActorDefs.ProfileView) {
        withAnimation(.smooth(duration: 0.3)) {
            selectedRecipient = .profile(profile)
            searchText = ""
            searchResults = []
            isMessageFieldFocused = true
        }
    }
    
    private func selectConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
        withAnimation(.smooth(duration: 0.3)) {
            selectedRecipient = .conversation(conversation)
            searchText = ""
            isMessageFieldFocused = true
        }
    }
    
    private func performSearch(_ query: String) {
        guard !query.isEmpty, query.count >= 2 else {
            searchResults = []
            return
        }
        
        guard let client = appState.atProtoClient else { return }
        
        Task {
            isSearching = true
            
            do {
                let params = AppBskyActorSearchActors.Parameters(q: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: 10)
                let (responseCode, response) = try await client.app.bsky.actor.searchActors(input: params)
                
                await MainActor.run {
                    isSearching = false
                    
                    guard responseCode >= 200 && responseCode < 300,
                          let results = response?.actors else {
                        return
                    }
                    
                    // Filter out users that already have conversations
                    let existingDids = Set(appState.chatManager.acceptedConversations.flatMap { conv in
                        conv.members.map { $0.did.didString() }
                    })
                    
                    searchResults = results.filter { profile in
                        !existingDids.contains(profile.did.didString())
                    }
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    logger.error("Search error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func sendMessage() {
        guard let recipient = selectedRecipient else { return }
        
        isSending = true
        
        switch recipient {
        case .conversation(let conversation):
            sendToConversation(conversation)
        case .profile(let profile):
            sendToNewConversation(with: profile)
        }
    }
    
    private func sendToConversation(_ conversation: ChatBskyConvoDefs.ConvoView) {
        Task {
            await MainActor.run {
                onDismiss()
                
                // Navigate to conversation
                appState.navigationManager.navigate(
                    to: .conversation(conversation.id),
                    in: 4
                )
                appState.navigationManager.tabSelection?(4)
            }
            
            // Send message in background
            let strongRef = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
            let recordEmbed = AppBskyEmbedRecord(record: strongRef)
            let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)
            
            _ = await appState.chatManager.sendMessage(
                convoId: conversation.id,
                text: messageText,
                embed: embed
            )
        }
    }
    
    private func sendToNewConversation(with profile: AppBskyActorDefs.ProfileView) {
        Task {
            if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
                await MainActor.run {
                    onDismiss()
                    
                    // Navigate to conversation
                    appState.navigationManager.navigate(
                        to: .conversation(convoId),
                        in: 4
                    )
                    appState.navigationManager.tabSelection?(4)
                }
                
                // Send message in background
                let strongRef = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
                let recordEmbed = AppBskyEmbedRecord(record: strongRef)
                let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)
                
                _ = await appState.chatManager.sendMessage(
                    convoId: convoId,
                    text: messageText,
                    embed: embed
                )
            } else {
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
}

// MARK: - Modern Recipient Row

@available(iOS 18.0, *)
struct ModernRecipientRow: View {
    let title: String
    let subtitle: String
    let avatarURL: String?
    let isSelected: Bool
    let showDivider: Bool
    let action: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Avatar
                Group {
                    if let avatarURL = avatarURL,
                       let url = URL(string: avatarURL) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Circle()
                                .fill(.quaternary)
                        }
                    } else {
                        Circle()
                            .fill(.quaternary)
                            .overlay {
                                Text(title.prefix(1))
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.accent)
                        .imageScale(.large)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .background(isPressed ? Color.secondary.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity) { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        } perform: { }
        
        if showDivider {
            Divider()
                .padding(.leading, 78)
        }
    }
}

// MARK: - Post Preview Sheet

@available(iOS 18.0, *)
struct PostPreviewSheet: View {
    let post: AppBskyFeedDefs.PostView
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Author info
                    HStack(spacing: 12) {
                        if let avatarURL = post.author.avatar?.uriString(),
                           let url = URL(string: avatarURL) {
                            AsyncImage(url: url) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Circle()
                                    .fill(.quaternary)
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.author.displayName ?? post.author.handle.description)
                                .font(.subheadline.weight(.semibold))
                            Text("@\(post.author.handle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    
                    // Post content
                    if case .knownType(let record) = post.record,
                       let postRecord = record as? AppBskyFeedPost {
                        Text(postRecord.text)
                            .font(.body)
                    }
                    
                    // Post stats
                    HStack(spacing: 24) {
                        Label("\(post.likeCount ?? 0)", systemImage: "heart")
                        Label("\(post.repostCount ?? 0)", systemImage: "arrow.2.squarepath")
                        Label("\(post.replyCount ?? 0)", systemImage: "bubble.left")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 16))
                .padding()
            }
            .navigationTitle("Post Preview")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Fallback for iOS 17

struct ChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void
    
    var body: some View {
        if #available(iOS 18.0, *) {
            ModernChatSelectionView(post: post, appState: appState, onDismiss: onDismiss)
        } else {
            // Fallback to a simpler version for iOS 17
            LegacyChatSelectionView(post: post, appState: appState, onDismiss: onDismiss)
        }
    }
}

// Keep the legacy view minimal for iOS 17 compatibility
struct LegacyChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void
    
    @State private var selectedConversation: ChatBskyConvoDefs.ConvoView?
    @State private var messageText = ""
    
    var body: some View {
        NavigationView {
            List(appState.chatManager.acceptedConversations) { conversation in
                if let otherMember = conversation.members.first(where: { $0.did.didString() != appState.currentUserDID }) {
                    Button {
                        selectedConversation = conversation
                        sendMessage()
                    } label: {
                        HStack {
                            Text(otherMember.displayName ?? "@\(otherMember.handle)")
                            Spacer()
                            if selectedConversation?.id == conversation.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Share to Chat")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        onDismiss()
                    }
                }
            }
        }
    }
    
    private func sendMessage() {
        guard let conversation = selectedConversation else { return }
        
        Task {
            await MainActor.run {
                onDismiss()
                appState.navigationManager.navigate(to: .conversation(conversation.id), in: 4)
                appState.navigationManager.tabSelection?(4)
            }
            
            let strongRef = ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid)
            let recordEmbed = AppBskyEmbedRecord(record: strongRef)
            let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)
            
            _ = await appState.chatManager.sendMessage(
                convoId: conversation.id,
                text: messageText,
                embed: embed
            )
        }
    }
}

#else
import Petrel
import SwiftUI

// macOS stubs for sharing functionality
class ShareToChatActivity {
    init(post: AppBskyFeedDefs.PostView, appState: AppState) {
        // macOS stub - sharing features not available
    }
}

class ShareablePost {
    init(post: AppBskyFeedDefs.PostView) {
        // macOS stub
    }
}

struct ChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void
    
    var body: some View {
        VStack {
            Text("Share to Chat")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Chat sharing is not available on macOS")
                .foregroundColor(.secondary)
            Text("Chat features require iOS")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

#endif

