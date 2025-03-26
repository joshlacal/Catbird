import SwiftUI

struct MuteWordsSettingsView: View {
  @Environment(AppState.self) private var appState
  @State private var newMuteWord: String = ""

  // Store mute words in UserDefaults
  @AppStorage("muteWords") private var muteWordsString: String = ""

  private var muteWords: [String] {
    muteWordsString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  var body: some View {
    List {
      Section(header: Text("Add Mute Word")) {
        HStack {
          TextField("New mute word", text: $newMuteWord)

          Button("Add") {
            if !newMuteWord.isEmpty && !muteWords.contains(newMuteWord) {
              addMuteWord(newMuteWord)
              newMuteWord = ""
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(newMuteWord.isEmpty)
        }
      }

      Section(header: Text("Current Mute Words")) {
        if muteWords.isEmpty {
          Text("No mute words added yet")
            .foregroundStyle(.secondary)
            .italic()
        } else {
          ForEach(muteWords, id: \.self) { word in
            HStack {
              Text(word)

              Spacer()

              Button {
                removeMuteWord(word)
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
          "Posts containing these words will be hidden from your feeds. Changes take effect immediately."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Mute Words")
  }

  private func addMuteWord(_ word: String) {
    var words = muteWords
    words.append(word)
    muteWordsString = words.joined(separator: ",")
    updateMuteWordFilter()
  }

  private func removeMuteWord(_ word: String) {
    var words = muteWords
    words.removeAll { $0 == word }
    muteWordsString = words.joined(separator: ",")
    updateMuteWordFilter()
  }

  private func updateMuteWordFilter() {
    // Update the mute words filter in FeedFilterSettings
    let processor = MuteWordProcessor(muteWords: muteWords)
    appState.feedFilterSettings.updateMuteWordProcessor(processor)
  }
}
