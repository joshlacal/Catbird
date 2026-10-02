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
                    
                    Text("Select topics you're interested in to get better feed recommendations and discover relevant content across Bluesky.")
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
                        
                        Button("Retry") {
                            loadTask?.cancel()
                            loadTask = Task { @MainActor in
                                await loadInterests()
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else if interests.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No interests selected")
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
                            Text(interest)
                                .appFont(AppTextRole.subheadline)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Button("Edit Interests") {
                    isShowingPicker = true
                }
                .disabled(isLoading || !hasLoadedSuccessfully)
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
        .alert("Error Saving Interests", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
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
            self.loadError = "Failed to load interests: \(error.localizedDescription)"
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
                self.errorMessage = "Failed to update interests: \(error.localizedDescription)"
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
