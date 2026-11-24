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
        title: String(localized: "Report Message", comment: "Navigation title for reporting a chat message"),
        subtitle: message.text.isEmpty
          ? String(localized: "Reporting a message", comment: "Subtitle when reporting a message without text")
          : (message.text.count > 60
              ? String(
                  localized: "Reporting message: “\(String(message.text.prefix(60)))…”",
                  comment: "Subtitle showing truncated text of message being reported (%@ = truncated message preview)"
                )
              : String(
                  localized: "Reporting message: “\(message.text)”",
                  comment: "Subtitle showing text of message being reported (%@ = message text)"
                )),
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
          self.errorMessage = String(
            localized: "Sign in to report this message.",
            comment: "Error message when attempting to report a chat message while signed out"
          )
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
            appState.toastManager.show(
              ToastItem(
                message: String(
                  localized: "Report sent. Thanks for helping keep Bluesky safe.",
                  comment: "Toast confirmation after reporting a chat message"
                )
              )
            )
            onDismiss()
          } else {
            self.errorMessage = String(
              localized: "Couldn’t send the report. Please try again.",
              comment: "Error message when submitting a chat message report fails"
            )
          }
        }
      } catch {
        await MainActor.run {
          self.isSubmitting = false
          self.errorMessage = UserFacingError.message(
            for: error,
            action: String(localized: "send the report", comment: "Action phrase when submitting a moderation report fails")
          )
        }
      }
    }
  }
  
}
