//
//  ReportProfileView.swift
//  Catbird
//
//  Created by Josh LaCalamito on 3/21/25.
//

import SwiftUI
import Petrel

struct ReportProfileView: View {
    let profile: AppBskyActorDefs.ProfileViewDetailed
    let reportingService: ReportingService
    let onComplete: (Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonother
    @State private var customReason: String = ""
    @State private var selectedLabeler: AppBskyLabelerDefs.LabelerViewDetailed?
    @State private var availableLabelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingLabelerPicker = false
    @State private var showingSuccessAlert = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section("User being reported") {
                    HStack {
                        Text("@\(profile.handle)")
                            .appFont(AppTextRole.headline)
                        
                        if let displayName = profile.displayName {
                            Text("(\(displayName))")
                                .foregroundStyle(.secondary)
                        }
                    }
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
            .navigationTitle("Report User")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
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
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
            }
            .alert("Report Submitted", isPresented: $showingSuccessAlert) {
                Button("OK") {
                    dismiss()
                    onComplete(true)
                }
            } message: {
                Text("Thank you for your report. It has been sent to Bluesky.")
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
                if let bskyLabeler = try await reportingService.getBlueskyModerationService() {
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
            // Create a user subject for the report
            let subject = reportingService.createUserSubject(did: profile.did)
            
            // Submit the report
            let success = try await reportingService.submitReport(
                subject: subject,
                reasonType: selectedReason,
                reason: customReason.isEmpty ? nil : customReason,
                labelerDid: labeler.creator.did.description
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
            return "Other"
        }
    }
}
