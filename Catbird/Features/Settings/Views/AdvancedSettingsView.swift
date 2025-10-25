import SwiftUI
import Petrel

struct AdvancedSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  
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
  @State private var hasUnsavedChanges = false
  
  var body: some View {
    ResponsiveContentView {
      List {
        headerSection
        appViewSection
        chatSection
        resetSection
        saveSection
        warningSection
      }
    }
    .navigationTitle("Advanced Settings")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    .task {
      await loadCurrentSettings()
    }
    .alert("Saved", isPresented: $showingSaveConfirmation) {
      Button("OK") {
        showingSaveConfirmation = false
      }
    } message: {
      Text("Service DID settings have been updated.")
    }
    .alert("Error", isPresented: .constant(error != nil)) {
      Button("OK") {
        error = nil
      }
    } message: {
      if let error {
        Text(error.localizedDescription)
      }
    }
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
    .onChange(of: selectedAppViewOption) { _, _ in
      hasUnsavedChanges = true
    }
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
        .onChange(of: customAppViewDID) { _, _ in
          hasUnsavedChanges = true
        }
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
    .onChange(of: selectedChatOption) { _, _ in
      hasUnsavedChanges = true
    }
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
        .onChange(of: customChatDID) { _, _ in
          hasUnsavedChanges = true
        }
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
          Text("Reset to Defaults")
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
    guard let client = appState.authManager.client,
          let account = await client.getCurrentAccount() else {
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
    
    hasUnsavedChanges = false
  }
  
  private func resetToDefaults() {
    selectedAppViewOption = .blueskyPBC
    selectedChatOption = .blueskyPBC
    customAppViewDID = ""
    customChatDID = ""
    hasUnsavedChanges = true
  }
  
  private func saveChanges() async {
    guard let client = appState.authManager.client else {
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
      try await client.updateAndPersistServiceDIDs(
        bskyAppViewDID: finalAppViewDID,
        bskyChatDID: finalChatDID
      )
      
      hasUnsavedChanges = false
      showingSaveConfirmation = true
    } catch {
      self.error = error
    }
    
    isSaving = false
  }
}

#Preview {
  NavigationStack {
    AdvancedSettingsView()
      .environment(AppState.shared)
  }
}
