import SwiftUI

struct MuteWordsSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var newMuteWord: String = ""
  @State private var muteWords: [MutedWord] = []
  @State private var filteredMuteWords: [MutedWord] = []
  @State private var searchText: String = ""
  @State private var isLoading: Bool = true
  @State private var errorMessage: String?
  @State private var showingDeleteConfirmation = false
  @State private var wordToDelete: MutedWord?
  @State private var showingAddWordSuccess = false
  
  private var hasSearchText: Bool {
    !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  
  private var displayedMuteWords: [MutedWord] {
    hasSearchText ? filteredMuteWords : muteWords
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if !muteWords.isEmpty {
          searchBarSection
        }
        
        List {
          addWordSection
          
          muteWordsSection
          
          if !hasSearchText {
            aboutSection
          }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.sidebar)
        #endif
        .searchable(text: $searchText, prompt: "Search mute words")
        .onChange(of: searchText) {
          filterMuteWords()
        }
      }
    }
    .navigationTitle("Mute Words")
    #if os(iOS)
    .toolbarTitleDisplayMode(.large)
    #endif
    .themedSecondaryBackground(appState.themeManager, appSettings: appState.appSettings)
    .alert("Delete Mute Word", isPresented: $showingDeleteConfirmation) {
      Button("Delete", role: .destructive) {
        if let word = wordToDelete {
          removeMuteWord(word.id)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let word = wordToDelete {
        Text("Are you sure you want to remove \"\(word.value)\" from your mute words?")
      }
    }
    .overlay(
      Group {
        if showingAddWordSuccess {
          addWordSuccessToast
        }
      }
    )
    .task {
      await loadMuteWords()
    }
  }
  
  // MARK: - View Components
  
  @ViewBuilder
  private var searchBarSection: some View {
    if !muteWords.isEmpty {
      VStack(spacing: DesignTokens.Spacing.none) {
        HStack(spacing: DesignTokens.Spacing.sm) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
            .frame(width: DesignTokens.Size.iconSM, height: DesignTokens.Size.iconSM)
          
          TextField("Search mute words", text: $searchText)
            .textFieldStyle(.plain)
          
          if !searchText.isEmpty {
            Button {
              withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
                searchText = ""
              }
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Size.iconSM, height: DesignTokens.Size.iconSM)
            }
            .transition(.scale.combined(with: .opacity))
          }
        }
        .spacingBase(.horizontal)
        .spacingSM(.vertical)
        .themedElevatedBackground(appState.themeManager, elevation: .low, appSettings: appState.appSettings)
        .cornerRadiusMD()
        .spacingBase(.horizontal)
        .spacingSM(.top)
      }
    }
  }
  
  @ViewBuilder
  private var addWordSection: some View {
    Section {
      VStack(spacing: DesignTokens.Spacing.base) {
        HStack(spacing: DesignTokens.Spacing.base) {
#if os(iOS)
          TextField("Add new mute word", text: $newMuteWord)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled(true)
            .textInputAutocapitalization(.never)
            .onSubmit {
              addWordIfValid()
            }
#else
          TextField("Add new mute word", text: $newMuteWord)
            .onSubmit {
              addWordIfValid()
            }
#endif
          
          Button(action: addWordIfValid) {
            Image(systemName: "plus.circle.fill")
              .font(.title2)
              .foregroundStyle(newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 
                             Color.secondary : Color.blue)
          }
          .disabled(newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .scaleEffect(newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.9 : 1.0)
          .animation(.easeInOut(duration: DesignTokens.Duration.fast), value: newMuteWord.isEmpty)
        }
        
        if !newMuteWord.isEmpty && muteWords.contains(where: { $0.value.lowercased() == newMuteWord.lowercased() }) {
          HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .font(.caption)
            Text("This word is already in your mute list")
              .designFootnote()
              .foregroundStyle(.orange)
            Spacer()
          }
          .transition(.asymmetric(
            insertion: .scale.combined(with: .opacity),
            removal: .opacity
          ))
        }
      }
      .spacingSM(.vertical)
    } header: {
      Label("Add Mute Word", systemImage: "plus.bubble")
        .designCallout()
    }
  }
  
  @ViewBuilder
  private var muteWordsSection: some View {
    Section {
      if isLoading {
        loadingView
      } else if let error = errorMessage {
        errorView(error)
      } else if displayedMuteWords.isEmpty {
        emptyStateView
      } else {
        muteWordsList
      }
    } header: {
      HStack {
        Label(hasSearchText ? "Search Results" : "Current Mute Words", 
              systemImage: hasSearchText ? "magnifyingglass" : "text.badge.minus")
          .designCallout()
        
        Spacer()
        
        if !hasSearchText && !muteWords.isEmpty {
          Text("\(muteWords.count)")
            .designCaption()
            .foregroundStyle(.secondary)
            .spacingXS(.horizontal)
            .spacingXS(.vertical)
            .background(.secondary.opacity(0.2))
            .cornerRadiusSM()
        }
      }
    }
  }
  
  @ViewBuilder
  private var muteWordsList: some View {
    ForEach(displayedMuteWords, id: \.id) { word in
      muteWordRow(word)
        .transition(.asymmetric(
          insertion: .scale.combined(with: .opacity),
          removal: .opacity.combined(with: .move(edge: .trailing))
        ))
    }
    .onDelete(perform: hasSearchText ? nil : deleteMuteWords)
  }
  
  @ViewBuilder
  private func muteWordRow(_ word: MutedWord) -> some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
        Text(word.value)
          .designBody()
          .foregroundStyle(.primary)
        
        if !word.targets.isEmpty {
          Text("Targets: \(word.targets.joined(separator: ", "))")
            .designCaption()
            .foregroundStyle(.secondary)
        }
      }
      
      Spacer()
      
      Button {
        wordToDelete = word
        showingDeleteConfirmation = true
      } label: {
        Image(systemName: "trash")
          .foregroundStyle(.red)
          .frame(width: DesignTokens.Size.iconMD, height: DesignTokens.Size.iconMD)
      }
      .buttonStyle(.plain)
    }
    .spacingSM(.vertical)
    #if os(iOS)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button("Delete", role: .destructive) {
        removeMuteWord(word.id)
      }
    }
    #endif
    .contextMenu {
      Button("Delete", role: .destructive) {
        wordToDelete = word
        showingDeleteConfirmation = true
      }
    }
  }
  
  @ViewBuilder
  private var loadingView: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      ProgressView()
        .scaleEffect(0.8)
      Text("Loading mute words...")
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
        Text("Error")
          .designCallout()
          .foregroundStyle(.red)
        Spacer()
      }
      
      Text(error)
        .designBody()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
      
      Button("Retry") {
        Task {
          await loadMuteWords()
        }
      }
      .buttonStyle(.borderedProminent)
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
    VStack(spacing: DesignTokens.Spacing.base) {
      Image(systemName: hasSearchText ? "magnifyingglass" : "text.badge.minus")
        .font(.title)
        .foregroundStyle(.secondary)
        .frame(width: DesignTokens.Size.iconXL, height: DesignTokens.Size.iconXL)
      
      Text(hasSearchText ? "No matching mute words" : "No mute words added yet")
        .designCallout()
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      
      if hasSearchText {
        Text("Try adjusting your search terms")
          .designFootnote()
          .foregroundStyle(.tertiary)
      } else {
        Text("Add words above to hide posts containing them from your feeds")
          .designFootnote()
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .spacingXL(.vertical)
    .frame(maxWidth: .infinity)
  }
  
  @ViewBuilder
  private var aboutSection: some View {
    Section {
      VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
        HStack(spacing: DesignTokens.Spacing.xs) {
          Image(systemName: "info.circle")
            .foregroundStyle(.blue)
            .font(.caption)
          Text("How Mute Words Work")
            .designCallout()
            .foregroundStyle(.primary)
        }
        
        Text("Posts containing these words will be hidden from your feeds. Changes take effect immediately and sync across all your devices.")
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
        Text("Mute word added")
          .designCallout()
          .foregroundStyle(.primary)
      }
      .spacingBase(.horizontal)
      .spacingSM(.vertical)
      .themedElevatedBackground(appState.themeManager, elevation: .medium, appSettings: appState.appSettings)
      .cornerRadiusLG()
      .shadowSoft()
      .spacingBase(.bottom)
      .transition(.asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .opacity
      ))
    }
    .onAppear {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        withAnimation(.easeInOut(duration: DesignTokens.Duration.normal)) {
          showingAddWordSuccess = false
        }
      }
    }
  }

  // MARK: - Helper Methods
  
  private func addWordIfValid() {
    let trimmedWord = newMuteWord.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedWord.isEmpty && !muteWords.contains(where: { $0.value.lowercased() == trimmedWord.lowercased() }) {
      addMuteWord(trimmedWord)
      newMuteWord = ""
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
    withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
      for index in offsets {
        let word = muteWords[index]
        removeMuteWord(word.id)
      }
    }
  }

  private func loadMuteWords() async {
    withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
      isLoading = true
      errorMessage = nil
    }
    
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      
      withAnimation(.easeInOut(duration: DesignTokens.Duration.normal)) {
        muteWords = preferences.mutedWords
        isLoading = false
      }
      
      // Filter the words based on current search
      filterMuteWords()
      
      // Also update the local filter
      updateMuteWordFilter()
    } catch {
      withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
        errorMessage = "Failed to load mute words: \(error.localizedDescription)"
        isLoading = false
      }
    }
  }

  private func addMuteWord(_ word: String) {
    Task {
      do {
        // Add to server preferences - using default targets of "content"
        try await appState.preferencesManager.addMutedWord(
          word: word,
          targets: ["content"],
          actorTarget: nil,
          expiresAt: nil
        )
        
        // Show success feedback
        withAnimation(.easeInOut(duration: DesignTokens.Duration.normal)) {
          showingAddWordSuccess = true
        }
        
        // Refresh mute words list from server
        await loadMuteWords()
      } catch {
        withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
          errorMessage = "Failed to add mute word: \(error.localizedDescription)"
          isLoading = false
        }
      }
    }
  }

  private func removeMuteWord(_ id: String) {
    // Optimistically remove from UI with animation
    withAnimation(.easeInOut(duration: DesignTokens.Duration.normal)) {
      muteWords.removeAll { $0.id == id }
      filterMuteWords()
    }
    
    Task {
      do {
        // Remove from server preferences
        try await appState.preferencesManager.removeMutedWord(id: id)
        
        // Update the local filter
        updateMuteWordFilter()
      } catch {
        // Revert the optimistic update and show error
        await loadMuteWords()
        
        withAnimation(.easeInOut(duration: DesignTokens.Duration.fast)) {
          errorMessage = "Failed to remove mute word: \(error.localizedDescription)"
        }
      }
    }
  }

  private func updateMuteWordFilter() {
    // Update the mute words filter in FeedFilterSettings
    let wordValues = muteWords.map { $0.value }
    let processor = MuteWordProcessor(muteWords: wordValues)
    appState.feedFilterSettings.updateMuteWordProcessor(processor)
  }
}
