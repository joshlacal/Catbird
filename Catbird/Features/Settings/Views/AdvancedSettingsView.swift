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
  @State private var activeSaveID: UUID?
  private var isSaving: Bool { activeSaveID != nil }
  @State private var showingSaveConfirmation = false
  @State private var saveOutcomeUnconfirmed = false
  @State private var confirmingReload = false
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
      SettingsFocusedForm(initialFocus: initialFocus == nil || baseline != nil ? initialFocus : .init(rawValue: "advanced.providerRetryLoad"), isReady: !isLoadingProviders) {
        SettingsScopeSection()
        if isLoadingProviders { Section { ProgressView("Loading service providers…") } }
        else if baseline == nil {
          Section {
            Text("Couldn’t load service providers. Your current providers are unchanged.").foregroundStyle(.secondary)
            Button("Try Again") { Task { _ = await loadCurrentSettings(); publishDraftGuard() } }
              .settingsControl(.init(rawValue: "advanced.providerRetryLoad"))
          }
        }
        if saveOutcomeUnconfirmed {
          Section("Save Not Confirmed") {
            Text("Catbird couldn’t confirm which providers were saved. Your choices are still here. Reload to check, or try again.")
              .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Reload Saved Providers") { confirmingReload = true }
            Button("Retry These Choices") { Task { await saveChanges() } }
          }
          .disabled(isSaving || isLoadingProviders)
          .settingsControl(.init(rawValue: "advanced.providerRecovery"))
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
      _ = await loadCurrentSettings()
      publishDraftGuard()
    }
    .onChange(of: currentDraft) { _, _ in publishDraftGuard() }
    .interactiveDismissDisabled(hasUnsavedChanges || saveOutcomeUnconfirmed || isSaving)
    .navigationBarBackButtonHidden(hasUnsavedChanges || saveOutcomeUnconfirmed || isSaving)
    .toolbar {
      if hasUnsavedChanges || saveOutcomeUnconfirmed {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back", systemImage: "chevron.left") { confirmingDeparture = true }.disabled(isSaving)
        }
      }
    }
    .confirmationDialog("Unsaved Provider Changes", isPresented: $confirmingDeparture, titleVisibility: .visible) {
      Button("Save") { Task { if await resolveDraft(save: true) { dismiss() } } }
      Button("Discard Changes", role: .destructive) { Task { if await resolveDraft(save: false) { dismiss() } } }
      Button("Stay", role: .cancel) { }
    }
    .onDisappear { if draftGuard?.accountDID == originDID { draftGuard?.hasChanges = false; draftGuard?.resolve = nil } }
    .confirmationDialog("Reload Saved Providers?", isPresented: $confirmingReload, titleVisibility: .visible) {
      Button("Reload Saved Providers") { Task { _ = await loadCurrentSettings(reconcileRuntime: true); publishDraftGuard() } }
      Button("Keep Typed Choices", role: .cancel) { }
    } message: { Text("Replace your choices with the providers saved to this account.") }
    .alert("Saved", isPresented: $showingSaveConfirmation) {
      Button("OK") {
        showingSaveConfirmation = false
      }
    } message: {
      Text("Service providers updated.")
    }
    .alert(error.map { ($0 as NSError).code } == -4 ? "Couldn’t Reload Providers" : "Couldn’t Save Providers", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") {
        error = nil
      }
    } message: {
      if let error {
        Text((error as NSError).domain == "AdvancedSettings" ? error.localizedDescription : (UserFacingError.message(for: error, action: "save service providers") ?? "Couldn’t save service providers. Try again."))
      }
    }
  }
  
  @MainActor private func publishDraftGuard() {
    draftGuard?.accountDID = originDID
    draftGuard?.hasChanges = hasUnsavedChanges || saveOutcomeUnconfirmed || isSaving
    draftGuard?.resolve = { save in await self.resolveDraft(save: save) }
  }
  @MainActor private func resolveDraft(save: Bool) async -> Bool {
    guard !isSaving else { return false }
    guard originDID == appState.userDID && originDID.map(SettingsAccountBoundary.isCurrent) == true else { return false }
    if save {
      let didSave = await saveChanges()
      return didSave && !isSaving && !hasUnsavedChanges && !saveOutcomeUnconfirmed
    }
    if saveOutcomeUnconfirmed {
      let reloaded = await loadCurrentSettings(reconcileRuntime: true)
      publishDraftGuard()
      return reloaded
    }
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
      Text("Choose which services provide content and direct messages for this account. Your choice is saved with this account.")
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
          Text(isSaving ? "Saving…" : "Save Changes")
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
  
  private func loadCurrentSettings(reconcileRuntime: Bool = false) async -> Bool {
    let expectedAppState = appState
    let expectedDID = expectedAppState.userDID
    let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
    let token = reconcileRuntime ? SettingsAccountOperationGate.begin(for: expectedDID) : nil
    if reconcileRuntime && token == nil { error = SettingsProviderTransaction.Failure.operationInProgress; return false }
    isLoadingProviders = true
    defer {
      isLoadingProviders = false
      if let token { SettingsAccountOperationGate.end(token: token) }
    }
    guard let client = expectedAppState.atProtoClient,
          SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return false }
    do {
      let account = try await expectedAppState.performSettingsAccountOperation {
        guard SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { throw CancellationError() }
        guard let account = await client.getCurrentAccount(), account.did == expectedDID,
              !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else {
          throw CancellationError()
        }
        if reconcileRuntime {
          await client.updateServiceDIDs(bskyAppViewDID: account.bskyAppViewDID, bskyChatDID: account.bskyChatDID)
          guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { throw CancellationError() }
        }
        return account
      }
      guard !Task.isCancelled, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return false }

      // Determine AppView option
      if account.bskyAppViewDID == "did:web:api.bsky.app#bsky_appview" {
        selectedAppViewOption = .blueskyPBC
        customAppViewDID = ""
      } else if account.bskyAppViewDID == "did:web:api.blacksky.community#bsky_appview" {
        selectedAppViewOption = .blacksky
        customAppViewDID = ""
      } else {
        selectedAppViewOption = .custom
        customAppViewDID = account.bskyAppViewDID
      }
      
      // Determine Chat option
      if account.bskyChatDID == "did:web:api.bsky.chat#bsky_chat" {
        selectedChatOption = .blueskyPBC
        customChatDID = ""
      } else {
        selectedChatOption = .custom
        customChatDID = account.bskyChatDID
      }
      
      baseline = currentDraft
      if reconcileRuntime { saveOutcomeUnconfirmed = false; error = nil }
      return true
    } catch {
      guard SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return false }
      if reconcileRuntime {
        self.error = NSError(domain: "AdvancedSettings", code: -4, userInfo: [NSLocalizedDescriptionKey: "Couldn’t reload saved providers. Your choices are still here. Try again."])
      }
      return false
    }
  }
  
  private func resetToDefaults() {
    selectedAppViewOption = .blueskyPBC
    selectedChatOption = .blueskyPBC
    customAppViewDID = ""
    customChatDID = ""
    publishDraftGuard()
  }
  
  @discardableResult
  private func saveChanges() async -> Bool {
    // A queued Save or departure resolver cannot mutate the owning save's state.
    guard activeSaveID == nil else { return false }
    let requestedDraft = currentDraft
    let expectedAppState = appState
    let expectedRevision = AppStateManager.shared.settingsAccountContextRevision
    guard let expectedDID = originDID, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision),
          let savedDraft = baseline, expectedAppState.userDID == expectedDID, let client = expectedAppState.atProtoClient else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey: "Sign in again to change service providers."]
      )
      return false
    }
    
    // Determine final DIDs based on selections
    let finalAppViewDID: String
    if let predefinedDID = requestedDraft.appView.did {
      finalAppViewDID = predefinedDID
    } else {
      finalAppViewDID = requestedDraft.customAppView
    }
    
    let finalChatDID: String
    if let predefinedDID = requestedDraft.chat.did {
      finalChatDID = predefinedDID
    } else {
      finalChatDID = requestedDraft.customChat
    }
    
    // Validate DIDs
    guard !finalAppViewDID.isEmpty, finalAppViewDID.hasPrefix("did:") else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Enter a valid AppView service identifier. It starts with “did:”."]
      )
      return false
    }
    
    guard !finalChatDID.isEmpty, finalChatDID.hasPrefix("did:") else {
      error = NSError(
        domain: "AdvancedSettings",
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Enter a valid chat service identifier. It starts with “did:”."]
      )
      return false
    }
    
    let saveID = UUID()
    activeSaveID = saveID
    publishDraftGuard()
    defer {
      if activeSaveID == saveID {
        activeSaveID = nil
        publishDraftGuard()
      }
    }
    var didAttemptSDKSave = false

    do {
      // Update and persist the DIDs
      let original = SettingsProviderServiceDIDs(appView: savedDraft.appView.did ?? savedDraft.customAppView, chat: savedDraft.chat.did ?? savedDraft.customChat)
      let requested = SettingsProviderServiceDIDs(appView: finalAppViewDID, chat: finalChatDID)
      try await expectedAppState.performSettingsAccountOperation {
        try await SettingsProviderTransaction.apply(accountDID: expectedDID, requested: requested, original: original,
          isCurrent: { SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) },
          persist: { values in
            didAttemptSDKSave = true
            try await client.updateAndPersistServiceDIDs(bskyAppViewDID: values.appView, bskyChatDID: values.chat)
          }, restoreRuntime: { values in
            await client.updateServiceDIDs(bskyAppViewDID: values.appView, bskyChatDID: values.chat)
          })
      }
      
      guard activeSaveID == saveID, !Task.isCancelled,
            SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return false }
      baseline = requestedDraft
      saveOutcomeUnconfirmed = false
      publishDraftGuard()
      showingSaveConfirmation = true
      return true
    } catch {
      guard activeSaveID == saveID, SettingsAccountBoundary.isCurrent(expectedDID, revision: expectedRevision) else { return false }
      saveOutcomeUnconfirmed = saveOutcomeUnconfirmed || didAttemptSDKSave
      publishDraftGuard()
      if didAttemptSDKSave {
        self.error = NSError(domain: "AdvancedSettings", code: -5, userInfo: [NSLocalizedDescriptionKey: "Catbird couldn’t confirm which providers were saved. Your choices are still here. Reload to check, or try again."])
      } else {
        self.error = error
      }
    }
    
    return false
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
        AdvancedSettingsView()
      }
  }
}

