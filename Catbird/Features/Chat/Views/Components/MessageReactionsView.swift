import ExyteChat
import Petrel
import SwiftUI

struct MessageReactionsView: View {
  let convoId: String
  let messageId: String
  let messageView: ChatBskyConvoDefs.MessageView

  @Environment(AppState.self) private var appState

  var body: some View {
    VStack {
      if let reactions = messageView.reactions {
        HStack(spacing: 4) {
          ForEach(reactions, id: \.value) { reaction in
            Button(action: {
              Task {
                try await toggleReaction(emoji: reaction.value)
              }
            }) {
              HStack(spacing: 2) {
                Text(reaction.value)
                      .font(.caption)
              }
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
//              .background(
//                RoundedRectangle(cornerRadius: 12)
//                  .fill(
//                    reaction.sender.did.didString() == appState.currentUserDID
//                      ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
//              )
            }
          }
          // Exyte Chat will handle emoji selection UI
        }
        .padding(.vertical, 2)
      }
    }
  }

  private func toggleReaction(emoji: String) async throws {
    try await appState.chatManager.toggleReaction(
      convoId: convoId, messageId: messageId, emoji: emoji)
  }
}
