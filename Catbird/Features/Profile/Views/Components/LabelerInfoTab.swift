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
    @State private var loadRequest = UUID()
    /// The account this tab last confirmed its preferences for with the server.
    @State private var confirmedAccountDID: String?
    @State private var isSaving = false
    @State private var pending: PendingLabelChoice?
    @State private var errorMessage: String?

    private var labelerDID: String { labelerDetails.creator.did.didString() }

    /// The moderation engine's preferences for this account, once confirmed by this tab.
    private var confirmedPrefs: ModerationPrefs? {
        let policy = appState.moderationPolicy
        guard confirmedAccountDID == appState.userDID, policy.isConfirmed,
              policy.accountDID == appState.userDID else { return nil }
        return policy.prefs
    }

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

            if let prefs = confirmedPrefs {
                labelRows(prefs)
            } else if errorMessage == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
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
    private func labelRows(_ prefs: ModerationPrefs) -> some View {
        let rows = LabelerLabelSettings.rows(
            labelValues: labelerDetails.policies.labelValues.map(\.rawValue),
            definitions: labelerDetails.policies.labelValueDefinitions ?? [],
            labelerDID: labelerDID, prefs: prefs)
        if rows.isEmpty {
            Text("This service doesn’t publish any labels you can configure.")
                .appCaption()
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(rows) { row in
                    LabelerLabelRowView(
                        row: row, pending: pending?.preference(for: row.identifier), isSaving: isSaving,
                        accessibilityID: "profile.labeler.setting.\(row.identifier)",
                        onSelect: { save(identifier: row.identifier, preference: $0) },
                        onReset: { reset(identifier: row.identifier) })
                }
            }
        }
    }

    // MARK: - Loading and saving

    private func loadLabelPreferences() async {
        let request = UUID(); loadRequest = request
        let account = appState.userDID; let manager = appState.preferencesManager
        if confirmedAccountDID != account { confirmedAccountDID = nil }
        errorMessage = nil; isSaving = false; pending = nil
        do {
            // A confirmed fetch rebuilds `appState.moderationPolicy` before it returns.
            _ = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
            guard loadRequest == request, !Task.isCancelled, manager.accountDID == account, appState.userDID == account else { return }
            confirmedAccountDID = account
        } catch {
            guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
            confirmedAccountDID = nil
            errorMessage = "Couldn’t load your label settings."
        }
    }

    /// Saves one choice for this service under the label's own identifier.
    private func save(identifier: String, preference: LabelPreference) {
        let write = LabelerLabelSettings.serviceWrite(
            identifier: identifier, preference: preference, labelerDID: labelerDetails.creator.did)
        edit(pending: PendingLabelChoice(identifier: identifier, preference: preference)) { manager, account in
            try await manager.updateContentLabelPreferences([write], expectedAccountDID: account)
        }
    }

    /// Removes this service's own choice for a label.
    private func reset(identifier: String) {
        let did = labelerDetails.creator.did
        edit { manager, account in
            try await manager.removeContentLabelOverride(label: identifier, labelerDid: did, expectedAccountDID: account)
        }
    }

    /// Runs one confirmed write. A confirmed write rebuilds `appState.moderationPolicy` before it returns.
    private func edit(
        pending choice: PendingLabelChoice? = nil,
        _ operation: @escaping @MainActor (PreferencesManager, String) async throws -> Void
    ) {
        guard confirmedPrefs != nil, !isSaving else { return }
        let account = appState.userDID
        let manager = appState.preferencesManager
        let request = loadRequest
        isSaving = true
        pending = choice
        errorMessage = nil
        Task { @MainActor in
            defer {
                if loadRequest == request, manager.accountDID == account, appState.userDID == account {
                    isSaving = false; pending = nil
                }
            }
            do {
                try await operation(manager, account)
            } catch {
                guard loadRequest == request, manager.accountDID == account, appState.userDID == account else { return }
                confirmedAccountDID = nil
                errorMessage = "Couldn’t save that setting. Try again."
            }
        }
    }
}
