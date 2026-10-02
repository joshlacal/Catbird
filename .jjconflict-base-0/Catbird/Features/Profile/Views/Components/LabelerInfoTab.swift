//
//  LabelerInfoTab.swift
//  Catbird
//
//  Created for labeler profile support
//

import SwiftUI
import Petrel

/// Tab view showing labeler information, policies, and label settings
struct LabelerInfoTab: View {
    let labelerDetails: AppBskyLabelerDefs.LabelerViewDetailed
    @Environment(AppState.self) private var appState
    @State private var labelPreferences: [String: ContentVisibility] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Labeler description
                if let description = labelerDetails.creator.description, !description.isEmpty {
                    descriptionSection(description)
                }
                
                // Policies section
                policiesSection
                
                // Available labels section
                labelsSection
                
                // Divider
                Divider()
                    .padding(.vertical, 8)
                
                // Label settings
                labelSettingsSection
                
                if isSaving {
                    HStack {
                        ProgressView()
                            .padding(.trailing, 8)
                        Text("Saving preferences...")
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
                }
            }
            .padding()
        }
        .task {
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
    private var policiesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Policies")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            if !labelerDetails.policies.labelValues.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(labelerDetails.policies.labelValues, id: \.self) { value in
                            Text(friendlyLabelName(value.rawValue))
                                .appCaption()
                                .fontWeight(.medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule()
                                        .fill(Color.blue.opacity(0.15))
                                )
                                .foregroundStyle(Color.blue)
                        }
                    }
                }
            } else {
                Text("No policies defined")
                    .appCaption()
                    .foregroundStyle(.secondary)
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
    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Labels")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            // Show simple label values if no detailed definitions available
            if !labelerDetails.policies.labelValues.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(labelerDetails.policies.labelValues, id: \.self) { labelValue in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(friendlyLabelName(labelValue.rawValue))
                                .appFont(AppTextRole.subheadline)
                                .fontWeight(.medium)
                            
                            let description = labelDescription(labelValue.rawValue)
                            if !description.isEmpty {
                                Text(description)
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            } else {
                Text("No labels available")
                    .appCaption()
                    .foregroundStyle(.secondary)
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
    private var labelSettingsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Label Settings")
                .appFont(AppTextRole.headline)
                .fontWeight(.semibold)
            
            Text("Configure how you want to see content labeled by this service")
                .appCaption()
                .foregroundStyle(.secondary)
            
            if !labelerDetails.policies.labelValues.isEmpty {
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
                    labelPreferences[identifier] = newValue
                    Task {
                        await saveLabelPreference(identifier: identifier, visibility: newValue)
                    }
                }
            )
        )
    }
    
    // MARK: - Helper Functions
    
    /// Converts label keys to user-friendly names
    private func friendlyLabelName(_ labelKey: String) -> String {
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
    
    private func loadLabelPreferences() async {
        do {
            let preferences = try await appState.preferencesManager.getPreferences()
            let labelerDid = labelerDetails.creator.did
            
            for labelValue in labelerDetails.policies.labelValues {
                let visibility = ContentFilterManager.getVisibilityForLabel(
                    label: labelValue.rawValue,
                    labelerDid: labelerDid,
                    preferences: preferences.contentLabelPrefs
                )
                await MainActor.run {
                    labelPreferences[labelValue.rawValue] = visibility
                }
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to load preferences: \(error.localizedDescription)"
            }
        }
    }
    
    private func saveLabelPreference(identifier: String, visibility: ContentVisibility) async {
        isSaving = true
        errorMessage = nil
        
        do {
            let labelerDid = labelerDetails.creator.did
            let preference = ContentLabelPreference(
                labelerDid: labelerDid,
                label: identifier,
                visibility: visibility.rawValue
            )
            
            // Get existing preferences
            let currentPrefs = try await appState.preferencesManager.getPreferences()
            var updatedPrefs = currentPrefs.contentLabelPrefs
            
            // Remove any existing preference for this labeler+label combination
            updatedPrefs.removeAll { pref in
                pref.labelerDid?.didString() == labelerDid.didString() && pref.label == identifier
            }
            
            // Add new preference
            updatedPrefs.append(preference)
            
            // Save to server
            try await appState.preferencesManager.updateContentLabelPreferences(updatedPrefs)
            
            await MainActor.run {
                isSaving = false
            }
        } catch {
            await MainActor.run {
                errorMessage = "Failed to save preference: \(error.localizedDescription)"
                isSaving = false
            }
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
