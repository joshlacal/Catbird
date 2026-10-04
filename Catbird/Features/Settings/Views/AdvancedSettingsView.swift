import SwiftUI
import Petrel

struct AdvancedSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsDraftGuard) private var draftGuard
  
  // Predefined AppView options
  enum AppViewOption: String, CaseIterable, Identifiable {
    case blueskyPBC = "Bluesky PBC"
    case blacksky = "Blacksky"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var did: String? {
      switch self {
      case .blueskyPBC:
        return "did:web:api.bsky.app#bsky_appview"
      case .blacksky:
        return "did:web:api.blacksky.community#bsky_appview"
      case .custom:
        return nil
      }
    }
  }
  
  // Predefined Chat options
  enum ChatOption: String, CaseIterable, Identifiable {
    case blueskyPBC = "Bluesky PBC"
    case custom = "Custom"
    
    var id: String { rawValue }
    
    var did: String? {
      switch self {
      case .blueskyPBC:
        return "did:web:api.bsky.chat#bsky_chat"
      case .custom:
        return nil
      }
    }
  }
  
  @State private var selectedAppViewOption: AppViewOption = .blueskyPBC
  @State private var selectedChatOption: ChatOption = .blueskyPBC
  @State private var customAppViewDID: String = ""
  @State private var customChatDID: String = ""
  @State private var isSaving = false
  @State private var showingSaveConfirmation = false
  @State private var error: Error?
  let initialFocus: SettingsControlID?
  @State private var originDID: String?
  @State private var isLoadingProviders = true
  @State private var baseline: ProviderDraft?
  @State private var confirmingDeparture = false
  private struct ProviderDraft: Equatable {
    let appView: AppViewOption
    let chat: ChatOption
    let customAppView: String
    let customChat: String
  }
  private var currentDraft: ProviderDraft { ProviderDraft(appView: selectedAppViewOption, chat: selectedChatOption, customAppView: customAppViewDID, customChat: customChatDID) }
  private var hasUnsavedChanges: Bool { baseline.map { $0 != currentDraft } ?? false }
  init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
  
  var body: some View {
    ResponsiveContentView {
      SettingsFocusedForm(initialFocus: initialFocus, isReady: baseline != nil) {
        SettingsScopeSection()
        if isLoadingProviders { Section { ProgressView("Loading service providers…") } }
        else if baseline == nil {
          Section {
            Text("Couldn’t load service providers. Your current providers are unchanged.").foregroundStyle(.secondary)
            Button("Retry") { Task { await loadCurrentSettings(); publishDraftGuard() } }
          }
        }
        headerSection
        appViewSection.settingsControl(.init(rawValue: "advanced.appView")).disabled(baseline == nil || isSaving)
        chatSection.settingsControl(.init(rawValue: "advanced.chatProvider")).disabled(baseline == nil || isSaving)
        resetSection.disabled(baseline == nil || isSaving)
        saveSection
        warningSection
      }
    }
    .navigationTitle("Service Providers")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    .task(id: appState.userDID) {
      originDID = appState.userDID
      baseline = nil
      await loadCurrentSettings()
      publishDraftGuard()
    }
    .onChange(of: currentDraft) { _, _ in publishDraftGuard() }
    .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
    .navigationBarBackButtonHidden(hasUnsavedChanges || isSaving)
    .toolbar {
      if hasUnsavedChanges {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back", systemImage: "chevron.left") { confirmingDeparture = true }.disabled(isSaving)
        }
      }
    }
    .confirmationDialog("Unsaved provider changes", isPresented: $confirmingDeparture, titleVisibility: .visible) {
      Button("Save") { Task { if await resolveDraft(save: true) { dismiss() } } }
      Button("Discard Changes", role: .destructive) { Task { if await resolveDraft(save: false) { dismiss() } } }
      Button("Stay", role: .cancel) { }
    }
    .onDisappear { if draftGuard?.accountDID == originDID { draftGuard?.hasChanges = false; draftGuard?.resolve = nil } }
    .alert("Saved", isPresented: $showingSaveConfirmation) {
      Button("OK") {
        showingSaveConfirmation = false
      }
    } message: {
      Text("Service DID settings have been updated.")
    }
    .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") {
        error = nil
      }
    } message: {
      if let error {
        Text(error.localizedDescription)
      }
    }
  }
  
  @MainActor private func publishDraftGuard() {
    draftGuard?.accountDID = originDID
    draftGuard?.hasChanges = hasUnsavedChanges
    draftGuard?.resolve = { save in await resolveDraft(save: save) }
  }
  @MainActor private func resolveDraft(save: Bool) async -> Bool {
    guard originDID == appState.userDID && originDID.map(SettingsAccountBoundary.isCurrent) == true else { return false }
    if save { await saveChanges(); return !hasUnsavedChanges }
    guard let baseline else { return false }
    selectedAppViewOption = baseline.appView
    selectedChatOption = baseline.chat
    customAppViewDID = baseline.customAppView
    customChatDID = baseline.customChat
    publishDraftGuard()
    return true
  }

  private var headerSection: some View {
    Section {
      Text("Configure custom service endpoints for your account. These settings are per-account and persist across app restarts.")
        .foregroundStyle(.secondary)
        .appFont(AppTextRole.caption)
    }
  }
  
  private var appViewSection: some View {
    Section("AppView Service") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Select AppView Provider")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
        
        appViewPicker
        
        if selectedAppViewOption == .custom {
          customAppViewField
        }
        
        Text(appViewDescription)
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
  }
  
  private var appViewPicker: some View {
    Picker("AppView", selection: $selectedAppViewOption) {
      ForEach(AppViewOption.allCases) { option in
        Text(option.rawValue).tag(option)
      }
    }
    .pickerStyle(.segmented)
  }
  
  private var customAppViewField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Custom AppView DID")
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      
      TextField("did:web:example.com#bsky_appview", text: $customAppViewDID)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        #endif
    }
    .padding(.top, 8)
  }
  
  private var chatSection: some View {
    Section("Chat Service") {
      VStack(alignment: .leading, spacing: 12) {
        Text("Select Chat Provider")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
        
        chatPicker
        
        if selectedChatOption == .custom {
          customChatField
        }
        
        Text("The Chat service handles direct messages.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
  }
  
  private var chatPicker: some View {
    Picker("Chat", selection: $selectedChatOption) {
      ForEach(ChatOption.allCases) { option in
        Text(option.rawValue).tag(option)
      }
    }
    .pickerStyle(.segmented)
  }
  
  private var customChatField: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Custom Chat DID")
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
      
      TextField("did:web:example.com#bsky_chat", text: $customChatDID)
        .textFieldStyle(.roundedBorder)
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .keyboardType(.URL)
        #endif
    }
    .padding(.top, 8)
  }
  
  private var resetSection: some View {
    Section {
      Button {
        resetToDefaults()
      } label: {
        HStack {
          Image(systemName: "arrow.counterclockwise")
          Text("Use Default Providers")
        }
      }
      .disabled(isSaving)
    }
  }
  
  private var saveSection: some View {
    Section {
      Button {
        Task {
          await saveChanges()
        }
      } label: {
        HStack {
          if isSaving {
            ProgressView()
              .progressViewStyle(.circular)
              #if os(iOS)
              .scaleEffect(0.8)
              #endif
          }
          Text(isSaving ? "Saving..." : "Save Changes")
                .appFont(AppTextRole.body).bold()
        }
        .frame(maxWidth: .infinity)
      }
      .disabled(!hasUnsavedChanges || isSaving)
      .buttonStyle(.borderedProminent)
    }
  }
  
  private var warningSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 8) {
        Label {
          Text("Warning")
                .appFont(AppTextRole.body).bold()
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        
        Text("AppViews give different views of the Bluesky social network. Some functionality may or may not work depending on what your AppView has implemented. If you experience issues loading content, reset to the default Bluesky AppView.")
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 4)
    }
  }
  
  private var appViewDescription: String {
    switch selectedAppViewOption {
    case .blueskyPBC:
      return "Official AppView operated by Bluesky PBC."
    case .blacksky:
      return "AppView with custom moderation operated by Blacksky Algorithms Inc."
    case .custom:
      return "Use a custom AppView service. The AppView handles timeline, profiles, and search functionality."
    }
  }
  
  private func loadCurrentSettings() async {
    let expectedDID = appState.userDID
    let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
    isLoadingProviders = true
    defer { isLoadingProviders = false }
    guard let client = AppStateManager.shared.authentication.client,
          let account = await client.getCurrentAccount(),
          !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else {
      return
    }
    
    // Determine AppView option
    if account.bskyAppViewDID == "did:web:api.bsky.app#bsky_appview" {
      selectedAppViewOption = .blueskyPBC
    } else if account.bskyAppViewDID == "did:web:api.blacksky.community#bsky_appview" {
      selectedAppViewOption = .blacksky
    } else {
      selectedAppViewOption = .custom
      customAppViewDID = account.bskyAppViewDID
    }
    
    // Determine Chat option
    if account.bskyChatDID == "did:web:api.bsky.chat#bsky_chat" {
      selectedChatOption = .blueskyPBC
    } else {
      selectedChatOption = .custom
      customChatDID = account.bskyChatDID
    }
    
    baseline = currentDraft
  }
  
  private func resetToDefaults() {
    selectedAppViewOption = .blueskyPBC
    selectedChatOption = .blueskyPBC
    customAppViewDID = ""
    customChatDID = ""
    publishDraftGuard()
  }
  
  private func saveChanges() async {
    let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
    guard let expectedDID = originDID, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision),
          let savedDraft = baseline, let client = AppStateManager.shared.authentication.client else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]
      )
      return
    }
    
    // Determine final DIDs based on selections
    let finalAppViewDID: String
    if let predefinedDID = selectedAppViewOption.did {
      finalAppViewDID = predefinedDID
    } else {
      finalAppViewDID = customAppViewDID
    }
    
    let finalChatDID: String
    if let predefinedDID = selectedChatOption.did {
      finalChatDID = predefinedDID
    } else {
      finalChatDID = customChatDID
    }
    
    // Validate DIDs
    guard !finalAppViewDID.isEmpty, finalAppViewDID.hasPrefix("did:") else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Invalid AppView DID format"]
      )
      return
    }
    
    guard !finalChatDID.isEmpty, finalChatDID.hasPrefix("did:") else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Invalid Chat DID format"]
      )
      return
    }
    
    isSaving = true
    
    do {
      // Update and persist the DIDs
      let original = SettingsProviderServiceDIDs(appView: savedDraft.appView.did ?? savedDraft.customAppView, chat: savedDraft.chat.did ?? savedDraft.customChat)
      let requested = SettingsProviderServiceDIDs(appView: finalAppViewDID, chat: finalChatDID)
      try await SettingsProviderTransaction.apply(accountDID: expectedDID, requested: requested, original: original,
        isCurrent: { SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) },
        persist: { values in
          try await client.updateAndPersistServiceDIDs(bskyAppViewDID: values.appView, bskyChatDID: values.chat)
        }, restoreRuntime: { values in
          await client.updateServiceDIDs(bskyAppViewDID: values.appView, bskyChatDID: values.chat)
        })
      
      guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { isSaving = false; return }
      baseline = currentDraft
      publishDraftGuard()
      showingSaveConfirmation = true
    } catch {
      guard SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { isSaving = false; return }
      self.error = error
    }
    
    isSaving = false
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
        AdvancedSettingsView()
      }
  }
}

