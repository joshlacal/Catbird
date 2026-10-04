import SwiftUI
import Petrel

/// View for managing per-labeler content preferences
struct LabelerSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var labelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
    let initialFocus: SettingsControlID?
    @State private var loadRequest = UUID()
    @State private var hasConfirmedPreferences = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    // Per-labeler preferences (labelerDID -> label -> visibility)
    @State private var labelerPreferences: [String: [String: ContentVisibility]] = [:]
    @State private var isSaving = false
    
    init(initialFocus: SettingsControlID? = nil) {
        self.initialFocus = initialFocus
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading labelers...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Error Loading Labelers")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        Task {
                            await loadLabelers()
                        }
                    }
                }
                .padding()
            } else if labelers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checklist.unchecked")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No Labelers Subscribed")
                        .font(.headline)
                    Text("You're not subscribed to any custom moderation services")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                labelersList
            }
        }
        .navigationTitle("Labeler Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await loadLabelers()
        }
    }
    
    private var labelersList: some View {
        SettingsFocusedForm(initialFocus: initialFocus, isReady: hasConfirmedPreferences && !isLoading) {
            ForEach(labelers, id: \.uri) { labeler in
                Section {
                    labelerHeader(labeler)
                    labelerContentControls(labeler)
                } header: {
                    Text(labelerDisplayName(labeler))
                        .textCase(nil)
                        .font(.headline)
                }
            }
            
            if isSaving {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Saving preferences...")
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func labelerHeader(_ labeler: AppBskyLabelerDefs.LabelerViewDetailed) -> some View {
        HStack(spacing: 12) {
            if let avatarURL = labeler.creator.finalAvatarURL() {
                AsyncImage(url: avatarURL) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.gray)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(labeler.creator.handle.description)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                if let description = labeler.creator.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private func labelerContentControls(_ labeler: AppBskyLabelerDefs.LabelerViewDetailed) -> some View {
        let labelerDid = labeler.creator.did.didString()
        
        VStack(spacing: 16) {
            ContentVisibilitySelector(
                title: "Adult Content",
                description: "Explicit sexual images, videos, or text",
                selection: Binding(
                    get: { getPreference(labelerDid: labelerDid, label: "nsfw") },
                    set: { setPreference(labelerDid: labelerDid, label: "nsfw", visibility: $0) }
                )
            )
            
            ContentVisibilitySelector(
                title: "Sexually Suggestive",
                description: "Sexualized content without explicit activity",
                selection: Binding(
                    get: { getPreference(labelerDid: labelerDid, label: "suggestive") },
                    set: { setPreference(labelerDid: labelerDid, label: "suggestive", visibility: $0) }
                )
            )
            
            ContentVisibilitySelector(
                title: "Graphic Content",
                description: "Violence, blood, or injury",
                selection: Binding(
                    get: { getPreference(labelerDid: labelerDid, label: "graphic") },
                    set: { setPreference(labelerDid: labelerDid, label: "graphic", visibility: $0) }
                )
            )
            
            ContentVisibilitySelector(
                title: "Non-Sexual Nudity",
                description: "Artistic or educational nudity",
                selection: Binding(
                    get: { getPreference(labelerDid: labelerDid, label: "nudity") },
                    set: { setPreference(labelerDid: labelerDid, label: "nudity", visibility: $0) }
                )
            )
        }
    }
    
    private func labelerDisplayName(_ labeler: AppBskyLabelerDefs.LabelerViewDetailed) -> String {
        if labeler.creator.handle.description == "moderation.bsky.app" {
            return "Official Bluesky Moderation"
        }
        return labeler.creator.displayName ?? labeler.creator.handle.description
    }
    
    private func getPreference(labelerDid: String, label: String) -> ContentVisibility {
        labelerPreferences[labelerDid]?[label] ?? .warn
    }
    
    private func setPreference(labelerDid: String, label: String, visibility: ContentVisibility) {
        guard hasConfirmedPreferences, !isLoading, !isSaving,
              getPreference(labelerDid: labelerDid, label: label) != visibility else { return }
        let account = appState.userDID
        let manager = appState.preferencesManager
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let did = try DID(didString: labelerDid)
                try await manager.setContentLabelVisibility(label: label, visibility: visibility.preferenceValue,
                                                             labelerDid: did, expectedAccountDID: account)
                guard manager.accountDID == account, appState.userDID == account else { return }
                if labelerPreferences[labelerDid] == nil { labelerPreferences[labelerDid] = [:] }
                labelerPreferences[labelerDid]?[label] = visibility
            } catch {
                guard manager.accountDID == account else { return }
                errorMessage = "Failed to save preference: \(error.localizedDescription)"
            }
        }
    }

    private func loadLabelers() async {
        let request = UUID()
        let account = appState.userDID
        let manager = appState.preferencesManager
        loadRequest = request
        isLoading = true
        hasConfirmedPreferences = false
        errorMessage = nil
        defer { if loadRequest == request { isLoading = false } }
        do {
            guard let client = appState.atProtoClient else {
                errorMessage = "Not authenticated"
                isLoading = false
                return
            }
            
            let reportingService = ReportingService(client: client)
            let loadedLabelers = try await reportingService.getSubscribedLabelers()
            let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
            guard loadRequest == request, manager.accountDID == account, appState.atProtoClient === client else { return }
            labelers = loadedLabelers
            labelerPreferences = [:]
            
            // Load existing preferences for all labelers
            
            for labeler in labelers {
                let labelerDid = labeler.creator.did.didString()
                var labelerPrefs: [String: ContentVisibility] = [:]
                
                // Check for existing preferences for this labeler
                for labelKey in ["nsfw", "suggestive", "graphic", "nudity"] {
                    let visibility = ContentFilterManager.getVisibilityForLabel(
                        label: labelKey,
                        labelerDid: labeler.creator.did,
                        preferences: preferences.contentLabelPrefs
                    )
                    labelerPrefs[labelKey] = visibility
                }
                
                labelerPreferences[labelerDid] = labelerPrefs
            }
            
            hasConfirmedPreferences = true
        } catch {
            guard loadRequest == request, manager.accountDID == account else { return }
            errorMessage = error.localizedDescription
        }
    }
    

}

#Preview("LabelerSettingsView") {
  NavigationStack {
    LabelerSettingsView()
  }
  .previewWithAuthenticatedState()
}
