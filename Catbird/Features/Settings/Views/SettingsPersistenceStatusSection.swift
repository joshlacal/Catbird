import SwiftUI

struct SettingsPersistenceStatusSection: View {
  let settings: AppSettings

  var body: some View {
    switch settings.persistenceState {
    case .unavailable:
      Section("Local Settings") {
        Text("Local settings are unavailable. Retry to load your saved choices. Other settings and support remain available.")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("SettingsPersistenceStatus")
        Button("Retry Loading") {
          settings.retryPersistence()
        }
        .accessibilityIdentifier("SettingsPersistenceRetry")
      }
    case .saveFailed:
      Section {
        Text("Your changes weren’t saved. Your previous settings remain active. Retry Saving to apply the pending changes shown below.")
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("SettingsPersistenceStatus")
        Text(settings.pendingChangesDescription)
          .accessibilityIdentifier("SettingsPersistencePendingChanges")
        Button("Retry Saving") {
          settings.retryPersistence()
        }
        .accessibilityIdentifier("SettingsPersistenceRetry")
      } header: {
        Text("Local Settings")
      } footer: {
        Text("Save pending changes before switching accounts or closing the app.")
      }
    case .ready, .saving:
      EmptyView()
    }
  }
}
