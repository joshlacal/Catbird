import SwiftUI
import Petrel

/// View for inspecting labels applied to the user's account or post, with appeal actions for third-party labeler labels.
struct LabelsOnMeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    let labels: [ComAtprotoLabelDefs.Label]
    let targetDescription: String
    let viewerDID: String
    let reportingService: ReportingService
    
    @State private var appealingLabel: ComAtprotoLabelDefs.Label?
    @State private var appealDetails: String = ""
    @State private var isSubmittingAppeal: Bool = false
    @State private var appealErrorMessage: String? = nil
    @State private var showingAlreadyAppealedAlert: Bool = false
    @State private var showingSuccessAlert: Bool = false
    
    private var activeLabels: [ComAtprotoLabelDefs.Label] {
        labels.filter { ReportingService.isLabelActive($0) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Labels Applied To")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(targetDescription)
                            .font(.headline)
                    }
                    .padding(.vertical, 2)
                }
                
                if activeLabels.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.green)
                            Text("No Active Labels")
                                .font(.headline)
                            Text("There are no active content moderation labels applied.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                } else {
                    Section("Active Labels (\(activeLabels.count))") {
                        ForEach(Array(activeLabels.enumerated()), id: \.offset) { _, label in
                            labelRow(for: label)
                        }
                    }
                }
            }
            .navigationTitle("Applied Labels")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .sheet(item: $appealingLabel) { label in
                appealSheet(for: label)
            }
            .alert("Appeal Already Submitted", isPresented: $showingAlreadyAppealedAlert) {
                Button("OK", role: .cancel) {
                    appealingLabel = nil
                }
            } message: {
                Text("This label has already been appealed and is currently under review by the moderation service.")
            }
            .alert("Appeal Submitted", isPresented: $showingSuccessAlert) {
                Button("OK") {
                    appealingLabel = nil
                }
            } message: {
                Text("Your appeal has been submitted to the moderation service for review.")
            }
        }
    }
    
    // MARK: - Row
    
    @ViewBuilder
    private func labelRow(for label: ComAtprotoLabelDefs.Label) -> some View {
        let isSelf = ReportingService.isSelfLabel(label, viewerDID: viewerDID)
        let isAccountLevel = label.cid == nil
        
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label.val)
                    .font(.body)
                    .fontWeight(.semibold)
                
                Spacer()
                
                if isSelf {
                    Text("Self-Applied")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                } else {
                    Button("Appeal") {
                        appealDetails = ""
                        appealErrorMessage = nil
                        appealingLabel = label
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Source:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(label.src.didString())
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                HStack(spacing: 4) {
                    Text("Scope:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(isAccountLevel ? "Whole Account" : "This Post")
                        .font(.caption)
                        .foregroundStyle(isAccountLevel ? .orange : .blue)
                }
                
                HStack(spacing: 4) {
                    Text("Applied:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(label.cts.date, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                if let expDate = label.exp?.date {
                    HStack(spacing: 4) {
                        Text("Expires:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(expDate, style: .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Appeal Sheet
    
    @ViewBuilder
    private func appealSheet(for label: ComAtprotoLabelDefs.Label) -> some View {
        NavigationStack {
            Form {
                Section("Label Details") {
                    HStack {
                        Text("Label")
                        Spacer()
                        Text(label.val)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Labeler")
                        Spacer()
                        Text(label.src.didString())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Section(header: Text("Reason for Appeal"), footer: Text("Explain why you believe this label was applied in error. Your appeal will be routed directly to the issuing moderation service.")) {
                    TextField("Enter details explaining your appeal...", text: $appealDetails, axis: .vertical)
                        .lineLimit(4...8)
                }
                
                if let error = appealErrorMessage {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                
                Section {
                    Button {
                        Task {
                            await submitAppeal(for: label)
                        }
                    } label: {
                        if isSubmittingAppeal {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Submitting...")
                                Spacer()
                            }
                        } else {
                            Text("Submit Appeal")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmittingAppeal || appealDetails.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Appeal Label")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        appealingLabel = nil
                    }
                    .disabled(isSubmittingAppeal)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func submitAppeal(for label: ComAtprotoLabelDefs.Label) async {
        isSubmittingAppeal = true
        appealErrorMessage = nil
        
        do {
            let details = appealDetails.trimmingCharacters(in: .whitespacesAndNewlines)
            let success = try await reportingService.submitAppeal(
                label: label,
                viewerDID: viewerDID,
                details: details.isEmpty ? nil : details
            )
            
            if success {
                showingSuccessAlert = true
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: "Appeal submitted",
                            icon: "checkmark.shield.fill",
                            duration: 2.5
                        )
                    )
                }
            } else {
                appealErrorMessage = "Failed to submit appeal. Please try again."
            }
        } catch LabelAppealError.alreadyAppealed {
            showingAlreadyAppealedAlert = true
        } catch LabelAppealError.selfLabelNotAppealable {
            appealErrorMessage = "Self-applied labels cannot be appealed."
        } catch {
            appealErrorMessage = "Error: \(error.localizedDescription)"
        }
        
        isSubmittingAppeal = false
    }
}

// MARK: - Identifiable Extension for Sheet

extension ComAtprotoLabelDefs.Label: @retroactive Identifiable {
    public var id: String {
        "\(src.didString())-\(uri.uriString)-\(val)-\(cid?.description ?? "none")"
    }
}
