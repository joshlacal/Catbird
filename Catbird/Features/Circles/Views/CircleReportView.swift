import SwiftUI
import Petrel
import PetrelCatbird

/// Private moderation report sheet for Circle posts.
/// Reports route exclusively through the proxied AppView endpoint (`blue.catbird.circle.reportRecord`) and never fall back to public moderation.
struct CircleReportView: View {
  let post: AppBskyFeedDefs.PostView
  let circle: CircleSummary
  var service: CircleService?

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var selectedReason: CircleReportReason = .abuse
  @State private var details: String = ""
  @State private var isSubmitting: Bool = false
  @State private var errorMessage: String?
  @State private var isSubmitted: Bool = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text("Report a post in Circle \"\(circle.name)\". Reports are reviewed privately and do not create public moderation labels.")
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

        Section("Additional Details (Optional)") {
          TextField("Describe the issue...", text: $details, axis: .vertical)
            .lineLimit(3...6)
            .accessibilityLabel("Additional report details")
            .accessibilityHint("Optional explanation of the violation")
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
            .accessibilityHint("Submits private report to Circle moderators")
          }
        }
      }
      .alert("Report Submitted", isPresented: $isSubmitted) {
        Button("OK") {
          dismiss()
        }
      } message: {
        Text("Thank you. This post has been reported privately for Circle review.")
      }
    }
  }

  private func submitReport() {
    isSubmitting = true
    errorMessage = nil

    let reportingService = service ?? appState.circleService

    Task {
      do {
        _ = try await reportingService.report(
          post: post.uri,
          circle: circle,
          reason: selectedReason,
          details: details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : details
        )
        await MainActor.run {
          self.isSubmitting = false
          self.isSubmitted = true
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
