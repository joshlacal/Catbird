import SwiftUI
import Petrel

// MARK: - Report Chat Message View

struct ReportChatMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let message: ChatBskyConvoDefs.MessageView
  let convoId: String
  let onDismiss: () -> Void
  
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  
  private var reportingService: ReportingService? {
    guard let client = appState.atProtoClient else { return nil }
    return ReportingService(client: client)
  }
  
  var body: some View {
    NavigationStack {
      ChatReportFormView(
        title: "Report Message",
        subtitle: message.text.isEmpty
          ? "Reporting a message"
          : "Reporting message: “\(message.text.prefix(60))\(message.text.count > 60 ? "…" : "")”",
        isSubmitting: isSubmitting,
        errorMessage: errorMessage,
        onSubmit: { reason, details in
          submitReport(reason: reason, details: details)
        },
        onCancel: {
          onDismiss()
        }
      )
    }
  }
  
  private func submitReport(reason: ComAtprotoModerationDefs.ReasonType, details: String) {
    isSubmitting = true
    errorMessage = nil

    Task {
      guard let reportingService = reportingService else {
        await MainActor.run {
          self.isSubmitting = false
          self.errorMessage = "Sign in to report this message."
        }
        return
      }
      
      do {
        // Report the specific message (chat.bsky.convo.defs#messageRef), not just its sender
        let messageRef = ChatBskyConvoDefs.MessageRef(
          did: message.sender.did,
          convoId: convoId,
          messageId: message.id
        )
        let subject = ComAtprotoModerationCreateReport.InputSubjectUnion.unexpected(.knownType(messageRef))
        let reasonText = details.isEmpty ? "Inappropriate message in chat" : details
        
        let success = try await reportingService.submitReport(
          subject: subject,
          reasonType: reason,
          reason: reasonText
        )
        
        await MainActor.run {
          self.isSubmitting = false
          if success {
            appState.toastManager.show(ToastItem(message: "Report sent. Thanks for helping keep Bluesky safe."))
            onDismiss()
          } else {
            self.errorMessage = "Couldn’t send the report. Please try again."
          }
        }
      } catch {
        await MainActor.run {
          self.isSubmitting = false
          self.errorMessage = UserFacingError.message(for: error, action: "send the report")
        }
      }
    }
  }
  
}
