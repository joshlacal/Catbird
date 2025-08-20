#if os(iOS)
import ExyteChat
import Petrel
import SwiftUI
import OSLog

struct MessageReactionsView: View {
  let convoId: String
  let messageId: String
  let messageView: ChatBskyConvoDefs.MessageView

  @Environment(AppState.self) private var appState
  @State private var showingEmojiPicker = false
  @State private var reactionTask: Task<Void, Never>?
  
  private let logger = Logger(subsystem: "blue.catbird", category: "MessageReactionsView")
  
  // Group reactions by emoji and count them
  private var groupedReactions: [String: [ChatBskyConvoDefs.ReactionView]] {
    guard let reactions = messageView.reactions else { return [:] }
    return Dictionary(grouping: reactions, by: { $0.value })
  }
  
  // Check if current user has reacted with specific emoji
  private func currentUserReacted(to emoji: String) -> Bool {
    guard let userReactions = groupedReactions[emoji] else { return false }
    return userReactions.contains { $0.sender.did.didString() == appState.currentUserDID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !groupedReactions.isEmpty || messageView.reactions != nil {
        HStack(spacing: 6) {
          // Display existing reactions
          ForEach(Array(groupedReactions.keys.sorted()), id: \.self) { emoji in
            let reactions = groupedReactions[emoji] ?? []
            let count = reactions.count
            let userReacted = currentUserReacted(to: emoji)
            
            Button(action: {
              // Cancel any existing reaction task to prevent concurrent operations
              reactionTask?.cancel()
              
              reactionTask = Task {
                do {
                  try await toggleReaction(emoji: emoji)
                } catch {
                  // Handle cancellation and other errors gracefully
                  if !(error is CancellationError) && !error.localizedDescription.lowercased().contains("cancel") {
                    logger.error("Reaction error: \(error.localizedDescription)")
                    // Could optionally show a brief toast here instead of alert
                  }
                }
              }
            }) {
              HStack(spacing: 4) {
                Text(emoji)
                  .font(.caption)
                if count > 1 {
                  Text("\(count)")
                    .font(.caption2)
                    .fontWeight(.medium)
                }
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 12)
                  .fill(userReacted ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                  .overlay(
                    RoundedRectangle(cornerRadius: 12)
                      .stroke(userReacted ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1)
                  )
              )
              .foregroundColor(userReacted ? .accentColor : .primary)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.2), value: userReacted)
          }
          
          // Add reaction button
          Button(action: {
            showingEmojiPicker = true
          }) {
            Image(systemName: "plus.circle")
              .font(.caption)
              .foregroundColor(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 4)
              .background(
                RoundedRectangle(cornerRadius: 12)
                  .fill(Color.gray.opacity(0.1))
              )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .sheet(isPresented: $showingEmojiPicker) {
      VStack {
        HStack {
          Text("Add Reaction")
            .font(.headline)
            .padding(.leading)
          Spacer()
          Button("Cancel") {
            showingEmojiPicker = false
          }
          .padding(.trailing)
        }
        .padding(.top)
        
        EmojiReactionPicker(isPresented: $showingEmojiPicker) { emoji in
          // Cancel any existing reaction task to prevent concurrent operations
          reactionTask?.cancel()
          
          reactionTask = Task {
            do {
              try await toggleReaction(emoji: emoji)
            } catch {
              // Handle cancellation and other errors gracefully
              if !(error is CancellationError) && !error.localizedDescription.lowercased().contains("cancel") {
                logger.error("Emoji picker reaction error: \(error.localizedDescription)")
                // Could optionally show a brief toast here instead of alert
              }
            }
          }
        }
        .padding()
      }
      .presentationDetents([.height(350)])
      .presentationDragIndicator(.visible)
    }
    .onDisappear {
      // Clean up any pending reaction tasks when view disappears
      reactionTask?.cancel()
    }
  }

  private func toggleReaction(emoji: String) async throws {
    try await appState.chatManager.toggleReaction(
      convoId: convoId, messageId: messageId, emoji: emoji)
  }
}
#endif
