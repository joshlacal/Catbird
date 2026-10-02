import SwiftUI
import Petrel

/// View for configuring account-wide default threadgate and postgate settings (Post Interaction Settings)
struct DefaultPostInteractionSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    enum ReplyMode: String, CaseIterable, Identifiable {
        case everybody = "everybody"
        case nobody = "nobody"
        case custom = "custom"
        
        var id: String { rawValue }
        
        var title: String {
            switch self {
            case .everybody: return "Everybody"
            case .nobody: return "Nobody"
            case .custom: return "Specific Users"
            }
        }
        
        var subtitle: String {
            switch self {
            case .everybody: return "Anyone can reply to your posts"
            case .nobody: return "No one can reply to your posts"
            case .custom: return "Only selected groups or lists can reply"
            }
        }
    }
    
    @State private var replyMode: ReplyMode = .everybody
    @State private var allowMentioned: Bool = true
    @State private var allowFollowing: Bool = true
    @State private var allowFollowers: Bool = false
    @State private var allowLists: Bool = false
    @State private var selectedListURIs: [String] = []
    @State private var userLists: [AppBskyGraphDefs.ListView] = []
    @State private var isLoadingLists: Bool = false
    @State private var allowQuotes: Bool = true
    
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var showingErrorAlert: Bool = false
    
    private var preferencesManager: PreferencesManager {
        appState.preferencesManager
    }
    
    var body: some View {
        Form {
            if isLoading {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                replySettingsSection
                
                if replyMode == .custom {
                    customRulesSection
                }
                
                quoteSettingsSection
                
                if isSaving {
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Saving settings...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Post Interaction Settings")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .alert("Error Saving Settings", isPresented: $showingErrorAlert) {
            Button("OK") { showingErrorAlert = false }
        } message: {
            if let error = errorMessage {
                Text(error)
            }
        }
        .task {
            await loadSettings()
        }
    }
    
    // MARK: - Sections
    
    private var replySettingsSection: some View {
        Section("Default Who Can Reply") {
            ForEach(ReplyMode.allCases) { mode in
                Button {
                    replyMode = mode
                    Task { await saveSettings() }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(mode.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if replyMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .fontWeight(.semibold)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    private var customRulesSection: some View {
        Group {
            Section("Allow Replies From") {
                Toggle("Users you follow", isOn: $allowFollowing)
                    .onChange(of: allowFollowing) { _, _ in Task { await saveSettings() } }
                
                Toggle("Your followers", isOn: $allowFollowers)
                    .onChange(of: allowFollowers) { _, _ in Task { await saveSettings() } }
                
                Toggle("Mentioned users", isOn: $allowMentioned)
                    .onChange(of: allowMentioned) { _, _ in Task { await saveSettings() } }
            }
            
            Section("User Lists") {
                if isLoadingLists {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if userLists.isEmpty {
                    Text("No lists found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(userLists, id: \.uri) { list in
                        let uriString = list.uri.uriString()
                        let isSelected = selectedListURIs.contains(uriString)
                        Button {
                            if isSelected {
                                selectedListURIs.removeAll { $0 == uriString }
                                allowLists = !selectedListURIs.isEmpty
                            } else {
                                selectedListURIs.append(uriString)
                                allowLists = true
                            }
                            Task { await saveSettings() }
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                    .frame(width: 24)
                                    .foregroundStyle(.primary)
                                
                                Text(list.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    private var quoteSettingsSection: some View {
        Section(header: Text("Quote Posts"), footer: Text("When disabled, other users cannot quote-post your posts by default. You can still override this per post.")) {
            Toggle("Allow quote posts", isOn: $allowQuotes)
                .tint(.blue)
                .onChange(of: allowQuotes) { _, _ in Task { await saveSettings() } }
        }
    }
    
    // MARK: - Conversions & Actions
    
    private func loadSettings() async {
        isLoading = true
        do {
            let pref = try await preferencesManager.getPostInteractionSettingsPref()
            decodePref(pref)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        await loadUserLists()
    }
    
    private func loadUserLists() async {
        guard let client = appState.atProtoClient else { return }
        isLoadingLists = true
        defer { isLoadingLists = false }
        
        do {
            var did = appState.userDID
            if did.isEmpty {
                did = (try? await client.getDid()) ?? ""
            }
            guard !did.isEmpty else { return }
            let params = AppBskyGraphGetLists.Parameters(
                actor: try ATIdentifier(string: did),
                limit: 50,
                cursor: nil
            )
            let (code, output) = try await client.app.bsky.graph.getLists(input: params)
            if code == 200, let output = output {
                userLists = output.lists
            }
        } catch {
            // Degrade gracefully
        }
    }
    
    private func decodePref(_ pref: AppBskyActorDefs.PostInteractionSettingsPref?) {
        guard let pref = pref else {
            // Default: everybody, allow quotes
            replyMode = .everybody
            allowQuotes = true
            return
        }
        
        // 1. Threadgate rules
        if let rules = pref.threadgateAllowRules {
            if rules.isEmpty {
                replyMode = .nobody
            } else {
                replyMode = .custom
                allowMentioned = false
                allowFollowing = false
                allowFollowers = false
                allowLists = false
                selectedListURIs = []
                
                for rule in rules {
                    switch rule {
                    case .appBskyFeedThreadgateMentionRule:
                        allowMentioned = true
                    case .appBskyFeedThreadgateFollowingRule:
                        allowFollowing = true
                    case .appBskyFeedThreadgateFollowerRule:
                        allowFollowers = true
                    case .appBskyFeedThreadgateListRule(let listRule):
                        allowLists = true
                        selectedListURIs.append(listRule.list.uriString())
                    case .unexpected:
                        break
                    }
                }
            }
        } else {
            replyMode = .everybody
        }
        
        // 2. Postgate rules
        if let postgateRules = pref.postgateEmbeddingRules,
           postgateRules.contains(where: {
               if case .appBskyFeedPostgateDisableRule = $0 { return true }
               return false
           }) {
            allowQuotes = false
        } else {
            allowQuotes = true
        }
    }
    
    private func encodePref() -> AppBskyActorDefs.PostInteractionSettingsPref {
        var allowRules: [AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion]? = nil
        
        switch replyMode {
        case .everybody:
            allowRules = nil
        case .nobody:
            allowRules = []
        case .custom:
            var rules: [AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion] = []
            if allowMentioned {
                rules.append(.appBskyFeedThreadgateMentionRule(AppBskyFeedThreadgate.MentionRule()))
            }
            if allowFollowing {
                rules.append(.appBskyFeedThreadgateFollowingRule(AppBskyFeedThreadgate.FollowingRule()))
            }
            if allowFollowers {
                rules.append(.appBskyFeedThreadgateFollowerRule(AppBskyFeedThreadgate.FollowerRule()))
            }
            for listURI in selectedListURIs {
                if let uri = try? ATProtocolURI(uriString: listURI) {
                    rules.append(.appBskyFeedThreadgateListRule(AppBskyFeedThreadgate.ListRule(list: uri)))
                }
            }
            allowRules = rules
        }
        
        var embeddingRules: [AppBskyActorDefs.PostInteractionSettingsPrefPostgateEmbeddingRulesUnion]? = nil
        if !allowQuotes {
            embeddingRules = [.appBskyFeedPostgateDisableRule(AppBskyFeedPostgate.DisableRule())]
        }
        
        return AppBskyActorDefs.PostInteractionSettingsPref(
            threadgateAllowRules: allowRules,
            postgateEmbeddingRules: embeddingRules
        )
    }
    
    private func saveSettings() async {
        isSaving = true
        errorMessage = nil
        
        let pref = encodePref()
        
        do {
            try await preferencesManager.setPostInteractionSettingsPref(pref)
        } catch {
            errorMessage = error.localizedDescription
            showingErrorAlert = true
            // Reload previous saved state
            await loadSettings()
        }
        
        isSaving = false
    }
}
