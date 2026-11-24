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
        case .misleading: return String(localized: "Misleading, Spam, or Scams", comment: "Moderation report category title.")
        case .harassment: return String(localized: "Harassment & Hate", comment: "Moderation report category title.")
        case .violence: return String(localized: "Violence & Physical Harm", comment: "Moderation report category title.")
        case .sexual: return String(localized: "Adult & Sexual Content", comment: "Moderation report category title.")
        case .childSafety: return String(localized: "Child Safety", comment: "Moderation report category title.")
        case .selfHarm: return String(localized: "Self-Harm & Eating Disorders", comment: "Moderation report category title.")
        case .ruleBreaking: return String(localized: "Rule Breaking & Security", comment: "Moderation report category title.")
        case .other: return String(localized: "Other Issue", comment: "Moderation report category title.")
        }
    }
    
    var subtitle: String {
        switch self {
        case .misleading: return String(localized: "Spam, bots, fake accounts, or impersonation", comment: "Moderation report category subtitle.")
        case .harassment: return String(localized: "Bullying, hate speech, threats, or doxxing", comment: "Moderation report category subtitle.")
        case .violence: return String(localized: "Graphic violence, threats, or violent extremism", comment: "Moderation report category subtitle.")
        case .sexual: return String(localized: "Nudity, sexual activity, or non-consensual content", comment: "Moderation report category subtitle.")
        case .childSafety: return String(localized: "Child exploitation, grooming, or abuse (Bluesky Official)", comment: "Moderation report category subtitle.")
        case .selfHarm: return String(localized: "Suicide, self-injury, or eating disorder promotion", comment: "Moderation report category subtitle.")
        case .ruleBreaking: return String(localized: "Malware, prohibited goods, or ban evasion", comment: "Moderation report category subtitle.")
        case .other: return String(localized: "Any other reason not listed above", comment: "Moderation report category subtitle.")
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
                (.toolsozonereportdefsreasonmisleadingspam, String(localized: "Spam", comment: "Moderation report reason."), String(localized: "Excessive unwanted posts, mentions, or automated junk", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonmisleadingbot, String(localized: "Bot Account", comment: "Moderation report reason."), String(localized: "Automated account operating without disclosure or maliciously", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonmisleadingimpersonation, String(localized: "Impersonation", comment: "Moderation report reason."), String(localized: "Pretending to be another person or organization", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonmisleadingscam, String(localized: "Scam or Fraud", comment: "Moderation report reason."), String(localized: "Financial scams, phishing, or deceptive links", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonmisleadingelections, String(localized: "Election Misinformation", comment: "Moderation report reason."), String(localized: "False voting dates, polling info, or suppression", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonmisleadingother, String(localized: "Other Misleading Behavior", comment: "Moderation report reason."), String(localized: "Other deceptive behavior", comment: "Moderation report reason description."))
            ]
        case .harassment:
            return [
                (.toolsozonereportdefsreasonharassmenttargeted, String(localized: "Targeted Harassment", comment: "Moderation report reason."), String(localized: "Persistent bullying, stalking, or targeted abuse", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonharassmenthatespeech, String(localized: "Hate Speech", comment: "Moderation report reason."), String(localized: "Attacks based on protected identity, race, religion, gender", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonharassmentdoxxing, String(localized: "Doxxing / Private Info", comment: "Moderation report reason."), String(localized: "Posting private personal information without consent", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonharassmenttroll, String(localized: "Trolling / Incitement", comment: "Moderation report reason."), String(localized: "Inciting mob harassment or coordinated bad-faith attacks", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonharassmentother, String(localized: "Other Harassment", comment: "Moderation report reason."), String(localized: "Other forms of harassment", comment: "Moderation report reason description."))
            ]
        case .violence:
            return [
                (.toolsozonereportdefsreasonviolencethreats, String(localized: "Threats of Violence", comment: "Moderation report reason."), String(localized: "Statements expressing intent to inflict serious harm", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolencegraphiccontent, String(localized: "Graphic Violence or Gore", comment: "Moderation report reason."), String(localized: "Depictions of severe injury, bloodshed, or death", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolenceglorification, String(localized: "Glorification of Violence", comment: "Moderation report reason."), String(localized: "Praising or celebrating violent acts", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolenceextremistcontent, String(localized: "Violent Extremism / Terrorism", comment: "Moderation report reason."), String(localized: "Promotion of violent extremist groups (Bluesky Official)", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolencetrafficking, String(localized: "Human Trafficking", comment: "Moderation report reason."), String(localized: "Trafficking or forced labor", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolenceanimal, String(localized: "Animal Cruelty", comment: "Moderation report reason."), String(localized: "Abuse or harm directed toward animals", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonviolenceother, String(localized: "Other Violence", comment: "Moderation report reason."), String(localized: "Other violent or threatening content", comment: "Moderation report reason description."))
            ]
        case .sexual:
            return [
                (.toolsozonereportdefsreasonsexualncii, String(localized: "Non-Consensual Intimate Imagery", comment: "Moderation report reason."), String(localized: "Intimate photos or videos shared without consent", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonsexualdeepfake, String(localized: "Sexually Explicit Deepfakes", comment: "Moderation report reason."), String(localized: "Manipulated sexual imagery or generative explicit media", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonsexualunlabeled, String(localized: "Unlabeled Adult Content", comment: "Moderation report reason."), String(localized: "Adult or sexually explicit content posted without adult content labels", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonsexualabusecontent, String(localized: "Sexual Violence / Assault", comment: "Moderation report reason."), String(localized: "Depiction or promotion of sexual violence", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonsexualanimal, String(localized: "Bestiality", comment: "Moderation report reason."), String(localized: "Sexual acts involving animals", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonsexualother, String(localized: "Other Sexual Content", comment: "Moderation report reason."), String(localized: "Other explicit or inappropriate sexual content", comment: "Moderation report reason description."))
            ]
        case .childSafety:
            return [
                (.toolsozonereportdefsreasonchildsafetycsam, String(localized: "Child Sexual Abuse Material (CSAM)", comment: "Moderation report reason."), String(localized: "Zero-tolerance CSAM content (Official Bluesky Moderation)", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonchildsafetygroom, String(localized: "Grooming / Exploitation", comment: "Moderation report reason."), String(localized: "Predatory behavior targeting minors (Official Bluesky Moderation)", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonchildsafetyprivacy, String(localized: "Child Privacy Violation", comment: "Moderation report reason."), String(localized: "Exposing private details or images of minors", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonchildsafetyharassment, String(localized: "Harassment of a Minor", comment: "Moderation report reason."), String(localized: "Targeted harassment or bullying of a minor", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonchildsafetyother, String(localized: "Other Child Safety Concern", comment: "Moderation report reason."), String(localized: "Other risks to child safety", comment: "Moderation report reason description."))
            ]
        case .selfHarm:
            return [
                (.toolsozonereportdefsreasonselfharmcontent, String(localized: "Suicide or Self-Harm", comment: "Moderation report reason."), String(localized: "Encouragement or instruction for self-injury or suicide", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonselfharmed, String(localized: "Eating Disorders", comment: "Moderation report reason."), String(localized: "Promotion or glorification of disordered eating", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonselfharmstunts, String(localized: "Dangerous Stunts", comment: "Moderation report reason."), String(localized: "Extremely hazardous challenges or stunts", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonselfharmsubstances, String(localized: "Substance Abuse", comment: "Moderation report reason."), String(localized: "Encouraging lethal or high-risk drug abuse", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonselfharmother, String(localized: "Other Self-Harm", comment: "Moderation report reason."), String(localized: "Other self-harm concerns", comment: "Moderation report reason description."))
            ]
        case .ruleBreaking:
            return [
                (.toolsozonereportdefsreasonrulesitesecurity, String(localized: "Site Security & Malware", comment: "Moderation report reason."), String(localized: "Hacking, credential harvesting, malware, or exploits", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonruleprohibitedsales, String(localized: "Prohibited Goods", comment: "Moderation report reason."), String(localized: "Illegal sales of drugs, weapons, or regulated items", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonrulebanevasion, String(localized: "Ban Evasion", comment: "Moderation report reason."), String(localized: "Operating an account to evade an active ban", comment: "Moderation report reason description.")),
                (.toolsozonereportdefsreasonruleother, String(localized: "Other Policy Violation", comment: "Moderation report reason."), String(localized: "Other violation of platform terms", comment: "Moderation report reason description."))
            ]
        case .other:
            return [
                (.comatprotomoderationdefsreasonother, String(localized: "Other Issue", comment: "Moderation report reason."), String(localized: "Any other violation or concern", comment: "Moderation report reason description."))
            ]
        }
    }
}

/// View for submitting reports for content or users via a multi-step wizard
struct ReportFormView: View {
    @Environment(\.openURL) private var openURL
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
    @State private var selectedReasonTitle: String = String(localized: "Other", comment: "Default moderation report reason title.")
    @State private var customReason: String = ""
    @State private var selectedLabeler: AppBskyLabelerDefs.LabelerViewDetailed?
    @State private var availableLabelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
    @State private var isLoadingLabelers = false
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
    private let expectedAccountDID: String?
    
    init(
        reportingService: ReportingService,
        subject: ComAtprotoModerationCreateReport.InputSubjectUnion,
        contentDescription: String,
        videoTimestamp: Double? = nil,
        expectedAccountDID: String? = nil,
        onComplete: ((Bool) -> Void)? = nil
    ) {
        self.subject = subject
        self.contentDescription = contentDescription
        self.expectedAccountDID = expectedAccountDID
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
        self._reportingService = State(initialValue: reportingService)
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
                        availableLabelers: eligibleLabelers,
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
            return "Intimate Imagery Report"
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
                            
                            Image(systemName: "chevron.forward")
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
                    Label("Back to Categories", systemImage: "chevron.backward")
                        .font(.subheadline)
                }
            }
            
            Section(category.title) {
                ForEach(category.reasons, id: \.reason.rawValue) { item in
                    Button {
                        selectedReason = item.reason
                        selectedReasonTitle = item.title
                        // Keep the chosen service only if it reviews this kind of report
                        if let labeler = selectedLabeler, !isEligible(labeler, for: item.reason) {
                            selectedLabeler = availableLabelers.first { isEligible($0, for: item.reason) }
                        }
                        
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
                Text("Are you shown in this image or video, or are you an authorized representative of the person shown?")
                    .font(.subheadline)
                    .padding(.vertical, 4)
                
                Button {
                    if let url = URL(string: "https://blueskyweb.zendesk.com/hc/en-us/requests/new?ticket_form_id=24729188849421") {
                        openURL(url)
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
                } else if isLoadingLabelers && availableLabelers.isEmpty {
                    HStack {
                        Text("Loading moderation services…")
                        Spacer()
                        ProgressView()
                    }
                } else if eligibleLabelers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Official Bluesky Moderation")
                            .fontWeight(.medium)
                        Text("Your other moderation services couldn’t be loaded, so this report will go to Bluesky.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    Button("Try Again") {
                        Task { await loadLabelers() }
                    }
                } else {
                    Button {
                        showingLabelerPicker = true
                    } label: {
                        HStack {
                            Text("Service")
                            Spacer()
                            let displayName = selectedLabeler?.creator.handle.description == "moderation.bsky.app"
                                ? String(localized: "Official Bluesky Moderation", comment: "Display name for Bluesky's official moderation service.")
                                : (selectedLabeler?.creator.displayName ?? selectedLabeler?.creator.handle.description ?? String(localized: "Select", comment: "Placeholder to select a moderation service."))
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
                            Text("Submitting…")
                            Spacer()
                        }
                    } else {
                        Text("Submit Report")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSubmitting || (!isBlueskyOnly && isLoadingLabelers))
                .buttonStyle(.borderedProminent)
            }
            
            Section {
                Button("Back to Reasons") {
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
        return Duration.seconds(totalSeconds).formatted(.time(pattern: .minuteSecond))
    }
    
    /// Services that accept this kind of report for this subject. The official Bluesky service
    /// accepts every report; for others, missing `reasonTypes`/`subjectTypes`/`subjectCollections`
    /// means no restriction.
    private var eligibleLabelers: [AppBskyLabelerDefs.LabelerViewDetailed] {
        availableLabelers.filter { isEligible($0, for: selectedReason) }
    }
    
    private func isEligible(
        _ labeler: AppBskyLabelerDefs.LabelerViewDetailed,
        for reason: ComAtprotoModerationDefs.ReasonType
    ) -> Bool {
        if labeler.creator.did.didString() == ReportingService.officialBlueskyDID {
            return true
        }
        if let reasonTypes = labeler.reasonTypes,
           !reasonTypes.contains(where: { $0.rawValue == reason.rawValue }) {
            return false
        }
        
        let subjectType: ComAtprotoModerationDefs.SubjectType
        var collection: String?
        switch subject {
        case .comAtprotoAdminDefsRepoRef:
            subjectType = .account
        case .comAtprotoRepoStrongRef(let strongRef):
            subjectType = .record
            collection = strongRef.uri.collection
        case .unexpected:
            return true
        }
        
        if let subjectTypes = labeler.subjectTypes,
           !subjectTypes.contains(where: { $0.rawValue == subjectType.rawValue }) {
            return false
        }
        if let collections = labeler.subjectCollections, let collection,
           !collections.contains(where: { $0.description == collection }) {
            return false
        }
        return true
    }
    
    private func loadLabelers() async {
        isLoadingLabelers = true
        defer { isLoadingLabelers = false }
        
        availableLabelers = (try? await reportingService.getSubscribedLabelers()) ?? []
        
        if selectedLabeler.map({ !isEligible($0, for: selectedReason) }) ?? true {
            selectedLabeler = eligibleLabelers.first
        }
    }
    
    private func submitReport() async {
        isSubmitting = true
        errorMessage = nil
        
        let timestampSeconds: Int? = (includeVideoTimestamp && videoTimestamp != nil) ? Int(floor(videoTimestamp!)) : nil
        // Bluesky-only reasons, or no reachable alternative service, go to Bluesky's moderators
        let targetLabelerDid: String
        if !isBlueskyOnly, let labeler = selectedLabeler, isEligible(labeler, for: selectedReason) {
            targetLabelerDid = labeler.creator.did.didString()
        } else {
            targetLabelerDid = ReportingService.officialBlueskyDID
        }
        
        do {
            let success = try await reportingService.submitReport(
                subject: subject,
                reasonType: selectedReason,
                reason: customReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : customReason.trimmingCharacters(in: .whitespacesAndNewlines),
                labelerDid: targetLabelerDid,
                videoTimestampSeconds: timestampSeconds,
                expectedAccountDID: expectedAccountDID
            )
            
            if success {
                showingSuccessAlert = true
                
                await MainActor.run {
                    appState.toastManager.show(
                        ToastItem(
                            message: String(localized: "Report submitted", comment: "Toast shown after submitting a moderation report."),
                            icon: "flag.fill",
                            duration: 2.5
                        )
                    )
                }
            } else {
                errorMessage = String(localized: "Couldn’t send your report. Try again.", comment: "Error when submitting a moderation report fails.")
            }
        } catch {
            errorMessage = UserFacingError.message(for: error, action: "send your report")
        }
        
        isSubmitting = false
    }
}
