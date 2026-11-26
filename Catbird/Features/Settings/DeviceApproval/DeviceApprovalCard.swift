import CatbirdMLSCore
import SwiftUI

// MARK: - Device Approval Card

/// Says, at the top of Messages, what stands between this device and encrypted chat, or
/// which of the account's devices wait for this one to approve them.
///
/// The list that hosts the card applies `DeviceApprovalTracking` with the same model, which
/// loads the state and presents the screens the card opens, so they outlive the card.
struct DeviceApprovalCard: View {
  @Environment(AppState.self) private var appState
  let model: DeviceApprovalModel

  var body: some View {
    if let copy = model.copy {
      card(copy)
    }
  }

  private func card(_ copy: DeviceApprovalCopy) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(copy.title)
          .font(.headline)
      } icon: {
        Image(systemName: copy.tone == .blocking ? "lock.shield" : "person.badge.shield.checkmark")
          .foregroundStyle(copy.tone == .blocking ? Color.orange : Color.blue)
      }

      Text(copy.message)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let failure = model.failure {
        Text(failure.message)
          .font(.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("device-approval-failure")
        if let detail = failure.detail {
          DisclosureGroup("Details for Support") {
            Text(verbatim: detail)
              .font(.caption2.monospaced())
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("device-approval-failure-details")
        }
      }

      HStack(spacing: 10) {
        Button(Self.label(for: copy.primary)) { perform(copy.primary) }
          .buttonStyle(.borderedProminent)
          .disabled(model.isWorking)
          .accessibilityIdentifier("device-approval-primary")
        if let secondary = copy.secondary {
          Button(Self.label(for: secondary)) { perform(secondary) }
            .buttonStyle(.bordered)
            .disabled(model.isWorking)
            .accessibilityIdentifier("device-approval-secondary")
        }
        if model.isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 14))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("device-approval-card")
  }

  static func label(for action: DeviceApprovalCopy.Action) -> String {
    switch action {
    case .restoreBackup: "Restore Backup"
    case .approve: "Approve"
    case .reviewDevices: "Review Devices"
    case .checkAgain: "Check Again"
    }
  }

  private func perform(_ action: DeviceApprovalCopy.Action) {
    switch action {
    case .restoreBackup:
      model.presentedSheet = .restore
    case .reviewDevices:
      model.presentedSheet = .devices
    case .approve(let peer):
      Task { @MainActor in await model.approve(peer, appState: appState) }
    case .checkAgain:
      Task { @MainActor in
        await model.refresh(appState: appState)
        await model.finishQueuedRestore(appState: appState, force: true)
      }
    }
  }
}

// MARK: - Tracking

/// Keeps a `DeviceApprovalModel` current for the view it modifies: loads it per account,
/// reloads when the app comes back, publishes a queued restore, and presents the restore
/// and Devices screens the card opens.
struct DeviceApprovalTracking: ViewModifier {
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @Bindable var model: DeviceApprovalModel

  func body(content: Content) -> some View {
    content
      .task(id: appState.userDID) {
        await model.refresh(appState: appState)
      }
      .task(id: model.selfApprovalKey(accountDID: appState.userDID)) {
        await model.waitForSelfApproval(appState: appState)
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { @MainActor in
          await model.refresh(appState: appState)
          await model.finishQueuedRestore(appState: appState)
        }
      }
      .sheet(item: $model.presentedSheet, onDismiss: {
        Task { @MainActor in await model.refresh(appState: appState) }
      }) { sheet in
        NavigationStack {
          switch sheet {
          case .restore:
            LabyrinthSettingsAndRestoreView(
              coordinator: appState.mlsCoordinator,
              currentDeviceId: appState.resolvedMLSDeviceID()
            )
            .id(appState.mlsCoordinator?.accountDidHash)
          case .devices:
            DeviceManagementView()
          }
        }
        .environment(appState)
      }
  }
}
