import SwiftUI
import Petrel

/// Reusable chat reporting form presentation supporting message and conversation reports
struct ChatReportFormView: View {
  let title: String
  let subtitle: String?
  let isSubmitting: Bool
  let errorMessage: String?
  let onSubmit: (ComAtprotoModerationDefs.ReasonType, String) -> Void
  let onCancel: () -> Void

  @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonspam
  @State private var additionalDetails: String = ""

  private struct ReasonOption: Identifiable {
    let type: ComAtprotoModerationDefs.ReasonType
    let title: String
    let description: String

    var id: String { type.rawValue }
  }

  private let reasons: [ReasonOption] = [
    ReasonOption(
      type: .comatprotomoderationdefsreasonspam,
      title: "Spam",
      description: "Excessive, unwanted, or repetitive messages"
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonviolation,
      title: "Terms of Service Violation",
      description: "Violates the platform terms or safety rules"
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonmisleading,
      title: "Scam or Fraud",
      description: "Phishing, impersonation, or financial deception"
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonsexual,
      title: "Unwanted Sexual Content",
      description: "Explicit, harassing, or non-consensual sexual content"
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonrude,
      title: "Harassment or Hate",
      description: "Targeted harassment, bullying, or hate speech"
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonother,
      title: "Other",
      description: "An issue not covered by other categories"
    ),
  ]

  var body: some View {
    Form {
      if let subtitle {
        Section {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      Section("Reason for Report") {
        ForEach(reasons) { reason in
          Button {
            selectedReason = reason.type
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(reason.title)
                  .font(.body)
                  .foregroundStyle(.primary)
                Text(reason.description)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              Spacer()
              if selectedReason.rawValue == reason.type.rawValue {
                Image(systemName: "checkmark")
                  .foregroundStyle(Color.accentColor)
                  .fontWeight(.semibold)
              }
            }
          }
          .buttonStyle(.plain)
        }
      }

      Section("Additional Details (Optional)") {
        TextEditor(text: $additionalDetails)
          .frame(minHeight: 80)
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle(title)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          onCancel()
        }
        .disabled(isSubmitting)
      }

      ToolbarItem(placement: .confirmationAction) {
        if isSubmitting {
          ProgressView()
            .scaleEffect(0.8)
        } else {
          Button("Submit") {
            onSubmit(selectedReason, additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines))
          }
          .fontWeight(.semibold)
        }
      }
    }
    .disabled(isSubmitting)
  }
}
