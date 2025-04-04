import SwiftUI

struct MuteWordsSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var newMuteWord: String = ""
  @State private var muteWords: [MutedWord] = []
  @State private var isLoading: Bool = true
  @State private var errorMessage: String? = nil

  var body: some View {
    List {
      Section(header: Text("Add Mute Word")) {
        HStack {
          TextField("New mute word", text: $newMuteWord)

          Button("Add") {
            if !newMuteWord.isEmpty && !muteWords.contains(where: { $0.value == newMuteWord }) {
              addMuteWord(newMuteWord)
              newMuteWord = ""
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(newMuteWord.isEmpty)
        }
      }

      Section(header: Text("Current Mute Words")) {
        if isLoading {
          ProgressView()
        } else if let error = errorMessage {
          Text(error)
            .foregroundStyle(.red)
        } else if muteWords.isEmpty {
          Text("No mute words added yet")
            .foregroundStyle(.secondary)
            .italic()
        } else {
          ForEach(muteWords, id: \.id) { word in
            HStack {
              Text(word.value)

              Spacer()

              Button {
                removeMuteWord(word.id)
              } label: {
                Image(systemName: "trash")
                  .foregroundColor(.red)
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      Section(header: Text("About Mute Words")) {
        Text(
          "Posts containing these words will be hidden from your feeds. Changes take effect immediately and sync across all your devices."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Mute Words")
    .task {
      await loadMuteWords()
    }
  }

  private func loadMuteWords() async {
    isLoading = true
    errorMessage = nil
    
    do {
      let preferences = try await appState.preferencesManager.getPreferences()
      muteWords = preferences.mutedWords
      isLoading = false
      
      // Also update the local filter
      updateMuteWordFilter()
    } catch {
      errorMessage = "Failed to load mute words: \(error.localizedDescription)"
      isLoading = false
    }
  }

  private func addMuteWord(_ word: String) {
    // Show loading state
    isLoading = true
    
    Task {
      do {
        // Add to server preferences - using default targets of "content"
        try await appState.preferencesManager.addMutedWord(
          word: word,
          targets: ["content"],
          actorTarget: nil,
          expiresAt: nil
        )
        
        // Refresh mute words list from server
        await loadMuteWords()
      } catch {
        errorMessage = "Failed to add mute word: \(error.localizedDescription)"
        isLoading = false
      }
    }
  }

  private func removeMuteWord(_ id: String) {
    // Show loading state
    isLoading = true
    
    Task {
      do {
        // Remove from server preferences
        try await appState.preferencesManager.removeMutedWord(id: id)
        
        // Refresh mute words list from server
        await loadMuteWords()
      } catch {
        errorMessage = "Failed to remove mute word: \(error.localizedDescription)"
        isLoading = false
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
