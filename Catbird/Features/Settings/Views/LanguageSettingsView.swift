import SwiftUI
import OSLog

// MARK: - Language Model

struct Language: Identifiable, Hashable, Codable {
    let id: String // ISO 639-1 code
    let englishName: String
    let nativeName: String
    let flag: String
    let rtl: Bool // Right-to-left language
    
    // Logger is not included in Codable/Hashable
    private static let logger = Logger(subsystem: "blue.catbird", category: "LanguageSettings")
    
    var displayName: String {
        if englishName == nativeName {
            return englishName
        }
        return "\(englishName) - \(nativeName)"
    }
    
    // Common languages sorted by global usage
    static let allLanguages: [Language] = [
        Language(id: "en", englishName: "English", nativeName: "English", flag: "🇺🇸", rtl: false),
        Language(id: "zh", englishName: "Chinese (Simplified)", nativeName: "简体中文", flag: "🇨🇳", rtl: false),
        Language(id: "zh-TW", englishName: "Chinese (Traditional)", nativeName: "繁體中文", flag: "🇹🇼", rtl: false),
        Language(id: "es", englishName: "Spanish", nativeName: "Español", flag: "🇪🇸", rtl: false),
        Language(id: "hi", englishName: "Hindi", nativeName: "हिन्दी", flag: "🇮🇳", rtl: false),
        Language(id: "ar", englishName: "Arabic", nativeName: "العربية", flag: "🇸🇦", rtl: true),
        Language(id: "bn", englishName: "Bengali", nativeName: "বাংলা", flag: "🇧🇩", rtl: false),
        Language(id: "pt", englishName: "Portuguese", nativeName: "Português", flag: "🇵🇹", rtl: false),
        Language(id: "pt-BR", englishName: "Portuguese (Brazil)", nativeName: "Português (Brasil)", flag: "🇧🇷", rtl: false),
        Language(id: "ru", englishName: "Russian", nativeName: "Русский", flag: "🇷🇺", rtl: false),
        Language(id: "ja", englishName: "Japanese", nativeName: "日本語", flag: "🇯🇵", rtl: false),
        Language(id: "pa", englishName: "Punjabi", nativeName: "ਪੰਜਾਬੀ", flag: "🇮🇳", rtl: false),
        Language(id: "de", englishName: "German", nativeName: "Deutsch", flag: "🇩🇪", rtl: false),
        Language(id: "jv", englishName: "Javanese", nativeName: "Basa Jawa", flag: "🇮🇩", rtl: false),
        Language(id: "ko", englishName: "Korean", nativeName: "한국어", flag: "🇰🇷", rtl: false),
        Language(id: "fr", englishName: "French", nativeName: "Français", flag: "🇫🇷", rtl: false),
        Language(id: "te", englishName: "Telugu", nativeName: "తెలుగు", flag: "🇮🇳", rtl: false),
        Language(id: "mr", englishName: "Marathi", nativeName: "मराठी", flag: "🇮🇳", rtl: false),
        Language(id: "tr", englishName: "Turkish", nativeName: "Türkçe", flag: "🇹🇷", rtl: false),
        Language(id: "ta", englishName: "Tamil", nativeName: "தமிழ்", flag: "🇮🇳", rtl: false),
        Language(id: "vi", englishName: "Vietnamese", nativeName: "Tiếng Việt", flag: "🇻🇳", rtl: false),
        Language(id: "ur", englishName: "Urdu", nativeName: "اردو", flag: "🇵🇰", rtl: true),
        Language(id: "it", englishName: "Italian", nativeName: "Italiano", flag: "🇮🇹", rtl: false),
        Language(id: "th", englishName: "Thai", nativeName: "ไทย", flag: "🇹🇭", rtl: false),
        Language(id: "gu", englishName: "Gujarati", nativeName: "ગુજરાતી", flag: "🇮🇳", rtl: false),
        Language(id: "fa", englishName: "Persian", nativeName: "فارسی", flag: "🇮🇷", rtl: true),
        Language(id: "pl", englishName: "Polish", nativeName: "Polski", flag: "🇵🇱", rtl: false),
        Language(id: "uk", englishName: "Ukrainian", nativeName: "Українська", flag: "🇺🇦", rtl: false),
        Language(id: "ml", englishName: "Malayalam", nativeName: "മലയാളം", flag: "🇮🇳", rtl: false),
        Language(id: "kn", englishName: "Kannada", nativeName: "ಕನ್ನಡ", flag: "🇮🇳", rtl: false),
        Language(id: "or", englishName: "Odia", nativeName: "ଓଡ଼ିଆ", flag: "🇮🇳", rtl: false),
        Language(id: "my", englishName: "Burmese", nativeName: "မြန်မာ", flag: "🇲🇲", rtl: false),
        Language(id: "ne", englishName: "Nepali", nativeName: "नेपाली", flag: "🇳🇵", rtl: false),
        Language(id: "si", englishName: "Sinhala", nativeName: "සිංහල", flag: "🇱🇰", rtl: false),
        Language(id: "km", englishName: "Khmer", nativeName: "ភាសាខ្មែរ", flag: "🇰🇭", rtl: false),
        Language(id: "nl", englishName: "Dutch", nativeName: "Nederlands", flag: "🇳🇱", rtl: false),
        Language(id: "sv", englishName: "Swedish", nativeName: "Svenska", flag: "🇸🇪", rtl: false),
        Language(id: "da", englishName: "Danish", nativeName: "Dansk", flag: "🇩🇰", rtl: false),
        Language(id: "fi", englishName: "Finnish", nativeName: "Suomi", flag: "🇫🇮", rtl: false),
        Language(id: "no", englishName: "Norwegian", nativeName: "Norsk", flag: "🇳🇴", rtl: false),
        Language(id: "he", englishName: "Hebrew", nativeName: "עברית", flag: "🇮🇱", rtl: true),
        Language(id: "el", englishName: "Greek", nativeName: "Ελληνικά", flag: "🇬🇷", rtl: false),
        Language(id: "ro", englishName: "Romanian", nativeName: "Română", flag: "🇷🇴", rtl: false),
        Language(id: "hu", englishName: "Hungarian", nativeName: "Magyar", flag: "🇭🇺", rtl: false),
        Language(id: "cs", englishName: "Czech", nativeName: "Čeština", flag: "🇨🇿", rtl: false),
        Language(id: "bg", englishName: "Bulgarian", nativeName: "Български", flag: "🇧🇬", rtl: false),
        Language(id: "sk", englishName: "Slovak", nativeName: "Slovenčina", flag: "🇸🇰", rtl: false),
        Language(id: "hr", englishName: "Croatian", nativeName: "Hrvatski", flag: "🇭🇷", rtl: false),
        Language(id: "sr", englishName: "Serbian", nativeName: "Српски", flag: "🇷🇸", rtl: false),
        Language(id: "ca", englishName: "Catalan", nativeName: "Català", flag: "🇪🇸", rtl: false),
        Language(id: "eu", englishName: "Basque", nativeName: "Euskara", flag: "🇪🇸", rtl: false),
        Language(id: "gl", englishName: "Galician", nativeName: "Galego", flag: "🇪🇸", rtl: false),
        Language(id: "et", englishName: "Estonian", nativeName: "Eesti", flag: "🇪🇪", rtl: false),
        Language(id: "lv", englishName: "Latvian", nativeName: "Latviešu", flag: "🇱🇻", rtl: false),
        Language(id: "lt", englishName: "Lithuanian", nativeName: "Lietuvių", flag: "🇱🇹", rtl: false),
        Language(id: "sl", englishName: "Slovenian", nativeName: "Slovenščina", flag: "🇸🇮", rtl: false),
        Language(id: "mk", englishName: "Macedonian", nativeName: "Македонски", flag: "🇲🇰", rtl: false),
        Language(id: "sq", englishName: "Albanian", nativeName: "Shqip", flag: "🇦🇱", rtl: false),
        Language(id: "is", englishName: "Icelandic", nativeName: "Íslenska", flag: "🇮🇸", rtl: false),
        Language(id: "ga", englishName: "Irish", nativeName: "Gaeilge", flag: "🇮🇪", rtl: false),
        Language(id: "cy", englishName: "Welsh", nativeName: "Cymraeg", flag: "🏴󠁧󠁢󠁷󠁬󠁳󠁿", rtl: false),
        Language(id: "eo", englishName: "Esperanto", nativeName: "Esperanto", flag: "🌍", rtl: false)
    ]
    
    static func detectSystemLanguage() -> Language? {
        let preferredLanguages = Locale.preferredLanguages
        guard let languageCode = preferredLanguages.first?.split(separator: "-").first else {
            return nil
        }
        
        let code = String(languageCode).lowercased()
        return allLanguages.first { $0.id == code } ?? allLanguages.first { $0.id == "en" }
    }
}

// MARK: - Language Manager

@Observable
@MainActor
class LanguageManager {
    var isLoading = false
    var error: String?
    var recentlyUsedLanguages: [String] = []
    
    private let preferencesManager: PreferencesManager?
    private let maxRecentLanguages = 5
    private static let logger = Logger(subsystem: "blue.catbird", category: "LanguageManager")
    
    init(preferencesManager: PreferencesManager?) {
        self.preferencesManager = preferencesManager
        loadRecentLanguages()
    }
    
    private func loadRecentLanguages() {
        if let data = UserDefaults.standard.data(forKey: "recentLanguages"),
           let languages = try? JSONDecoder().decode([String].self, from: data) {
            recentlyUsedLanguages = languages
        }
    }
    
    private func saveRecentLanguages() {
        if let data = try? JSONEncoder().encode(recentlyUsedLanguages) {
            UserDefaults.standard.set(data, forKey: "recentLanguages")
        }
    }
    
    func addToRecentLanguages(_ languageCode: String) {
        // Remove if already exists
        recentlyUsedLanguages.removeAll { $0 == languageCode }
        
        // Add to front
        recentlyUsedLanguages.insert(languageCode, at: 0)
        
        // Keep only max recent
        if recentlyUsedLanguages.count > maxRecentLanguages {
            recentlyUsedLanguages = Array(recentlyUsedLanguages.prefix(maxRecentLanguages))
        }
        
        saveRecentLanguages()
    }
    
    func syncReadingLanguagePreferences(primaryLanguage: String, contentLanguages: [String], expectedAccountDID: String) async {
        guard let preferencesManager else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            try await preferencesManager.updateReadingLanguagePreferences(primaryLanguage: primaryLanguage,
                contentLanguages: contentLanguages, expectedAccountDID: expectedAccountDID)
            addToRecentLanguages(primaryLanguage)
        } catch {
            self.error = "Your reading languages are saved in Catbird, but couldn’t be applied everywhere. Try again."
            Self.logger.error("Local reading-language publication failed: \(error.localizedDescription)")
        }
    }

    private enum ReadingLanguageRetryError: Error { case changedOrUnavailable }

    func retryConfirmedReadingLanguages(in appState: AppState,
        expected: AppSettings.ConfirmedReadingLanguages, accountContextRevision: UInt64) async {
        guard !isLoading, let preferencesManager else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await appState.performSettingsAccountOperation {
                let owner = AppStateManager.shared
                guard owner.lifecycle.appState === appState,
                      owner.lifecycle.userDID == expected.accountDID,
                      owner.settingsAccountContextRevision == accountContextRevision,
                      appState.userDID == expected.accountDID,
                      appState.preferencesManager === preferencesManager,
                      appState.appSettings.confirmedReadingLanguages(for: expected.accountDID) == expected
                else { throw ReadingLanguageRetryError.changedOrUnavailable }
                try await preferencesManager.updateReadingLanguagePreferences(primaryLanguage: expected.primaryLanguage,
                    contentLanguages: expected.contentLanguages, expectedAccountDID: expected.accountDID)
                self.addToRecentLanguages(expected.primaryLanguage)
                self.error = nil
            }
        } catch {
            // Refusal must leave the existing compatibility error available for a later Retry.
            self.error = self.error ?? "Your reading languages are saved in Catbird, but couldn’t be applied everywhere. Try again."
            Self.logger.error("Confirmed reading-language Retry did not complete: \(error.localizedDescription)")
        }
    }

}

struct LanguageSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var languageManager: LanguageManager?
    @State private var interfaceLanguage = "system"
    @State private var confirmsShowingAllLanguages = false
    var initialFocus: SettingsControlID? = nil
    var interfacePreferences = InterfaceLanguagePreferences()

    private var canEdit: Bool { appState.appSettings.canEditPersistedSettings }
    private var canRetryReadingLanguages: Bool {
        languageManager?.isLoading != true
            && appState.appSettings.confirmedReadingLanguages(for: appState.userDID) != nil
    }

    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            // Only offer an interface language choice when Catbird ships more than one translation.
            if InterfaceLanguagePreferences.availableLanguages().count > 1 {
                Section {
                    NavigationLink {
                        InterfaceLanguageSelectionView(selectedLanguage: $interfaceLanguage, preferences: interfacePreferences)
                    } label: {
                        SettingsNavigationRow(title: "Interface Language", summary: languageName(interfaceLanguage), systemImage: "globe", family: .language)
                    }
                    .settingsControl(.init(rawValue: "languages.interface"))
                } header: { Text("This Device") } footer: {
                    Text("Menu language applies to every account on this device. Available choices reflect the translations included in Catbird. Some interface text may remain in English.")
                }
            }

            SettingsPersistenceStatusSection(settings: appState.appSettings)
            if let error = languageManager?.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") {
                        let capturedState = appState
                        guard let manager = languageManager,
                              let confirmed = capturedState.appSettings.confirmedReadingLanguages(for: capturedState.userDID)
                        else { return }
                        let revision = AppStateManager.shared.settingsAccountContextRevision
                        Task { @MainActor in
                            await manager.retryConfirmedReadingLanguages(in: capturedState, expected: confirmed,
                                accountContextRevision: revision)
                        }
                    }
                    .disabled(!canRetryReadingLanguages)
                }
            }
            Section {
                NavigationLink {
                    EnhancedLanguageSelectionView(title: "Primary Reading Language", selectedLanguage: Binding(
                        get: { appState.appSettings.primaryLanguage },
                        set: { value in
                            guard canEdit else { return }
                            appState.appSettings.primaryLanguage = value
                            if !appState.appSettings.contentLanguages.contains(value) {
                                appState.appSettings.contentLanguages.append(value)
                            }
                            applyReadingLanguagesAfterSaving()
                        }), allowSystemDefault: false, recentLanguages: languageManager?.recentlyUsedLanguages ?? [])
                } label: {
                    SettingsNavigationRow(title: "Primary Reading Language", summary: languageName(appState.appSettings.primaryLanguage), systemImage: "text.book.closed", family: .language)
                }
                .settingsControl(.init(rawValue: "languages.primary"))
                NavigationLink {
                    EnhancedContentLanguagesView(selectedLanguages: Binding(
                        get: { appState.appSettings.contentLanguages },
                        set: { value in
                            guard canEdit else { return }
                            appState.appSettings.contentLanguages = value
                            applyReadingLanguagesAfterSaving()
                        }), primaryLanguage: appState.appSettings.primaryLanguage, recentLanguages: languageManager?.recentlyUsedLanguages ?? [])
                } label: {
                    SettingsNavigationRow(title: "Preferred Reading Languages", summary: appState.appSettings.contentLanguages.map(languageName).joined(separator: ", "), systemImage: "character.bubble", family: .language)
                }
                .settingsControl(.init(rawValue: "languages.content"))
                Toggle("Hide Posts in Other Languages", isOn: Binding(
                    get: { appState.appSettings.hideNonPreferredLanguages || appState.feedFilterSettings.isFilterEnabled(name: "Filter by Language") },
                    set: { value in
                        if value { appState.appSettings.hideNonPreferredLanguages = true }
                        else { confirmsShowingAllLanguages = true }
                    }))
                    .settingsControl(.init(rawValue: "languages.hideOtherLanguages"))
                Toggle("Show Language Indicators", isOn: Binding(
                    get: { appState.appSettings.showLanguageIndicators },
                    set: { appState.appSettings.showLanguageIndicators = $0 }))
                    .settingsControl(.init(rawValue: "languages.indicators"))
            } header: { Text("This Account in Catbird") } footer: {
                Text("Hide posts in languages you haven’t selected. Posts with no language are always shown. Indicators mark posts outside your reading languages. These choices are stored in Catbird on this device and don’t change other Bluesky apps.")
            }
            .disabled(!canEdit)
        }
        .navigationTitle("Language")
        .confirmationDialog("Show Posts in All Languages?", isPresented: $confirmsShowingAllLanguages, titleVisibility: .visible) {
            Button("Show All Languages") { showAllReadingLanguages() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Posts in every language will appear. Your preferred reading languages are kept.")
        }
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
        .onAppear {
            interfaceLanguage = interfacePreferences.selectedLanguage
            if languageManager == nil { languageManager = LanguageManager(preferencesManager: appState.preferencesManager) }
        }
        .onChange(of: appState.userDID) { _, _ in
            languageManager = LanguageManager(preferencesManager: appState.preferencesManager)
            confirmsShowingAllLanguages = false
            interfaceLanguage = interfacePreferences.selectedLanguage
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AppLanguageDidChange"))) { _ in
            interfaceLanguage = interfacePreferences.selectedLanguage
        }
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    private func showAllReadingLanguages() {
        guard canEdit else { return }
        let capturedState = appState
        let capturedDID = appState.userDID
        appState.appSettings.hideNonPreferredLanguages = false
        appState.appSettings.afterPendingSave(key: "language-filter", description: "Show posts in all reading languages") { @MainActor in
            guard AppStateManager.shared.lifecycle.appState === capturedState,
                  AppStateManager.shared.lifecycle.userDID == capturedDID else { return }
            capturedState.feedFilterSettings.setFilter(id: "Filter by Language", enabled: false)
        }
    }

    private func applyReadingLanguagesAfterSaving() {
        let capturedState = appState
        let capturedDID = appState.userDID
        let manager = languageManager
        appState.appSettings.afterPendingSave(key: "language") { @MainActor in
            guard AppStateManager.shared.lifecycle.appState === capturedState,
                  AppStateManager.shared.lifecycle.userDID == capturedDID else { return }
            await manager?.syncReadingLanguagePreferences(primaryLanguage: capturedState.appSettings.primaryLanguage,
                contentLanguages: capturedState.appSettings.contentLanguages, expectedAccountDID: capturedDID)
        }
    }

    private func languageName(_ code: String) -> String {
        if code == "system" { return "System Default" }
        return Language.allLanguages.first { $0.id == code }?.englishName
            ?? Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

struct InterfaceLanguageSelectionView: View {
    @Binding var selectedLanguage: String
    let preferences: InterfaceLanguagePreferences
    private var available: [String] { InterfaceLanguagePreferences.availableLanguages() }

    var body: some View {
        Form {
            Section {
                languageRow("system", title: "System Default")
                ForEach(available, id: \.self) { code in
                    languageRow(code, title: Locale.current.localizedString(forIdentifier: code) ?? code)
                }
            } footer: {
                Text("Applies to every account on this device. Only translations included in this build are offered.")
            }
            if selectedLanguage != "system" && !available.contains(selectedLanguage) {
                Section {
                    LabeledContent("Current language", value: Locale.current.localizedString(forIdentifier: selectedLanguage) ?? selectedLanguage)
                } header: {
                    Text("Saved Selection")
                } footer: {
                    Text("This saved selection is kept. Its translation is not included in this build, so unavailable text uses the default language. Choose System Default or an available translation to change it.")
                }
            }
        }
        .navigationTitle("Interface Language")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }

    private func languageRow(_ code: String, title: String) -> some View {
        Button {
            preferences.select(code)
            selectedLanguage = code
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if selectedLanguage == code { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }
        .accessibilityAddTraits(selectedLanguage == code ? .isSelected : [])
    }
}

// MARK: - Enhanced Language Selection View

struct EnhancedLanguageSelectionView: View {
    @Environment(AppState.self) private var appState
    let title: String
    @Binding var selectedLanguage: String
    let allowSystemDefault: Bool
    let recentLanguages: [String]
    
    @State private var searchText = ""
    @State private var showAllLanguages = false
    
    private var systemOption: (id: String, display: String, flag: String)? {
        guard allowSystemDefault else { return nil }
        if let detected = Language.detectSystemLanguage() {
            return ("system", "System (\(detected.englishName))", "⚙️")
        }
        return ("system", "System Default", "⚙️")
    }
    
    private var filteredLanguages: [Language] {
        if searchText.isEmpty {
            return Language.allLanguages
        }
        
        let search = searchText.lowercased()
        return Language.allLanguages.filter { lang in
            lang.englishName.lowercased().contains(search) ||
            lang.nativeName.lowercased().contains(search) ||
            lang.id.lowercased().contains(search)
        }
    }
    
    private var recentLanguageObjects: [Language] {
        recentLanguages.compactMap { code in
            Language.allLanguages.first { $0.id == code }
        }
    }
    
    private var popularLanguages: [Language] {
        // Top 10 most spoken languages
        let popularCodes = ["en", "zh", "es", "hi", "ar", "pt", "ja", "de", "fr", "ko"]
        return popularCodes.compactMap { code in
            Language.allLanguages.first { $0.id == code }
        }
    }
    
    var body: some View {
        List {
            SettingsPersistenceStatusSection(settings: appState.appSettings)

            // System Default Option
            if let system = systemOption {
                Section {
                    Button {
                        selectedLanguage = system.id
                    } label: {
                        HStack {
                            Text(system.flag)
                            Text(system.display)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selectedLanguage == system.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .disabled(!appState.appSettings.canEditPersistedSettings)
                }
            }
            
            // Recently Used Languages
            if !recentLanguageObjects.isEmpty && searchText.isEmpty {
                Section("Recently Used") {
                    ForEach(recentLanguageObjects) { language in
                        LanguageRow(
                            language: language,
                            isSelected: selectedLanguage == language.id,
                            onSelect: { selectedLanguage = language.id }
                        )
                        .disabled(!appState.appSettings.canEditPersistedSettings)
                    }
                }
            }
            
            // Popular Languages or All Languages
            if searchText.isEmpty && !showAllLanguages {
                Section("Popular Languages") {
                    ForEach(popularLanguages) { language in
                        LanguageRow(
                            language: language,
                            isSelected: selectedLanguage == language.id,
                            onSelect: { selectedLanguage = language.id }
                        )
                        .disabled(!appState.appSettings.canEditPersistedSettings)
                    }
                    
                    Button {
                        withAnimation {
                            showAllLanguages = true
                        }
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                                .foregroundStyle(.blue)
                            Text("Show All Languages")
                                .foregroundStyle(.blue)
                        }
                    }
                }
            } else {
                Section(searchText.isEmpty ? "All Languages" : "Search Results") {
                    ForEach(filteredLanguages) { language in
                        LanguageRow(
                            language: language,
                            isSelected: selectedLanguage == language.id,
                            onSelect: { selectedLanguage = language.id }
                        )
                        .disabled(!appState.appSettings.canEditPersistedSettings)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search languages")
        .navigationTitle(title)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    }
}

struct LanguageRow: View {
    let language: Language
    let isSelected: Bool
    let onSelect: () -> Void
    
    var body: some View {
        Button(action: onSelect) {
            HStack {
                Text(language.flag)
                    .appFont(AppTextRole.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.englishName)
                        .foregroundStyle(.primary)
                    if language.englishName != language.nativeName {
                        Text(language.nativeName)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                        .fontWeight(.semibold)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Enhanced Content Languages View

struct EnhancedContentLanguagesView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedLanguages: [String]
    let primaryLanguage: String
    let recentLanguages: [String]
    
    @State private var searchText = ""
    
    private var filteredLanguages: [Language] {
        if searchText.isEmpty {
            return Language.allLanguages
        }
        
        let search = searchText.lowercased()
        return Language.allLanguages.filter { lang in
            lang.englishName.lowercased().contains(search) ||
            lang.nativeName.lowercased().contains(search) ||
            lang.id.lowercased().contains(search)
        }
    }
    
    private var selectedLanguageObjects: [Language] {
        selectedLanguages.compactMap { code in
            Language.allLanguages.first { $0.id == code }
        }
    }
    
    private var suggestedLanguages: [Language] {
        var suggestions: [Language] = []
        
        // Add primary language if not selected
        if let primary = Language.allLanguages.first(where: { $0.id == primaryLanguage }),
           !selectedLanguages.contains(primaryLanguage) {
            suggestions.append(primary)
        }
        
        // Add recent languages not selected
        for code in recentLanguages {
            if !selectedLanguages.contains(code),
               let lang = Language.allLanguages.first(where: { $0.id == code }) {
                suggestions.append(lang)
            }
        }
        
        return suggestions
    }
    
    var body: some View {
        List {
            SettingsPersistenceStatusSection(settings: appState.appSettings)

            // Selected Languages Summary
            if !selectedLanguageObjects.isEmpty && searchText.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Languages (\(selectedLanguageObjects.count))")
                            .appFont(AppTextRole.headline)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(selectedLanguageObjects) { language in
                                    HStack(spacing: 4) {
                                        Text(language.flag)
                                        Text(language.englishName)
                                            .appFont(AppTextRole.caption)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.blue.opacity(0.1))
                                    .clipShape(Capsule())
                                }
                            }
                        }
                    }
                }
            }
            
            // Suggested Languages
            if !suggestedLanguages.isEmpty && searchText.isEmpty {
                Section("Suggested") {
                    ForEach(suggestedLanguages) { language in
                        ContentLanguageRow(
                            language: language,
                            isSelected: selectedLanguages.contains(language.id),
                            isPrimary: language.id == primaryLanguage,
                            onToggle: { toggleLanguage(language.id) }
                        )
                        .disabled(!appState.appSettings.canEditPersistedSettings)
                    }
                }
            }
            
            // All Languages
            Section(searchText.isEmpty ? "All Languages" : "Search Results") {
                ForEach(filteredLanguages) { language in
                    ContentLanguageRow(
                        language: language,
                        isSelected: selectedLanguages.contains(language.id),
                        isPrimary: language.id == primaryLanguage,
                        onToggle: { toggleLanguage(language.id) }
                    )
                    .disabled(!appState.appSettings.canEditPersistedSettings)
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search languages")
        .navigationTitle("Preferred Reading Languages")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
    
    private func toggleLanguage(_ code: String) {
        guard appState.appSettings.canEditPersistedSettings else { return }
        if selectedLanguages.contains(code) {
            // Don't allow removing the primary language or last language
            if code == primaryLanguage {
                return
            }
            if selectedLanguages.count > 1 {
                selectedLanguages.removeAll { $0 == code }
            }
        } else {
            selectedLanguages.append(code)
        }
    }
}

struct ContentLanguageRow: View {
    let language: Language
    let isSelected: Bool
    let isPrimary: Bool
    let onToggle: () -> Void
    
    var body: some View {
        Button(action: onToggle) {
            HStack {
                Text(language.flag)
                    .appFont(AppTextRole.title3)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(language.englishName)
                            .foregroundStyle(.primary)
                        if isPrimary {
                            Text("Primary")
                                .appFont(AppTextRole.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    if language.englishName != language.nativeName {
                        Text(language.nativeName)
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .appFont(AppTextRole.title3)
            }
        }
        .contentShape(Rectangle())
        .disabled(isPrimary && isSelected) // Can't deselect primary language
    }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
            LanguageSettingsView()
        }
  }
}
