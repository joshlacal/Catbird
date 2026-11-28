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
    VStack(alignment: .leading, spacing: Space.md) {
      Label {
        Text(copy.title)
          .appFont(AppTextRole.headline)
      } icon: {
        Image(systemName: copy.tone == .blocking ? "lock.shield" : "person.badge.shield.checkmark")
          .foregroundStyle(copy.tone == .blocking ? Color.orange : Color.accentColor)
      }

      Text(copy.message)
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let failure = model.failure {
        Text(failure.message)
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("device-approval-failure")
        if let detail = failure.detail {
          DisclosureGroup("Details for Support") {
            Text(verbatim: detail)
              .appFont(AppTextRole.caption2)
              .monospaced()
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("device-approval-failure-details")
        }
      }

      HStack(spacing: Space.sm) {
        Button(Self.label(for: copy.primary)) { self.perform(copy.primary) }
          .buttonStyle(.catbird(.primary, size: .sm))
          .disabled(model.isWorking)
          .accessibilityIdentifier("device-approval-primary")
        if let secondary = copy.secondary {
          Button(Self.label(for: secondary)) { self.perform(secondary) }
            .buttonStyle(.catbird(.tonal, size: .sm))
            .disabled(model.isWorking)
            .accessibilityIdentifier("device-approval-secondary")
        }
        if model.isWorking {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .padding(Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .catbirdCard(copy.tone == .blocking ? .notice(.warning) : .embed)
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
