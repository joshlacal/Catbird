import SwiftUI
import Petrel

struct LanguagePickerSheet: View {
  @Binding var selectedLanguages: [LanguageCodeContainer]
  @Environment(\.dismiss) private var dismiss
  @Environment(\.locale) private var locale

  @State private var searchText: String = ""

  /// Bluesky accepts at most three languages per post.
  static let maxLanguages = 3

  private struct LanguageOption: Identifiable {
    let code: String
    let name: String
    var id: String { code }
  }

  /// Unique ISO language codes known to the system.
  private static let languageCodes: [String] = Array(
    Set(
      Locale.availableIdentifiers.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
    )
  )

  /// Every language the system knows, sorted by its name in the active locale.
  private var languages: [LanguageOption] {
    Self.languageCodes
      .map { LanguageOption(code: $0, name: locale.localizedString(forLanguageCode: $0) ?? $0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private var filtered: [LanguageOption] {
    let allLanguages = languages
    guard !searchText.isEmpty else { return allLanguages }
    return allLanguages.filter { language in
      language.name.localizedCaseInsensitiveContains(searchText)
        || language.code.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var isAtLimit: Bool {
    selectedLanguages.count >= Self.maxLanguages
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(filtered) { language in
            let selected = isSelected(language.code)
            Button {
              toggle(language.code)
            } label: {
              HStack {
                Text(language.name)
                  .appFont(AppTextRole.body)
                  .foregroundStyle(Color.primary)
                Spacer()
                if selected {
                  Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                }
              }
              .contentShape(Rectangle())
            }
            .disabled(!selected && isAtLimit)
            .accessibilityAddTraits(selected ? .isSelected : [])
          }
        } footer: {
          Text("You can choose up to \(Self.maxLanguages) languages.", comment: "Footer in post language picker explaining maximum selectable languages")
        }

        if !selectedLanguages.isEmpty {
          Section {
            Button("Use as Default for New Posts") {
              saveDefaultLanguage()
            }
          }
        }
      }
      .searchable(text: $searchText)
      .navigationTitle("Post Languages")
      .platformInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }

  private func isSelected(_ code: String) -> Bool {
    selectedLanguages.contains(where: { $0.lang.languageCode?.identifier == code })
  }

  private func toggle(_ code: String) {
    if let idx = selectedLanguages.firstIndex(where: { $0.lang.languageCode?.identifier == code }) {
      selectedLanguages.remove(at: idx)
    } else if !isAtLimit {
      selectedLanguages.append(LanguageCodeContainer(languageCode: code))
    }
  }

  /// Only this explicit action changes the default; picking languages for one post doesn't.
  private func saveDefaultLanguage() {
    guard let first = selectedLanguages.first else { return }
    let code = first.lang.languageCode?.identifier ?? first.lang.minimalIdentifier
    UserDefaults.standard.set(code, forKey: "defaultComposerLanguage")
    dismiss()
  }
}


#Preview("LanguagePickerSheet") {
  NavigationStack {
    LanguagePickerSheet(selectedLanguages: .constant([]))
  }
}
