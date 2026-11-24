import SwiftUI
import Petrel
import PetrelCatbird

/// Report sheet for Circle posts.
/// Reports go through the reporter's PDS to Catbird's moderation service
/// (`CatbirdModeration`), never to Bluesky. Like Signal, they carry ids only:
/// the post's URI and CID, the Circle, and a reason category. No post text,
/// media, keys or free text.
struct CircleReportView: View {
  let post: AppBskyFeedDefs.PostView
  let circle: CircleSummary
  var service: CircleService?

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var selectedReason: CircleReportReason = .abuse
  @State private var isSubmitting: Bool = false
  @State private var errorMessage: String?
  @State private var isSubmitted: Bool = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(
            "Report a post in Circle \"\(circle.name)\".",
            comment: "Heading at the top of the Circle post report sheet — %1$@ is the Circle name."
          )
            .font(.subheadline)
          Label(CatbirdModeration.whatIsShared, systemImage: "lock")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }

        Section("Reason") {
          Picker("Reason", selection: $selectedReason) {
            Text("Harassment / Abuse").tag(CircleReportReason.abuse)
            Text("Spam").tag(CircleReportReason.spam)
            Text("Other Violation").tag(CircleReportReason.other)
          }
          .pickerStyle(.inline)
          .accessibilityLabel("Report reason")
        }

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Report Circle Post")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
          .accessibilityLabel("Cancel report")
        }

        ToolbarItem(placement: .confirmationAction) {
          if isSubmitting {
            ProgressView()
          } else {
            Button("Submit Report") {
              submitReport()
            }
            .fontWeight(.semibold)
            .disabled(isSubmitting)
            .accessibilityLabel("Submit report")
            .accessibilityHint("Sends the report to Catbird")
          }
        }
      }
      .alert("Report Submitted", isPresented: $isSubmitted) {
        Button("OK") {
          dismiss()
        }
      } message: {
        Text(CatbirdModeration.sent)
      }
    }
  }

  private func submitReport() {
    guard let serviceDID = CatbirdModeration.serviceDID else {
      errorMessage = CatbirdModeration.notConfigured
      return
    }
    guard let client = appState.atProtoClient else {
      errorMessage = String(
        localized: "Sign in to report this post.",
        comment: "Error message when attempting to report a Circle post while signed out"
      )
      return
    }
    isSubmitting = true
    errorMessage = nil

    let subject = CatbirdModeration.circlePostSubject(uri: post.uri, cid: post.cid)
    let reasonType = CatbirdModeration.reasonType(for: selectedReason)
    let reason = CatbirdModeration.circleReason(space: circle.uri.uriString())

    Task {
      do {
        let sent = try await ReportingService(client: client).submitReport(
          subject: subject,
          reasonType: reasonType,
          reason: reason,
          labelerDid: serviceDID
        )
        await MainActor.run {
          self.isSubmitting = false
          if sent {
            self.isSubmitted = true
          } else {
            self.errorMessage = String(
              localized: "Couldn’t send the report. Please try again.",
              comment: "Error message when submitting a Circle report fails"
            )
          }
        }
      } catch {
        await MainActor.run {
          self.isSubmitting = false
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }
}
