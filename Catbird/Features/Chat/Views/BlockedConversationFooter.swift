import SwiftUI
import Petrel
import OSLog

struct BlockedConversationFooter: View {
  @Environment(AppState.self) private var appState
  let convoId: String
  let isGroup: Bool
  let blockState: BlueskyConversationBlockState
  var onUnblocked: (() -> Void)?
  var onLeft: (() -> Void)?

  @State private var isProcessing = false
  @State private var errorMessage: String?
  @State private var showingListBlockDialog = false
  @State private var showingLeaveAlert = false

  private var statusText: String {
    switch blockState {
    case .directBlock:
      if isGroup {
        return "You have blocked the creator of this group. You cannot send messages."
      } else {
        return "You have blocked this user. You cannot send messages to each other."
      }
    case .listBlock(_, _, _, let list):
      if isGroup {
        return "You have blocked the creator of this group via the list '\(list.name)'. You cannot send messages."
      } else {
        return "You have blocked this user via the list '\(list.name)'. You cannot send messages to each other."
      }
    case .blockedBy:
      return "You have been blocked by this user. You cannot send messages to each other."
    case .none:
      return ""
    }
  }

  var body: some View {
    VStack(spacing: 10) {
      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }

      HStack(spacing: 8) {
        Image(systemName: "person.crop.circle.badge.xmark")
          .font(.title3)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(statusText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
          Text("Message history is readable.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        Spacer(minLength: 0)
      }

      HStack(spacing: 12) {
        switch blockState {
        case .directBlock(let did, _, _):
          Button {
            unblockDirectly(did: did)
          } label: {
            if isProcessing {
              ProgressView()
                .controlSize(.small)
            } else {
              Text("Unblock")
                .fontWeight(.medium)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isProcessing)

        case .listBlock:
          Button {
            showingListBlockDialog = true
          } label: {
            Text("Unblock")
              .fontWeight(.medium)
          }
          .buttonStyle(.borderedProminent)
          .disabled(isProcessing)

        case .blockedBy, .none:
          EmptyView()
        }

        Button(role: .destructive) {
          showingLeaveAlert = true
        } label: {
          Text(isGroup ? "Leave group" : "Leave chat")
            .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .disabled(isProcessing)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color(.secondarySystemBackground))
    .alert("User Blocked by List", isPresented: $showingListBlockDialog) {
      if case .listBlock(_, _, _, let list) = blockState {
        Button("View List") {
          appState.navigationManager.navigate(to: .list(list.uri), in: 4)
        }
        Button("Cancel", role: .cancel) { }
      }
    } message: {
      if case .listBlock(_, let handle, _, let list) = blockState {
        Text("@\(handle) is blocked because you subscribe to the list \"\(list.name)\". You can view the list to adjust your moderation settings.")
      }
    }
    .alert("Leave Chat", isPresented: $showingLeaveAlert) {
      Button("Cancel", role: .cancel) { }
      Button("Leave", role: .destructive) {
        leaveChat()
      }
    } message: {
      Text("Are you sure you want to leave this conversation? You will no longer receive messages from this conversation.")
    }
  }

  private func unblockDirectly(did: String) {
    Task {
      isProcessing = true
      errorMessage = nil
      do {
        _ = try await appState.graphManager.unblock(did: did)
        isProcessing = false
        onUnblocked?()
      } catch {
        isProcessing = false
        errorMessage = error.localizedDescription
      }
    }
  }

  private func leaveChat() {
    Task {
      isProcessing = true
      errorMessage = nil
      let result = await appState.chatManager.leaveConversation(convoId: convoId)
      isProcessing = false
      if result == .success {
        onLeft?()
      } else {
        errorMessage = appState.chatManager.errorState?.localizedDescription ?? "Couldn't leave this conversation. Please try again."
        appState.chatManager.errorState = nil
      }
    }
  }
}
