import SwiftUI

struct MuteWordsSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var newMuteWord: String = ""
  @State private var muteWords: [MutedWord] = []
  @State private var filteredMuteWords: [MutedWord] = []
  @State private var searchText: String = ""
  @State private var isLoading: Bool = true
  @State private var hasConfirmedPreferences = false
  @State private var isSaving = false
  @State private var loadedIdentity: AccountReadIdentity?
  @State private var loadRequest = UUID()
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false
  @State private var wordToDelete: MutedWord?
  @State private var deleteConfirmationRequest: UUID?
  @State private var showingAddWordSuccess = false

  private struct AccountReadIdentity: Hashable {
    let accountDID: String
    let state: ObjectIdentifier
    let manager: ObjectIdentifier
  }

  private var accountReadIdentity: AccountReadIdentity {
    .init(accountDID: appState.userDID, state: ObjectIdentifier(appState),
          manager: ObjectIdentifier(appState.preferencesManager))
  }
  
  private var hasSearchText: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  private var displayedMuteWords: [MutedWord] {
    hasSearchText ? filteredMuteWords : muteWords
  }

  private var canEdit: Bool {
    hasConfirmedPreferences && !isLoading && !isSaving
      && loadedIdentity == accountReadIdentity
      && appState.preferencesManager.accountDID == appState.userDID
  }

  var body: some View {
    List {
      addWordSection

      muteWordsSection

      if !hasSearchText && !muteWords.isEmpty {
        aboutSection
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.sidebar)
    #endif
    .searchable(text: $searchText, prompt: "Search muted words")
    .onChange(of: searchText) {
      filterMuteWords()
    }
    .navigationTitle("Muted Words & Tags")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .themedSecondaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .alert("Remove Muted Word", isPresented: $showingDeleteConfirmation) {
      Button("Remove", role: .destructive) {
        if let word = wordToDelete, deleteConfirmationRequest == loadRequest {
          removeMuteWord(word.id)
        }
      }
      .disabled(!canEdit)
      Button("Cancel", role: .cancel) {}
    } message: {
      if let word = wordToDelete {
        Text("Remove “\(word.value)” from your muted words?")
      }
    }
    .overlay(
      Group {
        if showingAddWordSuccess {
          addWordSuccessToast
        }
      }
    )
    .task(id: accountReadIdentity) {
      await loadMuteWords()
    }
    .onDisappear {
      loadRequest = UUID()
      hasConfirmedPreferences = false
      showingDeleteConfirmation = false
      deleteConfirmationRequest = nil
    }
  }
  
  // MARK: - View Components
  
  
  @ViewBuilder
  private var addWordSection: some View {
    Section {
      HStack(spacing: DesignTokens.Spacing.sm) {
#if os(iOS)
        TextField("Add a word or tag", text: $newMuteWord)
          .textFieldStyle(.plain)
          .autocorrectionDisabled(true)
          .textInputAutocapitalization(.never)
          .accessibilityIdentifier("settings.mutedWords.input")
          .onSubmit {
            addWordIfValid()
          }
#else
        TextField("Add a word or tag", text: $newMuteWord)
          .textFieldStyle(.plain)
          .accessibilityIdentifier("settings.mutedWords.input")
          .onSubmit {
            addWordIfValid()
          }
#endif
        
        Button(action: addWordIfValid) {
          Image(systemName: "plus.circle.fill")
            .foregroundStyle(newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                .secondary : Color.blue)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(!canEdit || newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .buttonStyle(.plain)
        .accessibilityLabel("Add Muted Word")
        .accessibilityIdentifier("settings.mutedWords.add")
      }
      .disabled(!canEdit)
      
      if !newMuteWord.isEmpty && muteWords.contains(where: { $0.value.lowercased() == newMuteWord.lowercased() }) {
        Label("This word is already muted", systemImage: "exclamationmark.triangle.fill")
          .designFootnote()
          .foregroundStyle(.orange)
      }
    }
  }
  
  @ViewBuilder
  private var muteWordsSection: some View {
    Section {
      if isLoading {
        loadingView
      }
      if isSaving {
        ProgressView("Saving muted words…")
      }
      if let error = errorMessage {
        errorView(error)
      }
      if !displayedMuteWords.isEmpty {
        muteWordsList
      } else if hasConfirmedPreferences && !isLoading && errorMessage == nil {
        emptyStateView
      }
    } header: {
      if !muteWords.isEmpty {
        Text(hasSearchText ? "Search Results" : "Muted Words")
          .designCallout()
      }
    }
  }
  
  @ViewBuilder
  private var muteWordsList: some View {
    // Imported rules can lack IDs; retain every rule without inventing an identity for server edits.
    ForEach(Array(displayedMuteWords.enumerated()), id: \.offset) { _, word in
      muteWordRow(word)
        .deleteDisabled(!canEdit || !hasUniqueIdentifier(word.id))
    }
    .onDelete(perform: hasSearchText || !canEdit ? nil : deleteMuteWords)
  }
  
  @ViewBuilder
  private func muteWordRow(_ word: MutedWord) -> some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(word.value)
          .designBody()
          .foregroundStyle(.primary)
        
        if !word.targets.isEmpty {
          Text(targetsDescription(word.targets))
            .designCaption()
            .foregroundStyle(.secondary)
        } else {
          Text("Not muting anything")
            .designCaption()
            .foregroundStyle(.secondary)
        }
        if let actorTarget = word.actorTarget, actorTarget != "all" {
          Text(actorTarget == "exclude-following" ? "Accounts you follow are excluded"
            : "Custom account rule")
            .designCaption()
            .foregroundStyle(.secondary)
        } else {
          Text("Applies to all accounts")
            .designCaption()
            .foregroundStyle(.secondary)
        }
        if let expiresAt = word.expiresAt {
          Text(expiresAt <= Date() ? "Expired \(expiresAt.formatted(date: .abbreviated, time: .shortened))"
            : "Expires: \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
            .designCaption()
            .foregroundStyle(.secondary)
        }
        if !hasUniqueIdentifier(word.id) {
          Text("This muted word can only be removed from the Bluesky app.")
            .designCaption()
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      Button {
        confirmRemoval(of: word)
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(.red)
          .frame(width: DesignTokens.Size.iconMD, height: DesignTokens.Size.iconMD)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canEdit || !hasUniqueIdentifier(word.id))
      .accessibilityLabel("Remove “\(word.value)”")
    }
    .spacingSM(.vertical)
    #if os(iOS)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button("Remove", role: .destructive) {
        removeMuteWord(word.id)
      }
      .disabled(!canEdit || !hasUniqueIdentifier(word.id))
    }
    #endif
    .contextMenu {
      Button("Remove", role: .destructive) {
        confirmRemoval(of: word)
      }
      .disabled(!canEdit || !hasUniqueIdentifier(word.id))
    }
  }
  
  @ViewBuilder
  private var loadingView: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading muted words…")
        .designBody()
        .foregroundStyle(.secondary)
      Spacer()
    }
    .spacingBase(.vertical)
  }
  
  @ViewBuilder
  private func errorView(_ error: String) -> some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
        Text("Something Went Wrong")
          .designCallout()
          .foregroundStyle(.red)
        Spacer()
      }
      
      Text(error)
        .designBody()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      
      Button("Try Again") {
        Task {
          await loadMuteWords()
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isLoading || isSaving)
      .accessibilityIdentifier("settings.mutedWords.retry")
      .controlSize(.small)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .spacingBase(.vertical)
    .themedElevatedBackground(appState.themeManager, elevation: .low, appSettings: appState.appSettings)
    .cornerRadiusMD()
    .spacingSM()
  }
  
  @ViewBuilder
  private var emptyStateView: some View {
    VStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: hasSearchText ? "magnifyingglass" : "text.badge.minus")
        .font(.title2)
        .foregroundStyle(.tertiary)
      
      Text(hasSearchText ? "No matching words" : "No muted words yet")
        .designBody()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      
      if !hasSearchText {
        Text("Add words or tags to hide posts that contain them.")
          .designFootnote()
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .spacingLG(.vertical)
    .frame(maxWidth: .infinity)
  }
  
  @ViewBuilder
  private var aboutSection: some View {
    Section {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "info.circle")
            .foregroundStyle(.blue)
            .designCaption()
          Text("How Muted Words Work")
            .designCallout()
            .foregroundStyle(.primary)
        }
        
        Text("Posts matching each rule’s targets are hidden from your feeds. Saved changes sync across your devices.")
          .designFootnote()
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .spacingBase(.vertical)
    }
  }
  
  @ViewBuilder
  private var addWordSuccessToast: some View {
    VStack {
      Spacer()
      
      HStack(spacing: DesignTokens.Spacing.sm) {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
        Text("Word muted")
          .designCallout()
          .foregroundStyle(.primary)
      }
      .spacingBase(.horizontal)
      .spacingSM(.vertical)
      .themedElevatedBackground(appState.themeManager, elevation: .medium, appSettings: appState.appSettings)
      .cornerRadiusLG()
      .shadowSoft()
      .spacingBase(.bottom)
    }
    .frame(maxHeight: .infinity, alignment: .bottom)
    .allowsHitTesting(false)
    .task {
      let request = loadRequest
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled, loadRequest == request else { return }
      showingAddWordSuccess = false
    }
  }

  // MARK: - Helper Methods
  
  private func addWordIfValid() {
    guard canEdit else { return }
    let trimmedWord = newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedWord.isEmpty && !muteWords.contains(where: { $0.value.lowercased() == trimmedWord.lowercased() }) {
      addMuteWord(trimmedWord)
    }
  }
  
  private func filterMuteWords() {
    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      filteredMuteWords = muteWords
    } else {
      let searchTerm = searchText.lowercased()
      filteredMuteWords = muteWords.filter { word in
        word.value.lowercased().contains(searchTerm)
      }
    }
  }
  
  private func deleteMuteWords(at offsets: IndexSet) {
    guard canEdit, !hasSearchText else { return }
    let ids = offsets.compactMap { offset in
      muteWords.indices.contains(offset) && hasUniqueIdentifier(muteWords[offset].id) ? muteWords[offset].id : nil
    }
    removeMuteWords(ids)
  }

  @MainActor
  private func loadMuteWords() async {
    let originatingState = appState
    let manager = originatingState.preferencesManager
    let account = originatingState.userDID
    let request = UUID()
    let identity = AccountReadIdentity(accountDID: account, state: ObjectIdentifier(originatingState),
                                       manager: ObjectIdentifier(manager))
    loadRequest = request
    wordToDelete = nil
    deleteConfirmationRequest = nil
    showingDeleteConfirmation = false
    if loadedIdentity != identity {
      muteWords = []
      filteredMuteWords = []
      newMuteWord = ""
      searchText = ""
      showingAddWordSuccess = false
    }
    loadedIdentity = identity
    hasConfirmedPreferences = false
    isSaving = false
    isLoading = true
    errorMessage = nil
    defer {
      if isCurrent(request, account: account, state: originatingState, manager: manager) {
        isLoading = false
      }
    }
    
    do {
      let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
      guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
      guard preferences.accountDID == account, preferences.hasConfirmedServerPreferences else {
        throw PreferencesManagerError.invalidData
      }
      muteWords = preferences.mutedWords
      hasConfirmedPreferences = true
      filterMuteWords()
    } catch {
      guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
      errorMessage = UserFacingError.message(for: error, action: "load your muted words") ?? "Couldn’t load your muted words. Try again."
    }
  }

  private func addMuteWord(_ word: String) {
    guard canEdit else { return }
    let originatingState = appState
    let manager = originatingState.preferencesManager
    let account = originatingState.userDID
    let request = loadRequest
    let submittedText = newMuteWord
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      defer {
        if isCurrent(request, account: account, state: originatingState, manager: manager) { isSaving = false }
      }
      do {
        guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
        try await manager.addMutedWord(
          word: word,
          targets: ["content"],
          actorTarget: nil,
          expiresAt: nil,
          expectedAccountDID: account
        )
        guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
        try publishAcceptedWords(from: manager, account: account)
        if newMuteWord == submittedText { newMuteWord = "" }
        showingAddWordSuccess = true
      } catch {
        guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
        hasConfirmedPreferences = false
        errorMessage = UserFacingError.message(for: error, action: "mute this word") ?? "Couldn’t mute this word. Try again."
      }
    }
  }

  private func removeMuteWord(_ id: String) {
    removeMuteWords([id])
  }

  private func removeMuteWords(_ ids: [String]) {
    guard canEdit, !ids.isEmpty, ids.allSatisfy(hasUniqueIdentifier) else { return }
    let originatingState = appState
    let manager = originatingState.preferencesManager
    let account = originatingState.userDID
    let request = loadRequest
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      defer {
        if isCurrent(request, account: account, state: originatingState, manager: manager) { isSaving = false }
      }
      var isConfirmingRemoval = false
      do {
        for id in ids {
          isConfirmingRemoval = false
          guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
          try await manager.removeMutedWord(id: id, expectedAccountDID: account)
          guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
          isConfirmingRemoval = true
          // A missing remote ID is a no-op; confirm the actual list before removing a retained row.
          let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
          guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
          guard preferences.accountDID == account, preferences.hasConfirmedServerPreferences else {
            throw PreferencesManagerError.invalidData
          }
          muteWords = preferences.mutedWords
          filterMuteWords()
        }
      } catch {
        guard isCurrent(request, account: account, state: originatingState, manager: manager) else { return }
        hasConfirmedPreferences = false
        let action = isConfirmingRemoval ? "refresh your muted words" : "remove this muted word"
        errorMessage = UserFacingError.message(for: error, action: action) ?? "Couldn’t \(action). Try again."
      }
    }
  }

  /// Plain-language summary of a rule's protocol targets ("content" covers post text and tags).
  private func targetsDescription(_ targets: [String]) -> String {
    if targets.contains("content") { return "Mutes post text and tags" }
    if targets.contains("tag") { return "Mutes tags only" }
    return "Custom rule"
  }

  private func hasUniqueIdentifier(_ id: String) -> Bool {
    !id.isEmpty && muteWords.filter { $0.id == id }.count == 1
  }

  private func confirmRemoval(of word: MutedWord) {
    guard canEdit, hasUniqueIdentifier(word.id) else { return }
    wordToDelete = word
    deleteConfirmationRequest = loadRequest
    showingDeleteConfirmation = true
  }

  @MainActor
  private func publishAcceptedWords(from manager: PreferencesManager, account: String) throws {
    guard let preferences = try manager.confirmedFeedFilterPreferences(),
          preferences.accountDID == account else { throw PreferencesManagerError.invalidData }
    muteWords = preferences.mutedWords
    filterMuteWords()
  }

  @MainActor
  private func isCurrent(_ request: UUID, account: String, state: AppState, manager: PreferencesManager) -> Bool {
    !Task.isCancelled && loadRequest == request && loadedIdentity == accountReadIdentity
      && loadedIdentity?.accountDID == account
      && appState === state && state.userDID == account
      && state.preferencesManager === manager && manager.accountDID == account
  }
}

#Preview("MuteWordsSettingsView") {
  NavigationStack {
    MuteWordsSettingsView()
  }
  .previewWithAuthenticatedState()
}
