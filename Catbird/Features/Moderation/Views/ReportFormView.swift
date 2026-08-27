import SwiftUI
import Petrel

/// Top-level categories for ATProto/Ozone moderation reporting
enum ReportCategory: String, CaseIterable, Identifiable {
    case misleading = "misleading"
    case harassment = "harassment"
    case violence = "violence"
    case sexual = "sexual"
    case childSafety = "childSafety"
    case selfHarm = "selfHarm"
    case ruleBreaking = "ruleBreaking"
    case other = "other"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .misleading: return "Misleading, Spam, or Scams"
        case .harassment: return "Harassment & Hate"
        case .violence: return "Violence & Physical Harm"
        case .sexual: return "Adult & Sexual Content"
        case .childSafety: return "Child Safety"
        case .selfHarm: return "Self-Harm & Eating Disorders"
        case .ruleBreaking: return "Rule Breaking & Security"
        case .other: return "Other Issue"
        }
    }
    
    var subtitle: String {
        switch self {
        case .misleading: return "Spam, bots, fake accounts, or impersonation"
        case .harassment: return "Bullying, hate speech, threats, or doxxing"
        case .violence: return "Graphic violence, threats, or violent extremism"
        case .sexual: return "Nudity, sexual activity, or non-consensual content"
        case .childSafety: return "Child exploitation, grooming, or abuse (Bluesky Official)"
        case .selfHarm: return "Suicide, self-injury, or eating disorder promotion"
        case .ruleBreaking: return "Malware, prohibited goods, or ban evasion"
        case .other: return "Any other reason not listed above"
        }
    }
    
    var iconName: String {
        switch self {
        case .misleading: return "exclamationmark.triangle.fill"
        case .harassment: return "hand.raised.fill"
        case .violence: return "bolt.shield.fill"
        case .sexual: return "eye.slash.fill"
        case .childSafety: return "person.badge.shield.checkmark.fill"
        case .selfHarm: return "heart.slash.fill"
        case .ruleBreaking: return "shield.slash.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .misleading: return .orange
        case .harassment: return .red
        case .violence: return .red
        case .sexual: return .pink
        case .childSafety: return .blue
        case .selfHarm: return .purple
        case .ruleBreaking: return .gray
        case .other: return .secondary
        }
    }
    
    var reasons: [(reason: ComAtprotoModerationDefs.ReasonType, title: String, description: String)] {
        switch self {
        case .misleading:
            return [
                (.toolsozonereportdefsreasonmisleadingspam, "Spam", "Excessive unwanted posts, mentions, or automated junk"),
                (.toolsozonereportdefsreasonmisleadingbot, "Bot Account", "Automated account operating without disclosure or maliciously"),
                (.toolsozonereportdefsreasonmisleadingimpersonation, "Impersonation", "Pretending to be another person or organization"),
                (.toolsozonereportdefsreasonmisleadingscam, "Scam or Fraud", "Financial scams, phishing, or deceptive links"),
                (.toolsozonereportdefsreasonmisleadingelections, "Election Misinformation", "False voting dates, polling info, or suppression"),
                (.toolsozonereportdefsreasonmisleadingother, "Other Misleading Behavior", "Other deceptive behavior")
            ]
        case .harassment:
            return [
                (.toolsozonereportdefsreasonharassmenttargeted, "Targeted Harassment", "Persistent bullying, stalking, or targeted abuse"),
                (.toolsozonereportdefsreasonharassmenthatespeech, "Hate Speech", "Attacks based on protected identity, race, religion, gender"),
                (.toolsozonereportdefsreasonharassmentdoxxing, "Doxxing / Private Info", "Posting private personal information without consent"),
                (.toolsozonereportdefsreasonharassmenttroll, "Trolling / Incitement", "Inciting mob harassment or coordinated bad-faith attacks"),
                (.toolsozonereportdefsreasonharassmentother, "Other Harassment", "Other forms of harassment")
            ]
        case .violence:
            return [
                (.toolsozonereportdefsreasonviolencethreats, "Threats of Violence", "Statements expressing intent to inflict serious harm"),
                (.toolsozonereportdefsreasonviolencegraphiccontent, "Graphic Violence or Gore", "Depictions of severe injury, bloodshed, or death"),
                (.toolsozonereportdefsreasonviolenceglorification, "Glorification of Violence", "Praising or celebrating violent acts"),
                (.toolsozonereportdefsreasonviolenceextremistcontent, "Violent Extremism / Terrorism", "Promotion of violent extremist groups (Bluesky Official)"),
                (.toolsozonereportdefsreasonviolencetrafficking, "Human Trafficking", "Trafficking or forced labor"),
                (.toolsozonereportdefsreasonviolenceanimal, "Animal Cruelty", "Abuse or harm directed toward animals"),
                (.toolsozonereportdefsreasonviolenceother, "Other Violence", "Other violent or threatening content")
            ]
        case .sexual:
            return [
                (.toolsozonereportdefsreasonsexualncii, "Non-Consensual Intimate Imagery", "Intimate photos or videos shared without consent"),
                (.toolsozonereportdefsreasonsexualdeepfake, "Sexually Explicit Deepfakes", "Manipulated sexual imagery or generative explicit media"),
                (.toolsozonereportdefsreasonsexualunlabeled, "Unlabeled Adult Content", "Adult or sexually explicit content posted without adult content labels"),
                (.toolsozonereportdefsreasonsexualabusecontent, "Sexual Violence / Assault", "Depiction or promotion of sexual violence"),
                (.toolsozonereportdefsreasonsexualanimal, "Bestiality", "Sexual acts involving animals"),
                (.toolsozonereportdefsreasonsexualother, "Other Sexual Content", "Other explicit or inappropriate sexual content")
            ]
        case .childSafety:
            return [
                (.toolsozonereportdefsreasonchildsafetycsam, "Child Sexual Abuse Material (CSAM)", "Zero-tolerance CSAM content (Official Bluesky Moderation)"),
                (.toolsozonereportdefsreasonchildsafetygroom, "Grooming / Exploitation", "Predatory behavior targeting minors (Official Bluesky Moderation)"),
                (.toolsozonereportdefsreasonchildsafetyprivacy, "Child Privacy Violation", "Exposing private details or images of minors"),
                (.toolsozonereportdefsreasonchildsafetyharassment, "Harassment of a Minor", "Targeted harassment or bullying of a minor"),
                (.toolsozonereportdefsreasonchildsafetyother, "Other Child Safety Concern", "Other risks to child safety")
            ]
        case .selfHarm:
            return [
                (.toolsozonereportdefsreasonselfharmcontent, "Suicide or Self-Harm", "Encouragement or instruction for self-injury or suicide"),
                (.toolsozonereportdefsreasonselfharmed, "Eating Disorders", "Promotion or glorification of disordered eating"),
                (.toolsozonereportdefsreasonselfharmstunts, "Dangerous Stunts", "Extremely hazardous challenges or stunts"),
                (.toolsozonereportdefsreasonselfharmsubstances, "Substance Abuse", "Encouraging lethal or high-risk drug abuse"),
                (.toolsozonereportdefsreasonselfharmother, "Other Self-Harm", "Other self-harm concerns")
            ]
        case .ruleBreaking:
            return [
                (.toolsozonereportdefsreasonrulesitesecurity, "Site Security & Malware", "Hacking, credential harvesting, malware, or exploits"),
                (.toolsozonereportdefsreasonruleprohibitedsales, "Prohibited Goods", "Illegal sales of drugs, weapons, or regulated items"),
                (.toolsozonereportdefsreasonrulebanevasion, "Ban Evasion", "Operating an account to evade an active ban"),
                (.toolsozonereportdefsreasonruleother, "Other Policy Violation", "Other violation of platform terms")
            ]
        case .other:
            return [
                (.comatprotomoderationdefsreasonother, "Other Issue", "Any other violation or concern")
            ]
        }
    }
}

/// View for submitting reports for content or users via a multi-step wizard
struct ReportFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var reportingService: ReportingService
    
    // Wizard step state
    enum WizardStep {
        case selectCategory
        case selectReason(ReportCategory)
        case nciiBranch
        case reviewAndSubmit
    }
    
    @State private var currentStep: WizardStep = .selectCategory
    @State private var selectedCategory: ReportCategory?
    @State private var selectedReason: ComAtprotoModerationDefs.ReasonType = .comatprotomoderationdefsreasonother
    @State private var selectedReasonTitle: String = "Other"
    @State private var customReason: String = ""
    @State private var selectedLabeler: AppBskyLabelerDefs.LabelerViewDetailed?
    @State private var availableLabelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
    @State private var includeVideoTimestamp: Bool = false
    
    // UI state
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showingLabelerPicker = false
    @State private var showingSuccessAlert = false
    
    private let subject: ComAtprotoModerationCreateReport.InputSubjectUnion
    private let contentDescription: String
    private let videoTimestamp: Double?
    private let onComplete: ((Bool) -> Void)?
    
    init(
        reportingService: ReportingService,
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        contentDescription: String,
        videoTimestamp: Double? = nil,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        self._reportingService = State(initialValue: reportingService)
        self.subject = subject
        self.contentDescription = contentDescription
        if let videoTimestamp = videoTimestamp {
            self.videoTimestamp = videoTimestamp
        } else if case .comAtprotoRepoStrongRef(let strongRef) = subject {
            let uriString = strongRef.uri.uriString()
            let cidString = strongRef.cid.string
            self.videoTimestamp = VideoPlaybackPositionProvider.shared.getPosition(forSubject: uriString)
                ?? VideoPlaybackPositionProvider.shared.getPosition(forSubject: cidString)
        } else {
            self.videoTimestamp = nil
        }
        self.onComplete = onComplete
    }
    
    var body: some View {
        NavigationStack {
            contentForStep
                .navigationTitle(navigationTitle)
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
                        onComplete?(true)
                        dismiss()
                    }
                } message: {
                    Text("Thank you for your report. It has been sent for review.")
                }
                .task {
                    await loadLabelers()
                }
        }
    }
    
    private var navigationTitle: String {
        switch currentStep {
        case .selectCategory:
            return "Report"
        case .selectReason:
            return "Select Reason"
        case .nciiBranch:
            return "NCII Removal"
        case .reviewAndSubmit:
            return "Review & Submit"
        }
    }
    
    @ViewBuilder
    private var contentForStep: some View {
        switch currentStep {
        case .selectCategory:
            categorySelectionView
        case .selectReason(let category):
            reasonSelectionView(category: category)
        case .nciiBranch:
            nciiBranchView
        case .reviewAndSubmit:
            reviewAndSubmitView
        }
    }
    
    // MARK: - Step 1: Category Selection
    
    private var categorySelectionView: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reporting")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(contentDescription)
                        .font(.headline)
                }
                .padding(.vertical, 4)
            }
            
            Section("Why are you reporting this?") {
                ForEach(ReportCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                        currentStep = .selectReason(category)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.iconName)
                                .font(.title3)
                                .foregroundStyle(category.iconColor)
                                .frame(width: 28)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(category.title)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                Text(category.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    // MARK: - Step 2: Reason Selection
    
    private func reasonSelectionView(category: ReportCategory) -> some View {
        Form {
            Section {
                Button {
                    currentStep = .selectCategory
                } label: {
                    Label("Back to categories", systemImage: "chevron.left")
                        .font(.subheadline)
                }
            }
            
            Section(category.title) {
                ForEach(category.reasons, id: \.reason.rawValue) { item in
                    Button {
                        selectedReason = item.reason
                        selectedReasonTitle = item.title
                        
                        if ReportingService.isNCIIReason(item.reason) {
                            currentStep = .nciiBranch
                        } else {
                            // If Bluesky-only reason, enforce Bluesky official labeler
                            if ReportingService.isBlueskyOnlyReason(item.reason) {
                                if let bsky = availableLabelers.first(where: { $0.creator.did.didString() == ReportingService.officialBlueskyDID }) {
                                    selectedLabeler = bsky
                                }
                            }
                            currentStep = .reviewAndSubmit
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.body)
                                .fontWeight(.medium)
                                .foregroundStyle(.primary)
                            Text(item.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
    
    // MARK: - Step 3: NCII Branching
    
    private var nciiBranchView: some View {
        Form {
            Section("Non-Consensual Intimate Imagery") {
                Text("Are you depicted in this image/video, or are you an authorized representative of the person depicted?")
                    .font(.subheadline)
                    .padding(.vertical, 4)
                
                Button {
                    if let url = URL(string: "https://blueskyweb.zendesk.com/hc/en-us/requests/new?ticket_form_id=24729188849421") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Yes — Open Official Removal Request")
                                .fontWeight(.semibold)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                        }
                        Text("Opens the official Bluesky emergency takedown request form.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                
                Button {
                    currentStep = .reviewAndSubmit
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No — Report on Behalf of Someone Else")
                            .fontWeight(.medium)
                        Text("Continue submitting an in-app report for moderator review.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Section {
                Button("Back") {
                    if let cat = selectedCategory {
                        currentStep = .selectReason(cat)
                    } else {
                        currentStep = .selectCategory
                    }
                }
            }
        }
    }
    
    // MARK: - Step 4: Review & Submit
    
    private var isBlueskyOnly: Bool {
        ReportingService.isBlueskyOnlyReason(selectedReason)
    }
    
    private var reviewAndSubmitView: some View {
        Form {
            Section("Subject") {
                Text(contentDescription)
                    .font(.body)
            }
            
            Section("Reason") {
                HStack {
                    Text("Violation")
                    Spacer()
                    Text(selectedReasonTitle)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Moderation Service") {
                if isBlueskyOnly {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Official Bluesky Moderation")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(.blue)
                        }
                        Text("Child safety and violent extremism reports are always routed directly to official Bluesky safety teams.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else if availableLabelers.isEmpty {
                    HStack {
                        Text("Loading moderation services...")
                        Spacer()
                        ProgressView()
                    }
                } else {
                    Button {
                        showingLabelerPicker = true
                    } label: {
                        HStack {
                            Text("Service")
                            Spacer()
                            let displayName = selectedLabeler?.creator.handle.description == "moderation.bsky.app"
                                ? "Official Bluesky Moderation"
                                : (selectedLabeler?.creator.displayName ?? selectedLabeler?.creator.handle.description ?? "Select")
                            Text(displayName)
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            
            // Video timestamp toggle (if available and >= 1 second, and submitting to official labeler)
            if let timestamp = videoTimestamp, timestamp >= 1.0, (selectedLabeler == nil || selectedLabeler?.creator.did.didString() == ReportingService.officialBlueskyDID) {
                Section("Video Attachment") {
                    Toggle("Include video timestamp (\(formatTimestamp(timestamp)))", isOn: $includeVideoTimestamp)
                        .tint(.blue)
                    Text("Helps moderators jump directly to the reported section of the video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("Additional Details (Optional)") {
                TextField("Add any extra context for moderators (optional)", text: $customReason, axis: .vertical)
                    .lineLimit(3...6)
            }
            
            if let errorMessage = errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
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
            
            Section {
                Button("Back to reasons") {
                    if let cat = selectedCategory {
                        currentStep = .selectReason(cat)
                    } else {
                        currentStep = .selectCategory
                    }
                }
            }
        }
    }
    
    // MARK: - Helpers & Actions
    
    private func formatTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(floor(seconds))
        let minutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
    
    private func loadLabelers() async {
        do {
            availableLabelers = try await reportingService.getSubscribedLabelers()
            
            if selectedLabeler == nil, let firstLabeler = availableLabelers.first {
                selectedLabeler = firstLabeler
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
        
        let timestampSeconds: Int? = (includeVideoTimestamp && videoTimestamp != nil) ? Int(floor(videoTimestamp!)) : nil
        let targetLabelerDid = isBlueskyOnly ? ReportingService.officialBlueskyDID : labeler.creator.did.didString()
        
        do {
            let success = try await reportingService.submitReport(
                subject: subject,
                reasonType: selectedReason,
                reason: customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customReason.trimmingCharacters(in: .whitespacesAndNewlines),
                labelerDid: targetLabelerDid,
                videoTimestampSeconds: timestampSeconds
            )
            
            if success {
                showingSuccessAlert = true
                
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: "Report submitted",
                            icon: "flag.fill",
                            duration: 2.5
                        )
                    )
                }
            } else {
                errorMessage = "Failed to submit report. Please try again."
            }
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
        
        isSubmitting = false
    }
}
