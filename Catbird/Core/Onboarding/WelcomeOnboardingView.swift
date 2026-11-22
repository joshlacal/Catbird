import Foundation
import OSLog
import Petrel
import SwiftUI

/// Interactive multi-step onboarding flow (Avatar, Interests, Suggested Accounts, Finish)
public struct WelcomeOnboardingView: View {
  @Environment(SceneNavigationContext.self) private var sceneContext
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep: Int = 0
    @State private var isShowingFeedDiscovery = false
    @State private var selectedInterests: Set<String> = []
    @State private var isSavingInterests: Bool = false
    @State private var interestsErrorMessage: String?
    
    // Starter Pack Finalization
    @State private var isFinalizingStarterPack: Bool = false
    @State private var starterPackResult: StarterPackFinalizationResult?
    @State private var starterPackContext: StarterPackPendingContext?
    @State private var starterPackError: String?
    private let isReplay: Bool
    private let initialStep: Int?
    private let logger = Logger(subsystem: "blue.catbird", category: "WelcomeOnboarding")
    
    /// Bluesky interest ids, ordered by their display names.
    private let availableInterests = BlueskyInterests.ids.sorted {
        BlueskyInterests.displayName(for: $0) < BlueskyInterests.displayName(for: $1)
    }
    
    public init(isReplay: Bool = false, initialStep: Int? = nil) {
        self.isReplay = isReplay
        self.initialStep = initialStep
        if let initialStep {
            _currentStep = State(initialValue: min(max(initialStep, 0), 3))
        }
    }
    
    public var body: some View {
        if appState.onboardingManager.isSignupQueued {
            SignupQueuedView(
                initialPlaceInQueue: appState.onboardingManager.signupQueueState?.placeInQueue,
                initialEstimatedTimeMs: appState.onboardingManager.signupQueueState?.estimatedTimeMs,
                onActivated: {
                    appState.onboardingManager.isSignupQueued = false
                    restoreSavedState()
                },
                onSignOut: {
                    Task { @MainActor in
                        let did = appState.userDID
                        appState.onboardingManager.isSignupQueued = false
                        appState.onboardingManager.signupQueueState = nil
                        appState.onboardingManager.showWelcomeSheet = false
                        dismiss()
                        // Removing the signed-in account signs it out first and returns to sign-in.
                        try? await AppStateManager.shared.authentication.removeAccount(did: did)
                    }
                }
            )
        } else {
            NavigationStack {
                VStack(spacing: 0) {
                    // Top Progress Bar
                    progressHeader
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                    
                    // Active Step Content
                    ZStack {
                        switch currentStep {
                        case 0:
                            OnboardingAvatarStep(
                                onContinue: { advanceStep() },
                                onSkip: { advanceStep() }
                            )
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        case 1:
                            interestsStepView
                                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        case 2:
                            SceneIntelligenceOnboardingView(
                                mode: isReplay ? .tuneExistingFeed : .newAccountOnboarding,
                                selectedInterests: Array(selectedInterests),
                                onComplete: { advanceStep() },
                                onSkip: { advanceStep() }
                            )
                            .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        default:
                            finishStepView
                                .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: currentStep)
                }
                #if os(iOS)
                .toolbarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if currentStep > 0 && currentStep < 3 {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Back", systemImage: "chevron.backward") {
                                previousStep()
                            }
                        }
                    }
                    if isReplay {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close", systemImage: "xmark") {
                                finishOnboarding()
                            }
                            .accessibilityIdentifier("onboarding.replay.close")
                        }
                    }
                }
                .task {
                    if let client = appState.atProtoClient {
                        _ = try? await appState.onboardingManager.checkSignupQueue(client: client)
                    }
                    restoreSavedState()
                    await loadExistingPreferences()
                }
            }
            .interactiveDismissDisabled(!isReplay)
        }
    }
    
    // MARK: - Progress Header
    
    private var progressHeader: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { stepIndex in
                Capsule()
                    .fill(stepIndex <= currentStep ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.25), value: currentStep)
            }
        }
    }
    
    // MARK: - Interests Step View
    
    private var interestsStepView: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Text("Choose Your Interests")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Select topics you care about to discover tailored feeds and creators.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding(.top, 16)
                    
                    // Interest Tags Flow
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(availableInterests, id: \.self) { interest in
                            InterestTag(
                                interest: BlueskyInterests.displayName(for: interest),
                                isSelected: selectedInterests.contains(interest),
                                onTap: {
                                    if selectedInterests.contains(interest) {
                                        selectedInterests.remove(interest)
                                    } else {
                                        selectedInterests.insert(interest)
                                    }
                                }
                            )
                            .accessibilityAddTraits(selectedInterests.contains(interest) ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    
                    if let error = interestsErrorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                    }
                }
            }
            
            // Bottom Action Area
            VStack(spacing: 12) {
                Button(action: saveInterestsAndAdvance) {
                    HStack {
                        if isSavingInterests {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 4)
                        }
                        Group {
                            if isSavingInterests {
                                Text("Saving…", comment: "Progress button label while saving selected interests.")
                            } else if selectedInterests.isEmpty {
                                Text("Continue", comment: "Button to advance past interests step without selections.")
                            } else {
                                Text("Save & Continue (\(selectedInterests.count))", comment: "Button to save selected interests and advance — variable is selected count.")
                            }
                        }
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSavingInterests)
                
                Button("Skip for Now") {
                    advanceStep()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .disabled(isSavingInterests)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 24)
            .background(.ultraThinMaterial)
        }
    }
    
    // MARK: - Finish Step View
    
    private var finishStepView: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 24)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce.wholeSymbol, options: .repeat(1))
                
                VStack(spacing: 12) {
                    Text("You’re All Set")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Welcome to Bluesky on Catbird. Choose community feeds or start exploring now.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                
                // Starter Pack Finalization Card (if joining via starter pack)
                if let context = starterPackContext ?? StarterPackOnboardingManager.shared.pendingContext {
                    starterPackSummaryCard(context)
                }
                
                Spacer(minLength: 32)
                
                VStack(spacing: 12) {
                    Button {
                        isShowingFeedDiscovery = true
                    } label: {
                        Label("Choose Feeds", systemImage: "plus.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Optional. Discover and save community feeds")

                    Button(action: finishOnboarding) {
                        Text("Start Exploring")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $isShowingFeedDiscovery) {
            AddFeedSheet(onOpen: { feed in
                finishOnboarding()
                sceneContext.navigationManager.navigate(to: .feed(feed.uri))
            })
        }
        .task {
            await finalizeStarterPackIfNeeded()
        }
    }
    
    private func starterPackSummaryCard(_ context: StarterPackPendingContext) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .foregroundStyle(.accent)
                
                VStack(alignment: .leading, spacing: 2) {
                    if let name = context.name {
                        Text(name)
                            .font(.headline)
                    } else {
                        Text("Starter Pack", comment: "Fallback title for a Bluesky Starter Pack.")
                            .font(.headline)
                    }
                    Text(starterPackStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isFinalizing {
                    ProgressView()
                } else if effectiveResult != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                } else if effectiveError != nil {
                    Button {
                        Task { await finalizeStarterPackIfNeeded() }
                    } label: {
                        Text("Try Again", comment: "Retry button when starter pack finalization fails.")
                    }
                    .font(.caption.bold())
                }
            }
            
            if let error = effectiveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            if let result = effectiveResult {
                HStack(spacing: 16) {
                    Label {
                        Text("\(result.followedCount) Followed", comment: "Count of accounts followed from a starter pack.")
                    } icon: {
                        Image(systemName: "person.badge.plus")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if result.pinnedFeedsCount > 0 {
                        Label {
                            Text("\(result.pinnedFeedsCount) Feeds Pinned", comment: "Count of feeds pinned from a starter pack.")
                        } icon: {
                            Image(systemName: "pin.fill")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 24)
    }
    
    private var isFinalizing: Bool {
        isFinalizingStarterPack || StarterPackOnboardingManager.shared.isFinalizing
    }
    
    private var effectiveResult: StarterPackFinalizationResult? {
        starterPackResult ?? StarterPackOnboardingManager.shared.storedResult
    }
    
    private var effectiveError: String? {
        starterPackError ?? StarterPackOnboardingManager.shared.storedError
    }

    private var starterPackStatusText: String {
        if let result = effectiveResult {
            return String(
                localized: "Joined • Followed \(result.followedCount), pinned \(result.pinnedFeedsCount) feeds",
                comment: "Starter pack completion status — %1$lld is accounts followed, %2$lld is feeds pinned."
            )
        }
        if isFinalizing {
            return String(localized: "Joining starter pack…", comment: "Status message while joining a starter pack in onboarding.")
        }
        if effectiveError != nil {
            return String(localized: "Couldn’t join", comment: "Status message when joining a starter pack fails.")
        }
        return String(localized: "Joining starter pack…", comment: "Status message while joining a starter pack in onboarding.")
    }
    
    // MARK: - Navigation & State Helpers
    
    private func advanceStep() {
        if currentStep < 3 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep += 1
            }
            appState.onboardingManager.saveStep(currentStep, for: appState.userDID)
        } else {
            finishOnboarding()
        }
    }
    
    private func previousStep() {
        if currentStep > 0 {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentStep -= 1
            }
            appState.onboardingManager.saveStep(currentStep, for: appState.userDID)
        }
    }
    
    private func restoreSavedState() {
        if let requested = initialStep ?? appState.onboardingManager.requestedWelcomeStartStep {
            let clamped = min(max(requested, 0), 3)
            self.currentStep = clamped
            appState.onboardingManager.requestedWelcomeStartStep = nil
            return
        }
        let saved = appState.onboardingManager.savedStep(for: appState.userDID)
        if saved > 0 && saved <= 3 {
            self.currentStep = saved
            logger.debug("Restored onboarding step \(saved) for user: \(self.appState.userDID)")
        }
    }
    
    private func loadExistingPreferences() async {
        do {
            let prefs = try await appState.preferencesManager.getPreferences()
            // Only interests with a Bluesky id can be shown as chips; others would be selected invisibly.
            let knownInterests = Set(prefs.interests.compactMap(BlueskyInterests.normalizedID))
            if !knownInterests.isEmpty {
                await MainActor.run {
                    self.selectedInterests = knownInterests
                }
            }
        } catch {
            logger.debug("Could not load existing preferences: \(error.localizedDescription)")
        }
    }
    
    private func saveInterestsAndAdvance() {
        guard !selectedInterests.isEmpty else {
            advanceStep()
            return
        }
        
        isSavingInterests = true
        interestsErrorMessage = nil
        Task {
            do {
                try await appState.preferencesManager.updateInterests(Array(selectedInterests))
                await MainActor.run {
                    isSavingInterests = false
                    advanceStep()
                }
            } catch {
                await MainActor.run {
                    isSavingInterests = false
                    interestsErrorMessage = UserFacingError.message(
                        for: error,
                        action: String(localized: "save your interests", comment: "Action phrase in error message when saving onboarding interests fails.")
                    )
                    logger.error("Failed to save interests: \(error)")
                }
            }
        }
    }
    
    private func finalizeStarterPackIfNeeded() async {
        guard let pendingContext = starterPackContext ?? StarterPackOnboardingManager.shared.pendingContext,
              let client = appState.atProtoClient else { return }
        
        if starterPackContext == nil {
            starterPackContext = pendingContext
        }
        
        guard !isFinalizing else { return }
        isFinalizingStarterPack = true
        starterPackError = nil
        do {
            let result = try await StarterPackOnboardingManager.shared.finalizeStarterPackOnboarding(
                client: client,
                appState: appState,
                context: pendingContext
            )
            self.starterPackResult = result
            self.isFinalizingStarterPack = false
        } catch {
            self.isFinalizingStarterPack = false
            self.starterPackError = UserFacingError.message(
                for: error,
                action: String(localized: "follow everyone in this starter pack", comment: "Action phrase in error message when starter pack finalization fails.")
            ) ?? String(localized: "Couldn’t follow everyone in this starter pack. Try again.", comment: "Fallback error message when starter pack finalization fails.")
            logger.error("Failed starter pack finalization: \(error)")
        }
    }
    
    private func finishOnboarding() {
        logger.info("Completing onboarding flow for: \(self.appState.userDID)")
        appState.onboardingManager.completeWelcomeOnboarding(for: appState.userDID)
        dismiss()
    }
}
