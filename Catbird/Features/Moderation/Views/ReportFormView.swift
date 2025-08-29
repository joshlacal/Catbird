import SwiftUI
import Petrel

/// View for submitting reports for content or users
struct ReportFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reportingService: ReportingService
    
    // Report data
    @State private var selectedReason: ComAtprotoModerationDefs.ReasonType
    @State private var customReason: String = ""
    @State private var selectedLabeler: AppBskyLabelerDefs.LabelerViewDetailed?
    
    // UI state
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var availableLabelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
    @State private var showingLabelerPicker = false
    @State private var showingSuccessAlert = false
    
    private let subject: ComAtprotoModerationCreateReport.InputSubjectUnion
    private let contentDescription: String
    
    init(
        reportingService: ReportingService,
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        contentDescription: String
    ) {
        self._reportingService = State(initialValue: reportingService)
        self.subject = subject
        self.contentDescription = contentDescription
        // Default to "other" reason
        self._selectedReason = State(initialValue: .comatprotomoderationdefsreasonother)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Content being reported") {
                    Text(contentDescription)
                        .padding(.vertical, 4)
                }
                
                Section("Reason for report") {
                    Picker("Reason", selection: $selectedReason) {
                        ForEach(ComAtprotoModerationDefs.ReasonType.predefinedValues, id: \.self) { reason in
                            Text(reasonDisplayName(reason))
                                .tag(reason)
                        }
                    }
                    .pickerStyle(.menu)
                    
                    TextField("Additional details (optional)", text: $customReason, axis: .vertical)
                        .lineLimit(3...6)
                }
                
                Section("Submit to") {
                    if availableLabelers.isEmpty {
                        HStack {
                            Text("Loading available labelers...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Button {
                            showingLabelerPicker = true
                        } label: {
                            HStack {
                                Text("Moderation service")
                                Spacer()
                                if let selectedLabeler = selectedLabeler {
                                    Text(selectedLabeler.creator.displayName ?? selectedLabeler.creator.handle.description)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Select")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                
                Section {
                    Button {
                        Task {
                            await submitReport()
                        }
                    } label: {
                        if isSubmitting {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.horizontal, 8)
                                Text("Submitting...")
                                Spacer()
                            }
                        } else {
                            Text("Submit Report")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isSubmitting || selectedLabeler == nil)
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Report Content")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingLabelerPicker) {
                LabelerPickerView(
                    availableLabelers: availableLabelers,
                    selectedLabeler: $selectedLabeler
                )
                .presentationDetents([.medium, .large])
            }
            .alert("Report Submitted", isPresented: $showingSuccessAlert) {
                Button("OK") {
                    dismiss()
                }
            } message: {
                Text("Thank you for your report. The moderation team will review it.")
            }
            .task {
                await loadLabelers()
            }
        }
    }
    
    private func loadLabelers() async {
        do {
            // Try to get user's subscribed labelers
            availableLabelers = try await reportingService.getSubscribedLabelers()
            
            // If no labelers found, try to get the default Bluesky moderation service
            if availableLabelers.isEmpty {
                if let bskyLabeler = try await reportingService.getBlueSkyModerationService() {
                    availableLabelers = [bskyLabeler]
                }
            }
            
            // Default to Bluesky moderation service if available
            if selectedLabeler == nil, let bskyLabeler = availableLabelers.first(where: { 
                $0.creator.handle.description == "moderation.bsky.app" 
            }) {
                selectedLabeler = bskyLabeler
            }
        } catch {
            errorMessage = "Failed to load available moderation services: \(error.localizedDescription)"
        }
    }
    
    private func submitReport() async {
        guard let labeler = selectedLabeler else {
            errorMessage = "Please select a moderation service"
            return
        }
        
        isSubmitting = true
        errorMessage = nil
        
        do {
            let success = try await reportingService.submitReport(
                subject: subject,
                reasonType: selectedReason,
                reason: customReason.isEmpty ? nil : customReason,
                labelerDid: labeler.creator.did.didString()
            )
            
            if success {
                showingSuccessAlert = true
            } else {
                errorMessage = "Failed to submit report. Please try again."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
        
        isSubmitting = false
    }
    
    private func reasonDisplayName(_ reason: ComAtprotoModerationDefs.ReasonType) -> String {
        switch reason {
        case .comatprotomoderationdefsreasonspam:
            return "Spam"
        case .comatprotomoderationdefsreasonviolation:
            return "Terms of Service Violation"
        case .comatprotomoderationdefsreasonmisleading:
            return "Misleading or False Information"
        case .comatprotomoderationdefsreasonsexual:
            return "Sexual Content"
        case .comatprotomoderationdefsreasonrude:
            return "Harassment or Rude Behavior"
        case .comatprotomoderationdefsreasonother:
            return "Other"
        case .comatprotomoderationdefsreasonappeal:
            return "Appeal Prior Moderation"
        default:
            return "Unknown Reason"
        }
    }
}

// #Preview {
//    // Mock data for preview
//    let mockReportingService = ReportingService(client: ATProtoClient(authMethod: .legacy, oauthConfig: .init(), baseURL: URL(string: "https://bsky.social")!, namespace: "", environment: .production))
//    
//    return ReportFormView(
//        reportingService: mockReportingService,
//        subject: .comAtprotoRepoStrongRef(ComAtprotoRepoStrongRef(uri: ATProtocolURI("at://did:example"), cid: "example")),
//        contentDescription: "Post by @example.bsky.social"
//    )
// }
