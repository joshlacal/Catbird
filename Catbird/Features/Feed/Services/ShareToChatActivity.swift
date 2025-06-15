//
//  ShareToChatActivity.swift
//  Catbird
//
//  Created for sharing posts to Bluesky chat conversations
//

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
        return .action  // Keep as action, but we'll prioritize via applicationActivities order
    }
    
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        // Check if user is authenticated and has chat functionality
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
        // The actual work is done in activityViewController
        // Just finish successfully
        activityDidFinish(true)
    }
    
    override var activityViewController: UIViewController? {
        let chatSelectionView = ChatSelectionView(post: post, appState: appState) { [weak self] in
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
        // Return the web URL as placeholder for standard activities
        let username = post.author.handle
        let recordKey = post.uri.recordKey ?? ""
        return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)") ?? ""
    }
    
    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Return the post URI for chat sharing
        if activityType?.rawValue == "com.catbird.share-to-chat" {
            return post
        }
        
        // For other activities, return the web URL
        let username = post.author.handle
        let recordKey = post.uri.recordKey ?? ""
        return URL(string: "https://bsky.app/profile/\(username)/post/\(recordKey)")
    }
}

/// View for selecting a chat conversation to share to
struct ChatSelectionView: View {
    let post: AppBskyFeedDefs.PostView
    let appState: AppState
    let onDismiss: () -> Void
    
    @State private var searchText = ""
    @State private var messageText = ""  // Removed default "Check out this post" text
    @State private var selectedConversation: ChatBskyConvoDefs.ConvoView?
    @State private var selectedProfile: AppBskyActorDefs.ProfileView?
    @State private var isSending = false
    @State private var isSearching = false
    @State private var searchResults: [AppBskyActorDefs.ProfileView] = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Message text input
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Message")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        Text("\(messageText.count)/1000")
                            .font(.caption)
                            .foregroundColor(messageText.count > 1000 ? .red : .secondary)
                    }
                    
                    TextField("Add a message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .lineLimit(3...6)
                        .onChange(of: messageText) { _, newValue in
                            // Enforce ChatBsky lexicon limits:
                            // - 1000 characters (graphemes)
                            // - 10,000 bytes (UTF-8)
                            var validText = newValue
                            
                            // Check character limit
                            if validText.count > 1000 {
                                validText = String(validText.prefix(1000))
                            }
                            
                            // Check byte limit
                            let utf8Data = validText.data(using: .utf8) ?? Data()
                            if utf8Data.count > 10000 {
                                // Trim by characters until under byte limit
                                while validText.count > 0 {
                                    validText = String(validText.dropLast())
                                    let testData = validText.data(using: .utf8) ?? Data()
                                    if testData.count <= 10000 {
                                        break
                                    }
                                }
                            }
                            
                            if validText != newValue {
                                messageText = validText
                            }
                        }
                    
                    // Rich text formatting help
                    Text("Supports @mentions, #hashtags, and links")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                
                Divider()
                
                // Search bar
                SearchBarView(searchText: $searchText, placeholder: "Search people or conversations...") {
                    // Search implementation handled by onChange
                }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                
                // Results list
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Search results section (for users not in conversations)
                        if !searchText.isEmpty && !searchResults.isEmpty {
                            Section {
                                ForEach(searchResults, id: \.did) { profile in
                                    ShareToUserRow(
                                        profile: profile,
                                        isSelected: selectedProfile?.did == profile.did
                                    ) {
                                        selectedProfile = profile
                                        sendPostToNewChat(with: profile)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 4)
                                    
                                    if profile.did != searchResults.last?.did {
                                        Divider()
                                            .padding(.leading, 68)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text("People")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }
                        
                        // Existing conversations section
                        if !filteredConversations.isEmpty {
                            if !searchText.isEmpty && !searchResults.isEmpty {
                                // Only show section header if we also have search results
                                HStack {
                                    Text("Conversations")
                                        .font(.headline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                            
                            ForEach(filteredConversations) { conversation in
                                ShareToConversationRow(
                                    conversation: conversation,
                                    isSelected: selectedConversation?.id == conversation.id
                                ) {
                                    selectedConversation = conversation
                                    sendPostToChat()
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 4)
                                
                                if conversation.id != filteredConversations.last?.id {
                                    Divider()
                                        .padding(.leading, 68)
                                }
                            }
                        }
                        
                        // Empty state
                        if filteredConversations.isEmpty && searchResults.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                
                                Text(searchText.isEmpty ? "No conversations yet" : "No results found")
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                                
                                if !searchText.isEmpty {
                                    Text("Try searching for someone to message")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                        }
                    }
                }
                
                // Loading indicator
                if isSending || isSearching {
                    ProgressView(isSending ? "Sending..." : "Searching...")
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(10)
                        .padding()
                }
            }
            .navigationTitle("Share to Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        onDismiss()
                    }
                }
            }
        }
        .onChange(of: searchText) { _, newValue in
            if !newValue.isEmpty && newValue.count >= 2 {
                performSearch(searchText: newValue)
            } else {
                searchResults = []
            }
        }
    }
    
    private var filteredConversations: [ChatBskyConvoDefs.ConvoView] {
        let conversations = appState.chatManager.acceptedConversations
        
        if searchText.isEmpty {
            return conversations
        }
        
        return conversations.filter { conversation in
            // Find the other member
            guard let otherMember = conversation.members.first(where: { $0.did.didString() != appState.currentUserDID }) else {
                return false
            }
            
            let displayName = otherMember.displayName ?? ""
            let handle = otherMember.handle.description
            
            return displayName.localizedCaseInsensitiveContains(searchText) ||
                   handle.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private func sendPostToChat() {
        guard let conversation = selectedConversation else { return }
        
        isSending = true
        
        Task {
            // Create an embed for the post
            let strongRef = ComAtprotoRepoStrongRef(
                uri: post.uri,
                cid: post.cid
            )
            
            let recordEmbed = AppBskyEmbedRecord(
                record: strongRef
            )
            
            let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)
            
            // Create a message with the post embed
            // Use the user's custom message text
            
            let success = await appState.chatManager.sendMessage(
                convoId: conversation.id,
                text: messageText,
                embed: embed
            )
            
            await MainActor.run {
                isSending = false
                if success {
                    onDismiss()
                    
                    // Navigate to the conversation
                    appState.navigationManager.navigate(
                        to: .conversation(conversation.id),
                        in: 4 // Chat tab
                    )
                } else {
                    // Handle error - could show an alert
                }
            }
        }
    }
    
    private func sendPostToNewChat(with profile: AppBskyActorDefs.ProfileView) {
        isSending = true
        
        Task {
            // First, start a conversation with the user
            if let convoId = await appState.chatManager.startConversationWith(userDID: profile.did.didString()) {
                // Then send the post
                let strongRef = ComAtprotoRepoStrongRef(
                    uri: post.uri,
                    cid: post.cid
                )
                
                let recordEmbed = AppBskyEmbedRecord(
                    record: strongRef
                )
                
                let embed = ChatBskyConvoDefs.MessageInputEmbedUnion.appBskyEmbedRecord(recordEmbed)
                
                let success = await appState.chatManager.sendMessage(
                    convoId: convoId,
                    text: messageText,
                    embed: embed
                )
                
                await MainActor.run {
                    isSending = false
                    if success {
                        onDismiss()
                        
                        // Navigate to the conversation
                        appState.navigationManager.navigate(
                            to: .conversation(convoId),
                            in: 4 // Chat tab
                        )
                    }
                }
            } else {
                await MainActor.run {
                    isSending = false
                }
            }
        }
    }
    
    private func performSearch(searchText: String) {
        guard let client = appState.atProtoClient else {
            return
        }
        
        Task {
            await MainActor.run {
                isSearching = true
            }
            
            do {
                let searchTerm = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                let params = AppBskyActorSearchActors.Parameters(q: searchTerm, limit: 10)
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
                }
            }
        }
    }
    
    /// Parse rich text facets from message text for mentions, links, and hashtags
    private func parseFacets(from text: String) -> [AppBskyRichtextFacet]? {
        guard !text.isEmpty else { return nil }
        
        var facets: [AppBskyRichtextFacet] = []
        let utf8Data = text.data(using: .utf8) ?? Data()
        
        // Find URLs
        let urlPattern = #"https?://[^\s<>"{}|\\^`[\]]+"#
        if let urlRegex = try? NSRegularExpression(pattern: urlPattern, options: []) {
            let matches = urlRegex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
            
            for match in matches {
                let range = match.range
                let startByte = text.utf8ByteOffset(from: range.location)
                let endByte = text.utf8ByteOffset(from: range.location + range.length)
                
                if let startByte = startByte, let endByte = endByte,
                   let substring = text.substring(with: range),
                   let url = URL(string: substring) {
                    
                    let byteSlice = AppBskyRichtextFacet.ByteSlice(
                        byteStart: startByte,
                        byteEnd: endByte
                    )
                    
                    guard let uri = URI(url.absoluteString) else { continue }
                    let linkFeature = AppBskyRichtextFacet.Link(uri: uri)
                    let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion(linkFeature)
                    
                    let facet = AppBskyRichtextFacet(
                        index: byteSlice,
                        features: [feature]
                    )
                    
                    facets.append(facet)
                }
            }
        }
        
        // Find mentions (@username)
        let mentionPattern = #"@([a-zA-Z0-9\-\.]+)"#
        if let mentionRegex = try? NSRegularExpression(pattern: mentionPattern, options: []) {
            let matches = mentionRegex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
            
            for match in matches {
                let range = match.range
                let startByte = text.utf8ByteOffset(from: range.location)
                let endByte = text.utf8ByteOffset(from: range.location + range.length)
                
                if let startByte = startByte, let endByte = endByte,
                   let handleRange = Range(match.range(at: 1), in: text) {
                    
                    let handleString = String(text[handleRange])
                    
                    // Try to resolve the handle to a DID
                    // For now, we'll create the mention with the handle
                    // In a real implementation, you'd want to resolve this to a DID
                    if let handle = try? Handle(handleString: handleString) {
                        let byteSlice = AppBskyRichtextFacet.ByteSlice(
                            byteStart: startByte,
                            byteEnd: endByte
                        )
                        
                        // Note: In a production app, you should resolve the handle to a DID
                        // For now, we'll use a placeholder DID format
                        if let did = try? DID(didString: "did:placeholder:\(handleString)") {
                            let mentionFeature = AppBskyRichtextFacet.Mention(did: did)
                            let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion(mentionFeature)
                            
                            let facet = AppBskyRichtextFacet(
                                index: byteSlice,
                                features: [feature]
                            )
                            
                            facets.append(facet)
                        }
                    }
                }
            }
        }
        
        // Find hashtags (#tag)
        let hashtagPattern = #"#([a-zA-Z0-9_]+)"#
        if let hashtagRegex = try? NSRegularExpression(pattern: hashtagPattern, options: []) {
            let matches = hashtagRegex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
            
            for match in matches {
                let range = match.range
                let startByte = text.utf8ByteOffset(from: range.location)
                let endByte = text.utf8ByteOffset(from: range.location + range.length)
                
                if let startByte = startByte, let endByte = endByte,
                   let tagRange = Range(match.range(at: 1), in: text) {
                    
                    let tagString = String(text[tagRange])
                    
                    // Validate hashtag length (max 64 graphemes per lexicon spec)
                    guard tagString.count <= 64 else { continue }
                    
                    let byteSlice = AppBskyRichtextFacet.ByteSlice(
                        byteStart: startByte,
                        byteEnd: endByte
                    )
                    
                    let tagFeature = AppBskyRichtextFacet.Tag(tag: tagString)
                    let feature = AppBskyRichtextFacet.AppBskyRichtextFacetFeaturesUnion(tagFeature)
                    
                    let facet = AppBskyRichtextFacet(
                        index: byteSlice,
                        features: [feature]
                    )
                    
                    facets.append(facet)
                }
            }
        }
        
        return facets.isEmpty ? nil : facets
    }
}

// MARK: - String Extensions for Facet Parsing

extension String {
    /// Get UTF-8 byte offset for a character offset
    func utf8ByteOffset(from characterOffset: Int) -> Int? {
        guard characterOffset <= self.count else { return nil }
        
        let index = self.index(self.startIndex, offsetBy: characterOffset)
        let substring = self[..<index]
        return substring.utf8.count
    }
    
    /// Get substring from NSRange
    func substring(with range: NSRange) -> String? {
        guard let stringRange = Range(range, in: self) else { return nil }
        return String(self[stringRange])
    }
}

/// Row for displaying a conversation in the selection list
struct ShareToConversationRow: View {
    let conversation: ChatBskyConvoDefs.ConvoView
    let isSelected: Bool
    let onTap: () -> Void
    
    @Environment(AppState.self) private var appState
    
    private var otherMember: ChatBskyActorDefs.ProfileViewBasic? {
        conversation.members.first(where: { $0.did.didString() != appState.currentUserDID })
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                if let avatarUrl = otherMember?.avatar {
                    AsyncImage(url: URL(string: avatarUrl.uriString())) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                }
                
                // Name and handle
                VStack(alignment: .leading, spacing: 2) {
                    Text(otherMember?.displayName ?? otherMember?.handle.description ?? "Unknown")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let handle = otherMember?.handle {
                        Text("@\(handle)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// Row for displaying a user (not in conversations) in the selection list
struct ShareToUserRow: View {
    let profile: AppBskyActorDefs.ProfileView
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Avatar
                if let avatarUrl = profile.avatar {
                    AsyncImage(url: URL(string: avatarUrl.uriString())) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 40, height: 40)
                }
                
                // Name and handle
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName ?? profile.handle.description)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text("@\(profile.handle)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
