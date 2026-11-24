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
  /// Encrypted chat reports send ids only, so they have no free-text box.
  var showsDetails: Bool = true
  /// Shown under the subtitle, e.g. what an encrypted report shares.
  var footnote: String? = nil

  @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonspam
  @State private var additionalDetails: String = ""

  private struct ReasonOption: Identifiable {
    let type: ComAtprotoModerationDefs.ReasonType
    let title: LocalizedStringResource
    let description: LocalizedStringResource

    var id: String { type.rawValue }
  }

  private let reasons: [ReasonOption] = [
    ReasonOption(
      type: .comatprotomoderationdefsreasonspam,
      title: LocalizedStringResource("Spam", comment: "Chat report reason title"),
      description: LocalizedStringResource("Excessive, unwanted, or repetitive messages", comment: "Chat report reason description for spam")
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonviolation,
      title: LocalizedStringResource("Terms of Service Violation", comment: "Chat report reason title"),
      description: LocalizedStringResource("Violates the platform terms or safety rules", comment: "Chat report reason description for terms violation")
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonmisleading,
      title: LocalizedStringResource("Scam or Fraud", comment: "Chat report reason title"),
      description: LocalizedStringResource("Phishing, impersonation, or financial deception", comment: "Chat report reason description for scam or fraud")
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonsexual,
      title: LocalizedStringResource("Unwanted Sexual Content", comment: "Chat report reason title"),
      description: LocalizedStringResource("Explicit, harassing, or non-consensual sexual content", comment: "Chat report reason description for unwanted sexual content")
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonrude,
      title: LocalizedStringResource("Harassment or Hate", comment: "Chat report reason title"),
      description: LocalizedStringResource("Targeted harassment, bullying, or hate speech", comment: "Chat report reason description for harassment or hate")
    ),
    ReasonOption(
      type: .comatprotomoderationdefsreasonother,
      title: LocalizedStringResource("Other", comment: "Chat report reason title"),
      description: LocalizedStringResource("An issue not covered by other categories", comment: "Chat report reason description for other issues")
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

      if let footnote {
        Section {
          Label(footnote, systemImage: "lock")
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

      if showsDetails {
        Section("Additional Details (Optional)") {
          TextEditor(text: $additionalDetails)
            .frame(minHeight: 80)
        }
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
            onSubmit(
              selectedReason,
              showsDetails ? additionalDetails.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            )
          }
          .fontWeight(.semibold)
        }
      }
    }
    .disabled(isSubmitting)
  }
}
