import Foundation
import OSLog
import Petrel
import SwiftUI

/// Interactive multi-step onboarding flow (Avatar, Interests, Suggested Accounts, Finish)
public struct WelcomeOnboardingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep: Int = 0
    @State private var selectedInterests: Set<String> = []
    @State private var isSavingInterests: Bool = false
    @State private var interestsErrorMessage: String?
    
    // Starter Pack Finalization
    @State private var isFinalizingStarterPack: Bool = false
    @State private var starterPackResult: StarterPackFinalizationResult?
    @State private var starterPackContext: StarterPackPendingContext?
    private let logger = Logger(subsystem: "blue.catbird", category: "WelcomeOnboarding")
    
    private let availableInterests = [
        "Technology", "Science", "Art", "Music", "Sports", "Politics",
        "Photography", "Travel", "Food", "Books", "Movies", "Gaming",
        "Fashion", "Health", "Fitness", "Business", "Education",
        "Environment", "News", "Comedy", "Design", "Programming"
    ].sorted()
    
    public init() {}
    
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
                        try? await appState.removeAccount(did: did)
                        dismiss()
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
                            OnboardingSuggestedAccountsStep(
                                selectedInterests: Array(selectedInterests),
                                onContinue: { advanceStep() },
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
                }
                .task {
                    if let client = appState.atProtoClient {
                        _ = try? await appState.onboardingManager.checkSignupQueue(client: client)
                    }
                    restoreSavedState()
                    await loadExistingPreferences()
                }
            }
            .interactiveDismissDisabled(true)
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
                                interest: interest,
                                isSelected: selectedInterests.contains(interest),
                                onTap: {
                                    if selectedInterests.contains(interest) {
                                        selectedInterests.remove(interest)
                                    } else {
                                        selectedInterests.insert(interest)
                                    }
                                }
                            )
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
                        Text(isSavingInterests ? "Saving..." : (selectedInterests.isEmpty ? "Continue" : "Save & Continue (\(selectedInterests.count))"))
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .disabled(isSavingInterests)
                
                Button("Skip for now") {
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
                    Text("You're All Set!")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Welcome to Bluesky on Catbird. Your personalized feed is ready to explore.")
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
                    Text(context.name ?? "Starter Pack")
                        .font(.headline)
                    Text("Joining starter pack...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if isFinalizingStarterPack {
                    ProgressView()
                } else if starterPackResult != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            
            if let result = starterPackResult {
                HStack(spacing: 16) {
                    Label("\(result.followedCount) Followed", systemImage: "person.badge.plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if result.pinnedFeedsCount > 0 {
                        Label("\(result.pinnedFeedsCount) Feeds Pinned", systemImage: "pin.fill")
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
        let saved = appState.onboardingManager.savedStep(for: appState.userDID)
        if saved > 0 && saved <= 3 {
            self.currentStep = saved
            logger.debug("Restored onboarding step \(saved) for user: \(self.appState.userDID)")
        }
    }
    
    private func loadExistingPreferences() async {
        do {
            let prefs = try await appState.preferencesManager.getPreferences()
            if !prefs.interests.isEmpty {
                await MainActor.run {
                    self.selectedInterests = Set(prefs.interests)
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
                    interestsErrorMessage = "Failed to save interests: \(error.localizedDescription). Please try again."
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
        
        guard !isFinalizingStarterPack else { return }
        isFinalizingStarterPack = true
        do {
            let result = try await StarterPackOnboardingManager.shared.finalizeStarterPackOnboarding(
                client: client,
                appState: appState,
                context: pendingContext
            )
            await MainActor.run {
                self.starterPackResult = result
                self.isFinalizingStarterPack = false
            }
        } catch {
            await MainActor.run {
                self.isFinalizingStarterPack = false
                logger.error("Failed starter pack finalization: \(error)")
            }
        }
    }
    
    private func finishOnboarding() {
        logger.info("Completing onboarding flow for: \(self.appState.userDID)")
        appState.onboardingManager.completeWelcomeOnboarding(for: appState.userDID)
        dismiss()
    }
}
