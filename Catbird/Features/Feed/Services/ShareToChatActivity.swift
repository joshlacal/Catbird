//
//  ShareToChatActivity.swift
//  Catbird
//
//  Created for sharing posts to Bluesky chat conversations
//

import UIKit
import SwiftUI
import Petrel

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
        return .share
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
    
    override var activityViewController: UIViewController? {
        let chatSelectionView = ChatSelectionView(post: post, appState: appState) { [weak self] in
            self?.activityDidFinish(true)
        }
        
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
        return post.uri.uriString()
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
    @State private var selectedConversation: ChatBskyConvoDefs.ConvoView?
    @State private var isSending = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Search bar
                SearchBarView(searchText: $searchText, placeholder: "Search conversations...") {
                    // TODO: Implement search functionality
                }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                
                // Conversations list
                ScrollView {
                    LazyVStack(spacing: 0) {
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
                        }
                    }
                }
                
                // Loading indicator
                if isSending {
                    ProgressView("Sending...")
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
            // Just add some text to describe what's being shared
            let messageText = "Check out this post"
            
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
                ChatProfileAvatarView(profile: otherMember, size: 40)
                
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