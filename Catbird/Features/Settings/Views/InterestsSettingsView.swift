import SwiftUI
import Petrel
import OSLog

struct InterestsSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var interests: [String] = []
    @State private var isLoading = true
    @State private var hasLoadedSuccessfully = false
    @State private var loadError: String?
    @State private var isShowingPicker = false
    @State private var activeSceneEntryPoint: SceneOnboardingViewModel.EntryPoint?
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var saveTask: Task<Void, Never>?
    @State private var loadTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "blue.catbird", category: "InterestsSettings")
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Selected Topics")
                        .fontWeight(.bold)
                        .appFont(AppTextRole.headline)
                    
                    Text("Choose topics you’re interested in to get better feed recommendations and discover more across Bluesky.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            
            Section("Current Interests") {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } else if let loadError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .appFont(AppTextRole.subheadline)
                        
                        Button("Try Again") {
                            loadTask?.cancel()
                            loadTask = Task { @MainActor in
                                await loadInterests()
                            }
                        }
                        .buttonStyle(.catbird(.tonal, size: .sm))
                    }
                    .padding(.vertical, 4)
                } else if interests.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No Interests Selected")
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        
                        Text("Choose topics you enjoy to help personalize your discovery feed.")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                        ForEach(interests, id: \.self) { interest in
                            CatbirdBadge(Text(verbatim: BlueskyInterest.displayName(for: interest)), tone: .accent)
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Button("Edit Interests") {
                    isShowingPicker = true
                }
                .disabled(isLoading || !hasLoadedSuccessfully)
            }

            Section("Community Intelligence") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Explore Scenes & Tune Your Feed", systemImage: "sparkles")
                        .fontWeight(.semibold)
                        .appFont(AppTextRole.headline)

                    Text("Browse 1,000+ live Bluesky communities, preview real posts, and assemble a role-balanced lineup with Originals-Only repost taming.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Button {
                    activeSceneEntryPoint = .explorer
                } label: {
                    Label("Open Scene Explorer", systemImage: "safari.fill")
                }
                .accessibilityIdentifier("settings.interests.openSceneExplorer")

                Button {
                    activeSceneEntryPoint = .quickCalibrate
                } label: {
                    Label("Quick Taste Calibration & Pace", systemImage: "slider.horizontal.below.sun.max")
                }
                .accessibilityIdentifier("settings.interests.quickCalibrate")

                NavigationLink {
                    OriginalsOnlyAccountsView()
                } label: {
                    let count = appState.feedFilterSettings.mutedRepostAuthorDIDs.count
                    LabeledContent {
                        Text("\(count)")
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Originals-Only Accounts", systemImage: "arrow.2.squarepath")
                    }
                }
            }
        }
        .navigationTitle("Your Interests")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadInterests()
        }
        .sheet(isPresented: $isShowingPicker) {
            InterestPickerSheet(
                currentInterests: interests,
                onSave: { updatedInterests in
                    await saveInterests(updatedInterests)
                }
            )
        }
        .sheet(item: $activeSceneEntryPoint) { entryPoint in
            NavigationStack {
                SceneIntelligenceOnboardingView(
                    mode: .tuneExistingFeed,
                    entryPoint: entryPoint,
                    selectedInterests: interests,
                    onComplete: {
                        activeSceneEntryPoint = nil
                    },
                    onSkip: {
                        activeSceneEntryPoint = nil
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            activeSceneEntryPoint = nil
                        }
                    }
                }
            }
        }
        .alert("Couldn’t Save Interests", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Try again.")
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            saveTask?.cancel()
            saveTask = nil
        }
    }
    
    @MainActor
    private func loadInterests() async {
        isLoading = true
        loadError = nil
        hasLoadedSuccessfully = false
        defer {
            if !Task.isCancelled {
                isLoading = false
            }
        }
        
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            guard !Task.isCancelled else { return }
            self.interests = preferences.interests
            self.hasLoadedSuccessfully = true
        } catch {
            guard !Task.isCancelled else { return }
            logger.error("Failed to load user interests: \(error.localizedDescription)")
            self.loadError = UserFacingError.message(for: error, action: "load your interests") ?? "Couldn’t load your interests. Try again."
        }
    }
    
    @MainActor
    private func saveInterests(_ updated: [String]) async {
        saveTask?.cancel()
        let task = Task { @MainActor in
            do {
                try await appState.preferencesManager.updateInterests(updated)
                self.interests = updated
            } catch {
                logger.error("Failed to save user interests: \(error.localizedDescription)")
                guard let message = UserFacingError.message(for: error, action: "save your interests") else { return }
                self.errorMessage = message
                self.showingError = true
            }
        }
        saveTask = task
        await task.value
    }
}

#Preview {
    NavigationStack {
        InterestsSettingsView()
    }
    .previewWithAuthenticatedState()
}
