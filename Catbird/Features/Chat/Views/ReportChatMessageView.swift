import SwiftUI
import Petrel

// MARK: - Report Chat Message View

struct ReportChatMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let message: ChatBskyConvoDefs.MessageView
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
        subtitle: "Reporting message: \"\(message.text.prefix(60))\(message.text.count > 60 ? "…" : "")\"",
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
          self.errorMessage = "Not authenticated"
        }
        return
      }
      
      do {
        let subject = reportingService.createUserSubject(did: message.sender.did)
        let reasonText = details.isEmpty ? "Inappropriate message in chat" : details
        
        let success = try await reportingService.submitReport(
          subject: subject,
          reasonType: reason,
          reason: reasonText
        )
        
        await MainActor.run {
          self.isSubmitting = false
          if success {
            onDismiss()
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
  
}
