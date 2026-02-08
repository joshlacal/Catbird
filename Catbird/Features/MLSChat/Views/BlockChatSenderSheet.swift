import OSLog
import Petrel
import SwiftUI

#if os(iOS)

/// Block reason options for chat sender blocking
enum BlockChatReason: String, CaseIterable, Identifiable {
  case spam = "spam"
  case harassment = "harassment"
  case inappropriate = "inappropriate"
  case other = "other"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .spam: return "Spam"
    case .harassment: return "Harassment"
    case .inappropriate: return "Inappropriate Content"
    case .other: return "Other"
    }
  }

  var icon: String {
    switch self {
    case .spam: return "envelope.badge.fill"
    case .harassment: return "exclamationmark.bubble.fill"
    case .inappropriate: return "eye.slash.fill"
    case .other: return "ellipsis.circle.fill"
    }
  }
}

/// Sheet for blocking a chat sender with reason selection
struct BlockChatSenderSheet: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let senderDid: String
  let senderHandle: String?
  let senderDisplayName: String?
  let requestId: String?
  let onBlocked: (() -> Void)?

  @State private var selectedReason: BlockChatReason = .spam
  @State private var isBlocking = false
  @State private var errorMessage: String?
  @State private var showingErrorAlert = false

  private let logger = Logger(subsystem: "blue.catbird", category: "BlockChatSender")

  init(
    senderDid: String,
    senderHandle: String? = nil,
    senderDisplayName: String? = nil,
    requestId: String? = nil,
    onBlocked: (() -> Void)? = nil
  ) {
    self.senderDid = senderDid
    self.senderHandle = senderHandle
    self.senderDisplayName = senderDisplayName
    self.requestId = requestId
    self.onBlocked = onBlocked
  }

  var body: some View {
    NavigationStack {
      Form {
        // MARK: - User Info

        Section {
          HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.xmark")
              .font(.system(size: 40))
              .foregroundStyle(.red.opacity(0.8))

            VStack(alignment: .leading, spacing: 4) {
              Text(senderDisplayName ?? senderHandle ?? "Unknown User")
                .fontWeight(.semibold)
              if let handle = senderHandle {
                Text("@\(handle)")
                  .appFont(AppTextRole.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          .padding(.vertical, 4)
        }

        // MARK: - Reason Selection

        Section("Why are you blocking this user?") {
          ForEach(BlockChatReason.allCases) { reason in
            Button {
              selectedReason = reason
            } label: {
              HStack {
                Image(systemName: reason.icon)
                  .foregroundStyle(selectedReason == reason ? .blue : .secondary)
                  .frame(width: 24)

                Text(reason.displayName)
                  .foregroundStyle(.primary)

                Spacer()

                if selectedReason == reason {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.blue)
                    .fontWeight(.semibold)
                }
              }
            }
          }
        }

        // MARK: - What Happens

        Section("What happens when you block") {
          VStack(alignment: .leading, spacing: 8) {
            BlockExplanationRow(
              icon: "xmark.circle.fill",
              text: "All pending requests from this user will be declined"
            )
            BlockExplanationRow(
              icon: "message.badge.fill",
              text: "They won't be able to send you new message requests"
            )
            BlockExplanationRow(
              icon: "eye.slash.fill",
              text: "Existing conversations will be hidden"
            )
          }
          .padding(.vertical, 4)
        }
      }
      .navigationTitle("Block User")
      .toolbarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isBlocking)
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Block", role: .destructive) {
            Task { await blockUser() }
          }
          .disabled(isBlocking)
          .fontWeight(.semibold)
        }
      }
      .interactiveDismissDisabled(isBlocking)
      .overlay {
        if isBlocking {
          Color.black.opacity(0.3)
            .ignoresSafeArea()
            .overlay {
              VStack(spacing: 12) {
                ProgressView()
                  .scaleEffect(1.2)
                Text("Blocking user...")
                  .fontWeight(.medium)
              }
              .padding(24)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
      }
      .alert("Block Failed", isPresented: $showingErrorAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(errorMessage ?? "An unknown error occurred.")
      }
    }
  }

  // MARK: - Block Action

  @MainActor
  private func blockUser() async {
    guard let apiClient = await appState.getMLSAPIClient() else {
      errorMessage = "MLS client not available"
      showingErrorAlert = true
      return
    }

    isBlocking = true
    defer { isBlocking = false }

    do {
      let (success, blockedCount) = try await apiClient.blockChatSender(
        senderDid: try DID(didString: senderDid),
        requestId: requestId,
        reason: selectedReason.rawValue
      )

      if success {
        logger.info("Successfully blocked sender \(senderDid), declined \(blockedCount) requests")
        onBlocked?()
        dismiss()
      } else {
        errorMessage = "Failed to block user. Please try again."
        showingErrorAlert = true
      }
    } catch {
      logger.error("Failed to block sender: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      showingErrorAlert = true
    }
  }
}

// MARK: - Helper Views

private struct BlockExplanationRow: View {
  let icon: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .foregroundStyle(.red.opacity(0.8))
        .frame(width: 20)
      Text(text)
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
    }
  }
}

#Preview {
  BlockChatSenderSheet(
    senderDid: "did:plc:test123",
    senderHandle: "spammer.bsky.social",
    senderDisplayName: "Spammy User",
    requestId: "req-123"
  )
}

#endif
