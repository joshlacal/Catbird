import SwiftUI
import Petrel

/// Sheet for reporting a conversation and performing post-report safety actions (leave, block)
struct ReportConversationView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  let conversation: ChatBskyConvoDefs.ConvoView
  var onConversationLeft: (() -> Void)? = nil

  @State private var isSubmitting = false
  @State private var isPerformingSafetyAction = false
  @State private var reportSubmitted = false
  @State private var errorMessage: String?

  private var primaryMember: ChatBskyActorDefs.ProfileViewBasic? {
    conversation.primaryMember(currentUserDID: appState.userDID)
  }

  private var reportingService: ReportingService? {
    guard let client = appState.atProtoClient else { return nil }
    return ReportingService(client: client)
  }

  var body: some View {
    NavigationStack {
      if reportSubmitted {
        afterReportView
      } else {
        ChatReportFormView(
          title: "Report Conversation",
          subtitle: primaryMember.map { "Reporting conversation with \($0.chatDisplayName)" },
          isSubmitting: isSubmitting,
          errorMessage: errorMessage,
          onSubmit: { reason, details in
            submitReport(reason: reason, details: details)
          },
          onCancel: {
            dismiss()
          }
        )
      }
    }
  }

  // MARK: - After Report View

  private var afterReportView: some View {
    VStack(spacing: 24) {
      Spacer()

      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)

      VStack(spacing: 8) {
        Text("Report Submitted")
          .font(.title2)
          .fontWeight(.bold)

        Text("Thank you for helping keep the community safe. Your report has been submitted to moderators.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 24)
      }

      if let errorMessage {
        Text(errorMessage)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 24)
      }

      Spacer()

      VStack(spacing: 12) {
        if let member = primaryMember {
          Button {
            blockAndLeave(memberDID: member.did.didString())
          } label: {
            HStack {
              if isPerformingSafetyAction {
                ProgressView()
                  .scaleEffect(0.8)
                  .tint(.white)
              } else {
                Image(systemName: "person.crop.circle.badge.xmark")
                Text("Block \(member.chatDisplayName) and Leave")
              }
            }
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.red)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .disabled(isPerformingSafetyAction)
        }

        Button {
          leaveConversation()
        } label: {
          HStack {
            if isPerformingSafetyAction {
              ProgressView()
                .scaleEffect(0.8)
            } else {
              Image(systemName: "rectangle.portrait.and.arrow.right")
              Text("Leave Conversation")
            }
          }
          .fontWeight(.medium)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .background(Color.secondary.opacity(0.15))
          .foregroundStyle(.primary)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(isPerformingSafetyAction)

        Button("Close") {
          dismiss()
        }
        .padding(.top, 4)
        .disabled(isPerformingSafetyAction)
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
    }
    .navigationTitle("Report Submitted")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }

  // MARK: - Actions

  private func submitReport(reason: ComAtprotoModerationDefs.ReasonType, details: String) {
    guard let reportingService else {
      errorMessage = "Not authenticated"
      return
    }

    guard let member = primaryMember else {
      errorMessage = "Could not identify conversation member to report"
      return
    }

    isSubmitting = true
    errorMessage = nil

    Task {
      do {
        let convoRef = ChatBskyConvoDefs.ConvoRef(did: member.did, convoId: conversation.id)
        let subject = ComAtprotoModerationCreateReport.InputSubjectUnion.unexpected(.knownType(convoRef))

        let success = try await reportingService.submitReport(
          subject: subject,
          reasonType: reason,
          reason: details.isEmpty ? "Inappropriate conversation" : details
        )

        await MainActor.run {
          self.isSubmitting = false
          if success {
            self.reportSubmitted = true
          } else {
            self.errorMessage = "Failed to submit report. Please try again."
          }
        }
      } catch {
        await MainActor.run {
          self.isSubmitting = false
          self.errorMessage = "Error submitting report: \(error.localizedDescription)"
        }
      }
    }
  }

  private func leaveConversation() {
    isPerformingSafetyAction = true
    errorMessage = nil

    Task {
      let result = await appState.chatManager.leaveConversation(convoId: conversation.id)
      await MainActor.run {
        self.isPerformingSafetyAction = false
        if result == .success {
          self.onConversationLeft?()
          self.dismiss()
        } else {
          self.errorMessage = "Failed to leave conversation."
        }
      }
    }
  }

  private func blockAndLeave(memberDID: String) {
    isPerformingSafetyAction = true
    errorMessage = nil

    Task {
      do {
        // Block the reported account
        try await appState.block(did: memberDID)

        // Then leave the conversation
        let leaveResult = await appState.chatManager.leaveConversation(convoId: conversation.id)
        await MainActor.run {
          self.isPerformingSafetyAction = false
          if leaveResult == .success {
            self.onConversationLeft?()
            self.dismiss()
          } else {
            self.errorMessage = "Account blocked, but failed to leave conversation."
          }
        }
      } catch {
        await MainActor.run {
          self.isPerformingSafetyAction = false
          self.errorMessage = "Failed to block account: \(error.localizedDescription)"
        }
      }
    }
  }
}
