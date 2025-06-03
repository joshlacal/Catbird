import SwiftUI
import Petrel
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

@MainActor
class LanguageManager: ObservableObject {
    @Published var isLoading = false
    @Published var error: String?
    @Published var recentlyUsedLanguages: [String] = []
    
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
    
    func syncLanguagePreferences(appLanguage: String?, primaryLanguage: String, contentLanguages: [String]) async {
        guard let preferencesManager = preferencesManager else {
            Self.logger.warning("PreferencesManager not available for language sync")
            return
        }
        
        isLoading = true
        error = nil
        
        do {
            // Update language preferences through PreferencesManager
            try await preferencesManager.updateLanguagePreferences(
                appLanguage: appLanguage,
                primaryLanguage: primaryLanguage,
                contentLanguages: contentLanguages
            )
            
            // Add primary language to recent if not system
            if let appLang = appLanguage, appLang != "system" {
                addToRecentLanguages(appLang)
            }
            addToRecentLanguages(primaryLanguage)
            
            Self.logger.info("Language preferences synced successfully")
            isLoading = false
        } catch {
            Self.logger.error("Failed to sync language preferences: \(error.localizedDescription)")
            self.error = "Failed to save language preferences"
            isLoading = false
        }
    }
}

struct LanguageSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var languageManager: LanguageManager?
    
    var body: some View {
        Form {
            // Header Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Language settings control both the app interface and content preferences.")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                    
                    if let detectedLanguage = Language.detectSystemLanguage() {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("System language detected: \(detectedLanguage.flag) \(detectedLanguage.englishName)")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
            }
            
            // Loading/Error State
            if let manager = languageManager {
                if manager.isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Saving language preferences...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                
                if let error = manager.error {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                            Text(error)
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            
            Section("App Language") {
                NavigationLink {
                    EnhancedLanguageSelectionView(
                        title: "App Language",
                        selectedLanguage: Binding(
                            get: { appState.appSettings.appLanguage },
                            set: { newValue in
                                appState.appSettings.appLanguage = newValue
                                
                                // Apply the language change immediately
                                Task { @MainActor in
                                    AppLanguageManager.shared.applyLanguage(newValue)
                                    
                                    await languageManager?.syncLanguagePreferences(
                                        appLanguage: newValue,
                                        primaryLanguage: appState.appSettings.primaryLanguage,
                                        contentLanguages: appState.appSettings.contentLanguages
                                    )
                                }
                            }
                        ),
                        allowSystemDefault: true,
                        recentLanguages: languageManager?.recentlyUsedLanguages ?? []
                    )
                } label: {
                    HStack {
                        Text("App Language")
                        Spacer()
                        HStack(spacing: 4) {
                            if appState.appSettings.appLanguage == "system" {
                                Image(systemName: "gear")
                                    .appFont(AppTextRole.caption)
                            } else if let lang = Language.allLanguages.first(where: { $0.id == appState.appSettings.appLanguage }) {
                                Text(lang.flag)
                            }
                            Text(languageDisplayName(forCode: appState.appSettings.appLanguage))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                
                Text("Controls the language used in menus and system messages.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Primary Language") {
                NavigationLink {
                    EnhancedLanguageSelectionView(
                        title: "Primary Language",
                        selectedLanguage: Binding(
                            get: { appState.appSettings.primaryLanguage },
                            set: { newValue in
                                appState.appSettings.primaryLanguage = newValue
                                // Ensure primary language is in content languages
                                if !appState.appSettings.contentLanguages.contains(newValue) {
                                    appState.appSettings.contentLanguages.append(newValue)
                                }
                                Task {
                                    await languageManager?.syncLanguagePreferences(
                                        appLanguage: appState.appSettings.appLanguage,
                                        primaryLanguage: newValue,
                                        contentLanguages: appState.appSettings.contentLanguages
                                    )
                                }
                            }
                        ),
                        allowSystemDefault: false,
                        recentLanguages: languageManager?.recentlyUsedLanguages ?? []
                    )
                } label: {
                    HStack {
                        Text("Primary Language")
                        Spacer()
                        HStack(spacing: 4) {
                            if let lang = Language.allLanguages.first(where: { $0.id == appState.appSettings.primaryLanguage }) {
                                Text(lang.flag)
                            }
                            Text(languageDisplayName(forCode: appState.appSettings.primaryLanguage))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                
                Text("Your preferred language for content. This is shared with other apps.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Content Languages") {
                NavigationLink {
                    EnhancedContentLanguagesView(
                        selectedLanguages: Binding(
                            get: { appState.appSettings.contentLanguages },
                            set: { newValue in
                                appState.appSettings.contentLanguages = newValue
                                Task {
                                    await languageManager?.syncLanguagePreferences(
                                        appLanguage: appState.appSettings.appLanguage,
                                        primaryLanguage: appState.appSettings.primaryLanguage,
                                        contentLanguages: newValue
                                    )
                                }
                            }
                        ),
                        primaryLanguage: appState.appSettings.primaryLanguage,
                        recentLanguages: languageManager?.recentlyUsedLanguages ?? []
                    )
                } label: {
                    HStack {
                        Text("Content Languages")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(appState.appSettings.contentLanguages.count) selected")
                                .foregroundStyle(.secondary)
                            if appState.appSettings.contentLanguages.count <= 3 {
                                HStack(spacing: 2) {
                                    ForEach(appState.appSettings.contentLanguages.prefix(3), id: \.self) { code in
                                        if let lang = Language.allLanguages.first(where: { $0.id == code }) {
                                            Text(lang.flag)
                                                .appFont(AppTextRole.caption2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                Text("Languages you'd like to see content in. Posts in other languages may be filtered out.")
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Languages")
        .navigationBarTitleDisplayMode(.inline)
        .appDisplayScale(appState: appState)
        .contrastAwareBackground(appState: appState, defaultColor: Color(.systemBackground))
        .onAppear {
            // Initialize language manager with proper preferences manager
            if languageManager == nil {
                languageManager = LanguageManager(preferencesManager: appState.preferencesManager)
            }
        }
    }
    
    private func languageDisplayName(forCode code: String) -> String {
        if code == "system" {
            if let detected = Language.detectSystemLanguage() {
                return "System (\(detected.englishName))"
            }
            return "System Default"
        }
        
        if let language = Language.allLanguages.first(where: { $0.id == code }) {
            return language.englishName
        }
        
        return code.uppercased()
    }
}

// MARK: - Enhanced Language Selection View

struct EnhancedLanguageSelectionView: View {
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
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search languages...")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
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
    }
}

// MARK: - Enhanced Content Languages View

struct EnhancedContentLanguagesView: View {
    @Binding var selectedLanguages: [String]
    let primaryLanguage: String
    let recentLanguages: [String]
    
    @State private var searchText = ""
    @State private var showingSelectAll = false
    @Environment(\.dismiss) private var dismiss
    
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
        NavigationStack {
            List {
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
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search languages...")
            .navigationTitle("Content Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .alert("Select All Languages?", isPresented: $showingSelectAll) {
            Button("Select All", role: .destructive) {
                selectedLanguages = Language.allLanguages.map { $0.id }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will show content in all \(Language.allLanguages.count) languages. This may include content you don't understand.")
        }
    }
    
    private func toggleLanguage(_ code: String) {
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
    NavigationStack {
        LanguageSettingsView()
            .environment(AppState.shared)
    }
}
