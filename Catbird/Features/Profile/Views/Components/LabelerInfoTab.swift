//
//  LabelerInfoTab.swift
//  Catbird
//
//  Created for labeler profile support
//

import SwiftUI
import Petrel

/// Canonical keys match the installed builtin renderer; raw records are never migrated.
enum ProfileLabelPreferenceAdapter {
    struct Selection {
        let visibility: ContentVisibility
        let usesLegacyRawKey: Bool
        let hasExplicitPreference: Bool
    }
    static func consumedKey(for raw: String) -> String {
        let value = raw.lowercased()
        switch value {
        case "nsfw", "porn", "sexual": return "nsfw"
        case "gore", "violence", "graphic", "graphic-media": return "graphic"
        case "nudity", "suggestive": return value
        default: return ContentLabels.contentWarningLabels.contains(value) ? value : raw
        }
    }
    static func selection(raw: String, labelerDID: DID, preferences: [ContentLabelPreference],
                          inheritedDefault: ContentVisibility = .warn) -> Selection {
        let key = consumedKey(for: raw)
        if let scoped = preferences.first(where: { $0.label == key && $0.labelerDid == labelerDID }) {
            return .init(visibility: ContentVisibility(fromPreference: scoped.visibility), usesLegacyRawKey: false, hasExplicitPreference: true)
        }
        if let global = preferences.first(where: { $0.label == key && $0.labelerDid == nil }) {
            return .init(visibility: ContentVisibility(fromPreference: global.visibility), usesLegacyRawKey: false, hasExplicitPreference: true)
        }
        if key != raw {
            let legacy = preferences.first { $0.label == raw && $0.labelerDid == labelerDID }
                ?? preferences.first { $0.label == raw && $0.labelerDid == nil }
            if let legacy {
                return .init(visibility: ContentVisibility(fromPreference: legacy.visibility), usesLegacyRawKey: true, hasExplicitPreference: true)
            }
        }
        return .init(visibility: inheritedDefault, usesLegacyRawKey: false, hasExplicitPreference: false)
    }
}

/// Tab view showing labeler information, policies, and label settings
struct LabelerInfoTab: View {
    let labelerDetails: AppBskyLabelerDefs.LabelerViewDetailed
    @Environment(AppState.self) private var appState
    @State private var loadRequest = UUID()
    @State private var rawFallbacks: Set<String> = []
    @State private var explicitPreferences: Set<String> = []
    @State private var labelPreferences: [String: ContentVisibility] = [:]
    @State private var isSaving = false
    @State private var hasConfirmedPreferences = false
    @State private var errorMessage: String?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Labeler description
                if let description = labelerDetails.creator.description, !description.isEmpty {
                    descriptionSection(description)
                }
                
                // Label settings
                labelSettingsSection
                
                if isSaving {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Saving…")
                            .appBody()
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }
                
                if let errorMessage = errorMessage {
                    Text(errorMessage)
                        .appCaption()
                        .foregroundStyle(.red)
                        .padding()
                    Button("Try Again") { Task { await loadLabelPreferences() } }
                        .disabled(isSaving)
                        .accessibilityIdentifier("profile.labeler.settings.retry")
                }
            }
            .padding()
        }
        .task(id: appState.userDID) {
            await loadLabelPreferences()
        }
    }
    
    @ViewBuilder
    private func descriptionSection(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            Text(description)
                .appBody()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.systemBackground)
        )
    }
    
    @ViewBuilder
    private var labelSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Label Settings")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            Text("Choose how content labeled by this service appears to you.")
                .appCaption()
                .foregroundStyle(.secondary)
            
            if labelerDetails.policies.labelValues.isEmpty {
                Text("This service doesn’t publish any labels.")
                    .appCaption()
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 16) {
                    ForEach(labelerDetails.policies.labelValues, id: \.self) { labelValue in
                        labelSettingControl(
                            identifier: labelValue.rawValue,
                            name: friendlyLabelName(labelValue.rawValue),
                            description: labelDescription(labelValue.rawValue)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.systemBackground)
        )
    }
    
    @ViewBuilder
    private func labelSettingControl(identifier: String, name: String, description: String) -> some View {
        LabelerContentVisibilitySelector(
            title: name,
            description: description,
            selection: Binding(
                get: { labelPreferences[identifier] ?? .warn },
                set: { newValue in
                    guard hasConfirmedPreferences, !isSaving,
                          rawFallbacks.contains(identifier) || !explicitPreferences.contains(identifier)
                            || newValue != labelPreferences[identifier] else { return }
                    let account = appState.userDID
                    let manager = appState.preferencesManager
                    let request = loadRequest
                    isSaving = true
                    Task {
                        await saveLabelPreference(identifier: identifier, visibility: newValue,
                                                  manager: manager, account: account, request: request)
                    }
                }
            )
        )
        .disabled(!hasConfirmedPreferences || isSaving)
        .accessibilityIdentifier("profile.labeler.setting.\(identifier)")
        if rawFallbacks.contains(identifier) {
            Text("This is an earlier stored choice. Changing it applies the shared content category setting for this service.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if ProfileLabelPreferenceAdapter.consumedKey(for: identifier) == "nsfw", !appState.isAdultContentEnabled {
            Text("Adult content is off. This choice is retained for when adult content is enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Helper Functions
    
    /// The labeler's own name and description for a label, in the user's language when available.
    private func localizedStrings(for labelKey: String) -> ComAtprotoLabelDefs.LabelValueDefinitionStrings? {
        guard let locales = labelerDetails.policies.labelValueDefinitions?
            .first(where: { $0.identifier == labelKey })?.locales, !locales.isEmpty else { return nil }
        func primaryLanguage(_ tag: String) -> String {
            String(tag.split(separator: "-").first ?? Substring(tag)).lowercased()
        }
        let preferred = primaryLanguage(Locale.preferredLanguages.first ?? "en")
        return locales.first { primaryLanguage($0.lang.languageTag) == preferred }
            ?? locales.first { primaryLanguage($0.lang.languageTag) == "en" }
            ?? locales.first
    }

    /// Converts label keys to user-friendly names
    private func friendlyLabelName(_ labelKey: String) -> String {
        if let name = localizedStrings(for: labelKey)?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        switch labelKey.lowercased() {
        case "nsfw", "porn":
            return "Adult Content"
        case "sexual":
            return "Sexual Content"
        case "suggestive":
            return "Sexually Suggestive"
        case "graphic", "gore":
            return "Graphic Content"
        case "violence":
            return "Violence"
        case "nudity":
            return "Non-Sexual Nudity"
        case "spam":
            return "Spam"
        case "misleading":
            return "Misleading"
        case "misinfo":
            return "Misinformation"
        case "hate":
            return "Hateful Content"
        case "harassment":
            return "Harassment"
        case "self-harm":
            return "Self-Harm"
        case "intolerant":
            return "Intolerance"
        default:
            // Fallback: capitalize and replace hyphens/underscores with spaces
            return labelKey.replacingOccurrences(of: "-", with: " ")
                          .replacingOccurrences(of: "_", with: " ")
                          .capitalized
        }
    }
    
    /// Provides descriptions for common labels
    private func labelDescription(_ labelKey: String) -> String {
        if let description = localizedStrings(for: labelKey)?.description.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return description
        }
        switch labelKey.lowercased() {
        case "nsfw", "porn":
            return "Explicit sexual images, videos, or text"
        case "sexual":
            return "Sexual content"
        case "suggestive":
            return "Sexualized content without explicit activity"
        case "graphic", "gore":
            return "Violence, blood, or injury"
        case "violence":
            return "Violent content"
        case "nudity":
            return "Artistic or educational nudity"
        case "spam":
            return "Unwanted promotional content"
        case "misleading":
            return "Potentially misleading information"
        case "misinfo":
            return "Misinformation or false claims"
        case "hate":
            return "Hateful or discriminatory content"
        case "harassment":
            return "Harassing behavior"
        case "self-harm":
            return "Content related to self-harm"
        case "intolerant":
            return "Intolerant views or behavior"
        default:
            return ""
        }
    }
    
    private func applyLabelPreferences(_ preferences: Preferences) {
        var values: [String: ContentVisibility] = [:]
        var fallbacks: Set<String> = []
        var explicit: Set<String> = []
        for labelValue in labelerDetails.policies.labelValues {
            let raw = labelValue.rawValue
            let definition = labelerDetails.policies.labelValueDefinitions?.first { $0.identifier == raw }
            let inherited: ContentVisibility = ContentLabels.contentWarningLabels.contains(raw.lowercased()) ? .warn
                : definition?.defaultSetting.map { ContentVisibility(fromPreference: $0) } ?? .show
            let selection = ProfileLabelPreferenceAdapter.selection(raw: raw, labelerDID: labelerDetails.creator.did,
                preferences: preferences.contentLabelPrefs, inheritedDefault: inherited)
            values[raw] = selection.visibility
            if selection.usesLegacyRawKey { fallbacks.insert(raw) }
            if selection.hasExplicitPreference { explicit.insert(raw) }
        }
        labelPreferences = values; rawFallbacks = fallbacks; explicitPreferences = explicit
    }

    private func loadLabelPreferences() async {
        let request = UUID(); loadRequest = request
        let account = appState.userDID; let manager = appState.preferencesManager
        hasConfirmedPreferences = false; errorMessage = nil; isSaving = false
        do {
            let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
            guard loadRequest == request, !Task.isCancelled, manager.accountDID == account, appState.userDID == account else { return }
            applyLabelPreferences(preferences)
            hasConfirmedPreferences = true
        } catch {
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            errorMessage = "Couldn’t load your label settings."
        }
    }

    private func saveLabelPreference(identifier: String, visibility: ContentVisibility,
                                     manager: PreferencesManager, account: String, request: UUID) async {
        defer { if loadRequest == request, manager.accountDID == account, appState.userDID == account { isSaving = false } }
        errorMessage = nil
        do {
            let key = ProfileLabelPreferenceAdapter.consumedKey(for: identifier)
            try await manager.setContentLabelVisibility(label: key, visibility: visibility.preferenceValue,
                labelerDid: labelerDetails.creator.did, expectedAccountDID: account)
            let preferences = try await manager.getPreferences()
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            // Re-read every alias from the accepted local snapshot so sibling controls stay truthful.
            applyLabelPreferences(preferences)
        } catch {
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            hasConfirmedPreferences = false
            errorMessage = "Couldn’t save that setting. Try again."
        }
    }

}

/// Content visibility selector component used for labeler label settings (renamed to avoid conflicts)
struct LabelerContentVisibilitySelector: View {
    let title: String
    let description: String
    @Binding var selection: ContentVisibility
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .appFont(AppTextRole.subheadline)
                    .fontWeight(.medium)
                
                if !description.isEmpty {
                    Text(description)
                        .appCaption()
                        .foregroundStyle(.secondary)
                }
            }
            
            Picker("Visibility", selection: $selection) {
                Text("Show").tag(ContentVisibility.show)
                Text("Warn").tag(ContentVisibility.warn)
                Text("Hide").tag(ContentVisibility.hide)
            }
            .pickerStyle(.segmented)
        }
    }
}
