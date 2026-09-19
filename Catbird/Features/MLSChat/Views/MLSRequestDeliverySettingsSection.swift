import CatbirdMLSCore
import SwiftUI

struct MLSRequestDeliverySettingsSection: View {
  @Environment(AppState.self) private var appState
  @State private var enabled: Bool?
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    Section("Encrypted introductions on this device") {
      Toggle("Receive encrypted message requests", isOn: Binding(
        get: { enabled == true },
        set: { value in Task { await update(value) } }
      ))
      .disabled(busy)
      if busy { ProgressView("Updating request delivery…") }
      if enabled == nil {
        Text("Delivery is not confirmed for this device.").foregroundStyle(.secondary)
      }
      Text("Allow senders to encrypt one text introduction for this device. Accepting the request remains your choice.")
        .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red) }
    }
    .task(id: appState.userDID) { enabled = nil; await update(nil) }
  }

  @MainActor private func update(_ requested: Bool?) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    let account = appState.userDID
    do {
      guard let manager = await appState.getMLSConversationManager(), manager.currentUserDID == account,
            appState.userDID == account else { throw CancellationError() }
      if let requested { try await manager.setDirectRequestDeliveryEnabled(requested) }
      let acknowledged = try await manager.getDirectRequestDeliveryEnabled()
      guard appState.userDID == account, appState.mlsConversationManager === manager else { return }
      enabled = acknowledged
      error = nil
    } catch is CancellationError { } catch {
      guard appState.userDID == account else { return }
      enabled = nil
      self.error = "Could not confirm this device's request delivery setting. Please try again."
    }
  }
}
