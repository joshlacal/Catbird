import SwiftUI
import Petrel

struct LanguagePickerSheet: View {
  @Binding var selectedLanguages: [LanguageCodeContainer]
  @Environment(\.dismiss) private var dismiss

  @State private var searchText: String = ""

  private var allLanguageCodes: [String] {
    Locale.availableIdentifiers.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
  }

  private var uniqueCodes: [String] {
    Array(Set(allLanguageCodes)).sorted()
  }

  private var filtered: [String] {
    guard !searchText.isEmpty else { return uniqueCodes }
    return uniqueCodes.filter { code in
      let name = Locale.current.localizedString(forLanguageCode: code) ?? code
      return name.localizedCaseInsensitiveContains(searchText) || code.localizedCaseInsensitiveContains(searchText)
    }
  }

  var body: some View {
    NavigationStack {
      List(filtered, id: \.self) { code in
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        HStack {
          Text(name).appFont(AppTextRole.body)
          Spacer()
          if selectedLanguages.contains(where: { $0.lang.languageCode?.identifier == code }) {
            Image(systemName: "checkmark")
          }
        }
        .contentShape(Rectangle())
        .onTapGesture {
          toggle(code)
        }
      }
      .searchable(text: $searchText)
      .navigationTitle("Add Language")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "checkmark")
            }
        }
      }
    }
  }

  private func toggle(_ code: String) {
    if let idx = selectedLanguages.firstIndex(where: { $0.lang.languageCode?.identifier == code }) {
      selectedLanguages.remove(at: idx)
      // Save preference: clear if empty, otherwise save first language
      if selectedLanguages.isEmpty {
        UserDefaults.standard.removeObject(forKey: "defaultComposerLanguage")
      } else if let firstLang = selectedLanguages.first {
        let langCode = firstLang.lang.languageCode?.identifier ?? firstLang.lang.minimalIdentifier
        UserDefaults.standard.set(langCode, forKey: "defaultComposerLanguage")
      }
    } else {
      selectedLanguages.append(LanguageCodeContainer(languageCode: code))
      // Save the newly added language as default preference
      UserDefaults.standard.set(code, forKey: "defaultComposerLanguage")
    }
  }
}

