//
//  StarterPackWizardView.swift
//  Catbird
//
//  Created for Bluesky social app parity (WS-H / G57).
//

import SwiftUI
import Petrel
import OSLog

public struct StarterPackWizardView: View {
    public enum WizardMode {
        case create
        case edit(existingPack: AppBskyGraphDefs.StarterPackView)
    }
    
    public enum WizardStep: Int, CaseIterable, Identifiable {
        case details = 0
        case profiles = 1
        case feeds = 2
        
        public var id: Int { rawValue }
        
        public var title: String {
            switch self {
            case .details: return "Details"
            case .profiles: return "People"
            case .feeds: return "Feeds"
            }
        }
    }
    
    let mode: WizardMode
    var onCompletion: ((ATProtocolURI) -> Void)?
    
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    
    @State private var currentStep: WizardStep = .details
    @State private var draft: StarterPackDraft = StarterPackDraft()
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var showingErrorAlert: Bool = false
    @State private var isPreloadingEdit: Bool = false
    
    private let logger = Logger(subsystem: "blue.catbird", category: "StarterPackWizardView")
    
    public init(
        mode: WizardMode = .create,
        onCompletion: ((ATProtocolURI) -> Void)? = nil
    ) {
        self.mode = mode
        self.onCompletion = onCompletion
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Step Indicator Bar
                stepIndicator
                    .padding(.vertical, 8)
                
                if isPreloadingEdit {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Loading starter pack details...")
                            .appFont(AppTextRole.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Step Content
                    Group {
                        switch currentStep {
                        case .details:
                            StarterPackDetailsStep(draft: $draft)
                        case .profiles:
                            StarterPackProfilesStep(draft: $draft)
                        case .feeds:
                            StarterPackFeedsStep(draft: $draft)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                
                // Bottom Action Bar
                bottomBar
            }
            .navigationTitle(navigationTitle)
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSubmitting)
                }
            }
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "An unknown error occurred.")
            }
            .task {
                await preloadEditStateIfNeeded()
            }
        }
    }
    
    private var navigationTitle: String {
        switch mode {
        case .create:
            return "New Starter Pack"
        case .edit:
            return "Edit Starter Pack"
        }
    }
    
    // MARK: - Step Indicator
    
    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(WizardStep.allCases) { step in
                HStack(spacing: 6) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text("\(step.rawValue + 1)")
                                .appFont(AppTextRole.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(step.rawValue <= currentStep.rawValue ? .white : .secondary)
                        )
                    
                    Text(step.title)
                        .appFont(AppTextRole.caption)
                        .fontWeight(step == currentStep ? .bold : .regular)
                        .foregroundColor(step == currentStep ? .primary : .secondary)
                }
                
                if step.rawValue < WizardStep.allCases.count - 1 {
                    Rectangle()
                        .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Bottom Action Bar
    
    private var bottomBar: some View {
        HStack(spacing: 16) {
            if currentStep.rawValue > 0 {
                Button {
                    withAnimation {
                        if let prevStep = WizardStep(rawValue: currentStep.rawValue - 1) {
                            currentStep = prevStep
                        }
                    }
                } label: {
                    Text("Back")
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.systemGray5))
                        .foregroundColor(.primary)
                }
                .disabled(isSubmitting)
            }
            
            Spacer()
            
            if currentStep == .feeds {
                Button {
                    Task {
                        await finishWizard()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSubmitting {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(submitButtonTitle)
                            .appFont(AppTextRole.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(draft.isValid && !isSubmitting ? Color.accentColor : Color.gray.opacity(0.4))
                    )
                    .foregroundColor(.white)
                }
                .disabled(!draft.isValid || isSubmitting)
            } else {
                Button {
                    withAnimation {
                        if let nextStep = WizardStep(rawValue: currentStep.rawValue + 1) {
                            currentStep = nextStep
                        }
                    }
                } label: {
                    Text("Next")
                        .appFont(AppTextRole.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(isCurrentStepValid ? Color.accentColor : Color.gray.opacity(0.4))
                        )
                        .foregroundColor(.white)
                }
                .disabled(!isCurrentStepValid)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.systemBackground)
        .overlay(
            Divider(), alignment: .top
        )
    }
    
    private var submitButtonTitle: String {
        switch mode {
        case .create:
            return "Create Starter Pack"
        case .edit:
            return "Save Changes"
        }
    }
    
    private var isCurrentStepValid: Bool {
        switch currentStep {
        case .details:
            return draft.isNameValid && draft.isDescriptionValid
        case .profiles:
            return draft.isProfilesValid
        case .feeds:
            return draft.isFeedsValid
        }
    }
    
    // MARK: - Preloading for Edit Mode
    
    private func preloadEditStateIfNeeded() async {
        guard case .edit(let pack) = mode else { return }
        guard let client = appState.atProtoClient else { return }
        
        isPreloadingEdit = true
        defer { isPreloadingEdit = false }
        
        // Extract metadata
        var initialName = ""
        var initialDesc = ""
        if case .knownType(let recordValue) = pack.record,
           let starterpack = recordValue as? AppBskyGraphStarterpack {
            initialName = starterpack.name
            initialDesc = starterpack.description ?? ""
        }
        
        var initialFeeds: [AppBskyFeedDefs.GeneratorView] = pack.feeds ?? []
        var initialProfiles: [AppBskyActorDefs.ProfileViewBasic] = []
        
        // Fetch all list items
        if let listUri = pack.list?.uri {
            do {
                let items = try await StarterPackService.shared.fetchAllMembers(client: client, listUri: listUri)
                initialProfiles = items.map { item in
                    let subject = item.subject
                    return AppBskyActorDefs.ProfileViewBasic(
                        did: subject.did,
                        handle: subject.handle,
                        displayName: subject.displayName,
                        pronouns: subject.pronouns,
                        avatar: subject.avatar,
                        associated: subject.associated,
                        viewer: subject.viewer,
                        labels: subject.labels,
                        createdAt: subject.createdAt,
                        verification: subject.verification,
                        status: subject.status,
                        debug: subject.debug
                    )
                }
            } catch {
                logger.error("Failed to preload starter pack members: \(error.localizedDescription)")
            }
        }
        
        self.draft = StarterPackDraft(
            name: initialName,
            description: initialDesc,
            profiles: initialProfiles,
            feeds: initialFeeds
        )
    }
    
    // MARK: - Submission
    
    private func finishWizard() async {
        guard let client = appState.atProtoClient else {
            errorMessage = "Not logged in."
            showingErrorAlert = true
            return
        }
        let accountDID = appState.userDID
        guard draft.isValid else {
            errorMessage = draft.validationError ?? "Invalid draft."
            showingErrorAlert = true
            return
        }
        
        isSubmitting = true
        errorMessage = nil
        
        do {
            switch mode {
            case .create:
                logger.info("Creating starter pack...")
                let packUri = try await StarterPackService.shared.createStarterPack(
                    client: client,
                    draft: draft,
                    accountDID: accountDID
                )
                onCompletion?(packUri)
                dismiss()
                
            case .edit(let existingPack):
                logger.info("Updating starter pack...")
                try await StarterPackService.shared.updateStarterPack(
                    client: client,
                    starterPack: existingPack,
                    draft: draft,
                    accountDID: accountDID
                )
                onCompletion?(existingPack.uri)
                dismiss()
            }
        } catch {
            logger.error("Failed to save starter pack: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            isSubmitting = false
        }
    }
}
