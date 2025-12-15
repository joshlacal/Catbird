//
//  MLSReportMemberSheet.swift
//  Catbird
//
//  Report form for MLS conversation members
//
//  NOTE: Deprecated/hidden while MLS moderation relies on direct removals.

import SwiftUI
import Petrel
import OSLog

#if os(iOS)

struct MLSReportMemberSheet: View {
    // MARK: - Dependencies

    let conversationId: String
    let memberDid: String
    let memberDisplayName: String
    let conversationManager: MLSConversationManager

    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var selectedReason: ReportReason?
    @State private var details = ""
    @State private var isSubmitting = false
    @State private var showingSuccess = false
    @State private var showingError = false
    @State private var errorMessage: String?

    private let logger = Logger(subsystem: "blue.catbird", category: "MLSReportMember")

    // MARK: - Report Reasons

    enum ReportReason: String, CaseIterable, Identifiable {
        case harassment = "Harassment"
        case spam = "Spam"
        case inappropriate = "Inappropriate Content"
        case impersonation = "Impersonation"
        case other = "Other"

        var id: String { rawValue }

        var description: String {
            switch self {
            case .harassment:
                return "Abusive or threatening behavior"
            case .spam:
                return "Unwanted or repetitive messages"
            case .inappropriate:
                return "Offensive or inappropriate content"
            case .impersonation:
                return "Pretending to be someone else"
            case .other:
                return "Other violation"
            }
        }

        var icon: String {
            switch self {
            case .harassment: return "exclamationmark.bubble"
            case .spam: return "envelope.badge"
            case .inappropriate: return "eye.slash"
            case .impersonation: return "person.crop.circle.badge.questionmark"
            case .other: return "ellipsis.circle"
            }
        }
    }

    // MARK: - Computed Properties

    private var canSubmit: Bool {
        selectedReason != nil && !isSubmitting
    }

    private var detailsPlaceholder: String {
        "Please provide additional details about this report (optional but recommended)"
    }

    private let detailsCharacterLimit = 500

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Form {
                // Member info section
                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.red.gradient)
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.white)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Report Member")
                                .font(.headline)
                            Text(memberDisplayName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Reason selection
                Section {
                    ForEach(ReportReason.allCases) { reason in
                        Button {
                            selectedReason = reason
                        } label: {
                            HStack {
                                Image(systemName: reason.icon)
                                    .frame(width: 24)
                                    .foregroundStyle(selectedReason == reason ? .blue : .secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reason.rawValue)
                                        .foregroundStyle(.primary)
                                    Text(reason.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if selectedReason == reason {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Reason for Report")
                } footer: {
                    if selectedReason == nil {
                        Text("Please select a reason for this report")
                            .foregroundStyle(.red)
                    }
                }

                // Details section
                Section {
                    ZStack(alignment: .topLeading) {
                        if details.isEmpty {
                            Text(detailsPlaceholder)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }

                        TextEditor(text: $details)
                            .frame(minHeight: 120)
                            .onChange(of: details) { _, newValue in
                                // Limit character count
                                if newValue.count > detailsCharacterLimit {
                                    details = String(newValue.prefix(detailsCharacterLimit))
                                }
                            }
                    }

                    HStack {
                        Spacer()
                        Text("\(details.count)/\(detailsCharacterLimit)")
                            .font(.caption)
                            .foregroundStyle(details.count >= detailsCharacterLimit ? .red : .secondary)
                    }
                } header: {
                    Text("Additional Details")
                } footer: {
                    Text("Provide specific examples or context to help moderators understand this report")
                }

                // Info section
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your report will be reviewed by conversation administrators", systemImage: "info.circle")
                            .font(.caption)

                        Label("False reports may result in action against your account", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Report Member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            await submitReport()
                        }
                    }
                    .disabled(!canSubmit)
                    .fontWeight(.semibold)
                }
            }
            .disabled(isSubmitting)
            .overlay {
                if isSubmitting {
                    LoadingOverlay()
                }
            }
            .alert("Report Submitted", isPresented: $showingSuccess) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Thank you for your report. Administrators will review it and take appropriate action.")
            }
            .alert("Error", isPresented: $showingError) {
                Button("Retry") {
                    Task {
                        await submitReport()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                }
            }
        }
    }

    // MARK: - Actions

    @MainActor
    private func submitReport() async {
        guard let reason = selectedReason else { return }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let _ = try await conversationManager.reportMember(
                in: conversationId,
                memberDid: memberDid,
                reason: reason.rawValue,
                details: details.isEmpty ? nil : details
            )

            logger.info("Successfully submitted report for member: \(self.memberDid)")
            showingSuccess = true
        } catch {
            logger.error("Failed to submit report: \(error.localizedDescription)")
            errorMessage = "Failed to submit report. Please try again."
            showingError = true
        }
    }
}

// MARK: - Loading Overlay

private struct LoadingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .tint(.white)
                Text("Submitting Report...")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

#endif
