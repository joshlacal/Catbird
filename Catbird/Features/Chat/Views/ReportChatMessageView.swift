import SwiftUI
import Petrel

// MARK: - Report Chat Message View

struct ReportChatMessageView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
  let message: ChatBskyConvoDefs.MessageView
  let onDismiss: () -> Void
  
  @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonspam
  @State private var additionalDetails: String = ""
  @State private var isSubmitting = false
  @State private var showingError = false
  @State private var errorMessage = ""
  
  private var reportingService: ReportingService? {
    guard let client = appState.atProtoClient else { return nil }
    return ReportingService(client: client)
  }
  
  var body: some View {
    NavigationStack {
      Form {
        Section("Message to Report") {
          Text(message.text)
            .appCallout()
            .foregroundColor(.secondary)
            .padding(.vertical, 4)
        }
        
        Section("Report Reason") {
          Picker("Reason", selection: $selectedReason) {
              Text("Spam").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonspam)
              Text("Harassment").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonrude)
              Text("Violation").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonviolation)
              Text("Misleading").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonmisleading)
              Text("Sexual Content").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonsexual)
              Text("Other").tag(ComAtprotoModerationDefs.ReasonType.comatprotomoderationdefsreasonother)
          }
        }
        
        Section("Additional Details (Optional)") {
          TextEditor(text: $additionalDetails)
            .frame(minHeight: 100)
        }
        
        Section {
          Text("This report will be sent to the Bluesky moderation team for review.")
            .appCaption()
            .foregroundColor(.secondary)
        }
      }
      .navigationTitle("Report Message")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", systemImage: "xmark") {
            onDismiss()
          }
          .disabled(isSubmitting)
        }
        
        ToolbarItem(placement: .primaryAction) {
          Button("Submit") {
            submitReport()
          }
          .disabled(isSubmitting)
        }
      }
      .disabled(isSubmitting)
      .overlay {
        if isSubmitting {
          ProgressView("Submitting report...")
            .padding()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
      }
      .alert("Report Error", isPresented: $showingError) {
        Button("OK") { }
      } message: {
        Text(errorMessage)
      }
    }
  }
  
  private func submitReport() {
    Task {
      isSubmitting = true
      defer { isSubmitting = false }
      
      guard let reportingService = reportingService else {
        await MainActor.run {
          errorMessage = "Reporting service is not available"
          showingError = true
        }
        return
      }
      
      do {
        // For chat messages, we'll report the sender's account
        let subject = reportingService.createUserSubject(did: message.sender.did)
        
        let reason = additionalDetails.isEmpty ? "Inappropriate message in chat" : additionalDetails
        
        let success = try await reportingService.submitReport(
          subject: subject,
          reasonType: selectedReason,
          reason: reason
        )
        
        if success {
          await MainActor.run {
            onDismiss()
          }
        } else {
          await MainActor.run {
            errorMessage = "Failed to submit report. Please try again."
            showingError = true
          }
        }
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          showingError = true
        }
      }
    }
  }
}
