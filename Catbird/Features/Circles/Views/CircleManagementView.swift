import SwiftUI
import Petrel
import PetrelCatbird

/// View for managing an existing Circle's settings, mute preference, and members.
/// Owner-only controls (member list, add/remove member, delete Circle) are strictly hidden from non-owner members.
struct CircleManagementView: View {
  let circle: CircleSummary

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  @State private var viewModel: CircleManagementViewModel?
  @State private var membersToAdd: [AppBskyActorDefs.ProfileViewBasic] = []
  /// Hydrated profiles for the member roster, keyed by DID string.
  @State private var memberProfiles: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]
  @State private var showingAddMemberSheet = false
  @State private var memberToRemove: DID?
  @State private var showingDeleteConfirmation = false
  @State private var showingRemoveConfirmation = false
  @State private var isAuthorizingActivation = false
  @State private var showingRotateConfirmation = false
  @State private var showingUpgradeSheet = false
  @State private var showingHistoryOffAddConfirmation = false
  @State private var ineligibleAddMessages: [String] = []

  var body: some View {
    NavigationStack {
      Form {
        circleInfoSection

        if let vm = viewModel, vm.canManageMembers {
          encryptionSection(vm: vm)
          membersSection(vm: vm)
          disclosuresSection(vm: vm)
          deleteSection
        }

        if let vm = viewModel {
          operationStateSection(vm: vm)
        }
      }
      .navigationTitle("Circle Settings")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
          .accessibilityLabel("Done managing circle")
        }
      }
      .task {
        if viewModel == nil {
          let vm = CircleManagementViewModel(
            circle: circle,
            service: appState.circleService,
            userDID: appState.userDID ?? ""
          )
          self.viewModel = vm
          await vm.loadMembers()
          await vm.loadEncryptionState()
          vm.reconcileOnAppear()
          await hydrateMemberProfiles()
        }
      }
      .sheet(isPresented: $showingAddMemberSheet, onDismiss: confirmPendingMembers) {
        CircleMemberPickerView(
          selection: $membersToAdd,
          excludedDIDs: Set((viewModel?.members ?? []).map { $0.didString() }),
          disclosure: addMemberDisclosure(vm: viewModel)
        )
      }
      .sheet(isPresented: $showingUpgradeSheet) {
        if let vm = viewModel {
          upgradeSheet(vm: vm)
        }
      }
      .confirmationDialog(
        "Add Members",
        isPresented: $showingHistoryOffAddConfirmation
      ) {
        Button("Add Members") {
          commitPendingMembers()
        }
        Button("Cancel", role: .cancel) {
          membersToAdd = []
        }
      } message: {
        Text(CircleManagementCopy.historyOffAddConfirmation)
      }
      .alert(CircleManagementCopy.rotateKeyNow, isPresented: $showingRotateConfirmation) {
        Button(CircleManagementCopy.rotateKeyNow) {
          Task { await viewModel?.rotateKeyNow() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(CircleManagementCopy.rotateKeyConfirmation)
      }
      .confirmationDialog(
        "Remove Member",
        isPresented: $showingRemoveConfirmation,
        presenting: memberToRemove
      ) { did in
        Button("Remove Member", role: .destructive) {
          Task {
            _ = try? await viewModel?.removeMember(did: did)
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: { _ in
        Text(CircleManagementCopy.removeMemberDisclosure)
      }
      .confirmationDialog(
        "Delete Circle",
        isPresented: $showingDeleteConfirmation
      ) {
        Button("Delete Circle", role: .destructive) {
          Task {
            do {
              try await viewModel?.deleteCircle()
              dismiss()
            } catch {
              // Errors are surfaced in viewModel.state -> operationStateSection
            }
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Are you sure you want to delete this Circle? All posts and memberships in this Space will be permanently removed.")
      }
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var circleInfoSection: some View {
    Section("Circle") {
      VStack(alignment: .leading, spacing: 4) {
        Text(circle.name)
          .font(.headline)
        Text("Owner: \(circle.owner.didString())")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let vm = viewModel {
        Toggle(isOn: Binding(
          get: { vm.isMuted },
          set: { newValue in
            Task { try? await vm.setMuted(newValue) }
          }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Mute Circle")
            Text("Hides posts from unified feed and silences notifications. You can still open this Circle directly.")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityLabel("Mute Circle")
        .accessibilityHint("Toggles muting of this Circle from unified feeds and notifications")
      }
    }
  }

  @ViewBuilder
  private func membersSection(vm: CircleManagementViewModel) -> some View {
    Section("Members (\(vm.members.count)/150)") {
      if vm.members.isEmpty {
        Text("No additional members yet.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else {
        ForEach(vm.members, id: \.self) { did in
          HStack(spacing: 12) {
            if let profile = memberProfiles[did.didString()] {
              AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 36)
              VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName ?? "@\(profile.handle)")
                  .font(.subheadline.weight(.medium))
                  .lineLimit(1)
                Text("@\(profile.handle)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
            } else {
              Image(systemName: "person.circle")
                .foregroundStyle(.secondary)
              Text(did.didString())
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            if let badge = vm.pendingBadge(for: did) {
              Text(badge)
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel(badge)
            }
            if let permissions = vm.memberPermissions.first(where: { $0.did == did }),
               !permissions.read || !permissions.write {
              Text(permissions.read ? "Read only" : (permissions.write ? "Write only" : "No access"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
              memberToRemove = did
              showingRemoveConfirmation = true
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove member \(memberProfiles[did.didString()].map { $0.displayName ?? "@\($0.handle)" } ?? did.didString())")
            .accessibilityHint("Removes member from this Circle")
          }
        }
      }

      Button {
        membersToAdd = []
        showingAddMemberSheet = true
      } label: {
        Label("Add Members", systemImage: "person.badge.plus")
      }
      .disabled(vm.members.count >= 150)
      .accessibilityLabel("Add Members")
      .accessibilityHint("Search for people to add to this Circle")

      ForEach(ineligibleAddMessages, id: \.self) { message in
        Label(message, systemImage: "lock.slash")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if vm.circle.isEncrypted && !vm.pendingRewraps.isEmpty {
        Button(CircleManagementCopy.retryNow) {
          Task { await vm.retryPendingNow() }
        }
        .disabled(vm.state == .submitting)
        .accessibilityLabel(CircleManagementCopy.retryNow)
      }
    }
  }

  /// Encrypted: the history toggle and manual rotation. Plaintext: the D17
  /// upgrade row (or its resume row after an interrupted upgrade).
  @ViewBuilder
  private func encryptionSection(vm: CircleManagementViewModel) -> some View {
    if vm.circle.isEncrypted {
      Section {
        Toggle(isOn: Binding(
          get: { vm.historyForNewMembers },
          set: { newValue in
            Task { await vm.setHistoryForNewMembers(newValue) }
          }
        )) {
          VStack(alignment: .leading, spacing: 2) {
            Text(CircleManagementCopy.historyToggleLabel)
            Text(addMemberDisclosure(vm: vm))
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .disabled(vm.isWritingHistorySetting)
        .accessibilityLabel(CircleManagementCopy.historyToggleLabel)

        Button(CircleManagementCopy.rotateKeyNow) {
          showingRotateConfirmation = true
        }
        .disabled(!vm.canRotateKeyNow)
        .accessibilityLabel(CircleManagementCopy.rotateKeyNow)
      }
    } else if vm.encryptionAvailability != nil && !vm.encryptionAvailable {
      Section {
        Text(CircleManagementCopy.encryptionUnavailableHint)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    } else if vm.hasIncompleteUpgrade {
      Section {
        Button(CircleManagementCopy.upgradeIncomplete) {
          runUpgrade(vm: vm)
        }
        .disabled(vm.state == .submitting || isAuthorizingActivation)
        .accessibilityLabel(CircleManagementCopy.upgradeIncomplete)
      }
    } else {
      Section {
        Button {
          Task {
            await vm.prepareUpgrade()
            showingUpgradeSheet = true
          }
        } label: {
          Label(CircleManagementCopy.upgradeToEncrypted, systemImage: "lock")
        }
        .disabled(vm.state == .submitting || isAuthorizingActivation || !vm.encryptionAvailable)
        .accessibilityLabel(CircleManagementCopy.upgradeToEncrypted)
      }
    }
  }

  /// Lists the members a dry-run wrap could not carry over before the owner
  /// confirms the upgrade.
  private func upgradeSheet(vm: CircleManagementViewModel) -> some View {
    NavigationStack {
      List {
        if let blocked = vm.upgradeBlockedReason {
          Label(blocked, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline)
            .foregroundStyle(.orange)
        }
        ForEach(vm.upgradeIneligible, id: \.did) { entry in
          Label(vm.ineligibleMessage(for: entry.did), systemImage: "lock.slash")
            .font(.subheadline)
        }
      }
      .navigationTitle(CircleManagementCopy.upgradeToEncrypted)
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            showingUpgradeSheet = false
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(CircleManagementCopy.upgradeToEncrypted) {
            showingUpgradeSheet = false
            runUpgrade(vm: vm)
          }
          .fontWeight(.semibold)
          .disabled(!vm.canConfirmUpgrade)
        }
      }
    }
  }

  private func addMemberDisclosure(vm: CircleManagementViewModel?) -> String {
    guard let vm, vm.circle.isEncrypted, !vm.historyForNewMembers else {
      return CircleManagementCopy.addMemberDisclosure
    }
    return CircleManagementCopy.historyOffAddConfirmation
  }

  @ViewBuilder
  private func disclosuresSection(vm: CircleManagementViewModel) -> some View {
    Section("Privacy & Data Disclosures") {
      VStack(alignment: .leading, spacing: 8) {
        Label {
          Text(addMemberDisclosure(vm: vm))
            .font(.caption)
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "clock.arrow.circlepath")
            .foregroundStyle(Color.accentColor)
        }

        Label {
          Text(CircleManagementCopy.removeMemberDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "exclamationmark.shield")
            .foregroundStyle(.orange)
        }
      }
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("Circle privacy and membership disclosures")
    }
  }

  @ViewBuilder
  private var deleteSection: some View {
    Section {
      Button(role: .destructive) {
        showingDeleteConfirmation = true
      } label: {
        HStack {
          Spacer()
          Text("Delete Circle")
            .fontWeight(.semibold)
          Spacer()
        }
      }
      .accessibilityLabel("Delete Circle")
      .accessibilityHint("Permanently deletes this Circle Space")
    }
  }

  @ViewBuilder
  private func operationStateSection(vm: CircleManagementViewModel) -> some View {
    switch vm.state {
    case .submitting:
      Section {
        HStack {
          ProgressView()
            .padding(.trailing, 8)
          Text("Updating Circle...")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    case .failed(let message):
      Section {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.subheadline)
      }
    case .upgradeIncomplete(let message):
      Section {
        Button {
          runUpgrade(vm: vm)
        } label: {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.subheadline)
        }
        .disabled(isAuthorizingActivation)
      }
    case .activationFailed(let message):
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Label("AppView activation failed: \(message)", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.subheadline)
          Button("Retry Activation") {
            guard !isAuthorizingActivation else { return }
            isAuthorizingActivation = true
            Task {
              defer { isAuthorizingActivation = false }
              do {
                let currentDID = appState.userDID
                guard currentDID == vm.userDID,
                      appStateManager.lifecycle.userDID == currentDID,
                      let did = try? DID(didString: currentDID) else {
                  throw GatewayPermissionError.stateChanged
                }
                try await CircleAppViewAuthCoordinator.shared.ensureAuthorization(
                  did: did, using: webAuthenticationSession
                )
                guard appStateManager.lifecycle.userDID == currentDID else {
                  throw GatewayPermissionError.stateChanged
                }
                try await vm.retryActivation()
              } catch is CancellationError {
                // Keep the existing Space available for another authorization attempt.
              } catch {
                vm.state = .activationFailed(message: error.localizedDescription)
              }
            }
          }
          .buttonStyle(.bordered)
          .disabled(isAuthorizingActivation)
          .accessibilityLabel("Retry Circle activation")
        }
      }
    case .complete, .idle:
      EmptyView()
    }
  }

  // MARK: - Add Members

  /// With history hidden on an encrypted Circle, asks first ("They will only
  /// see new posts."); otherwise commits straight away.
  private func confirmPendingMembers() {
    guard let vm = viewModel, !membersToAdd.isEmpty else { return }
    if vm.circle.isEncrypted && !vm.historyForNewMembers {
      showingHistoryOffAddConfirmation = true
    } else {
      commitPendingMembers()
    }
  }

  /// Adds everyone picked in the member sheet once it is dismissed. Failures
  /// surface through `viewModel.state` in `operationStateSection`. On an
  /// encrypted Circle, members who cannot be wrapped are listed and skipped.
  private func commitPendingMembers() {
    guard let vm = viewModel, !membersToAdd.isEmpty else { return }
    for profile in membersToAdd {
      vm.knownHandles[profile.did.didString()] = "\(profile.handle)"
    }
    let dids = membersToAdd.map(\.did)
    membersToAdd = []
    ineligibleAddMessages = []
    Task {
      var skipped: [String] = []
      for did in dids {
        do {
          try await vm.addMember(did: did)
        } catch CircleError.ineligibleMember(let reason) {
          skipped.append(reason)
          continue
        } catch {
          // State already carries the failure; remaining adds would repeat it.
          break
        }
      }
      ineligibleAddMessages = skipped
      await vm.loadMembers()
      await hydrateMemberProfiles()
    }
  }

  // MARK: - Upgrade

  /// Runs (or resumes) the D17 upgrade after the encrypted-Space scope and
  /// AppView consent are in place. Failures surface through `viewModel.state`.
  private func runUpgrade(vm: CircleManagementViewModel) {
    guard !isAuthorizingActivation else { return }
    isAuthorizingActivation = true
    Task {
      defer { isAuthorizingActivation = false }
      var started = false
      do {
        let currentDID = appState.userDID
        guard currentDID == vm.userDID,
              appStateManager.lifecycle.userDID == currentDID,
              let did = try? DID(didString: currentDID) else {
          throw GatewayPermissionError.stateChanged
        }
        try await appStateManager.authentication.ensureGatewayPermission(.circleEncryptedSpaces) { authURL in
          if #available(iOS 17.4, macOS 14.4, *) {
            return try await webAuthenticationSession.authenticate(
              using: authURL,
              callback: .https(host: "catbird.blue", path: "/oauth/permission-callback"),
              preferredBrowserSession: .shared,
              additionalHeaderFields: [:]
            )
          } else {
            return try await webAuthenticationSession.authenticate(
              using: authURL,
              callbackURLScheme: "catbird",
              preferredBrowserSession: .shared
            )
          }
        }
        try await CircleAppViewAuthCoordinator.shared.ensureAuthorization(
          did: did, using: webAuthenticationSession
        )
        guard appStateManager.lifecycle.userDID == currentDID else {
          throw GatewayPermissionError.stateChanged
        }
        started = true
        try await vm.upgradeToEncrypted()
        await hydrateMemberProfiles()
      } catch is CancellationError, GatewayPermissionError.cancelled {
        // The owner dismissed a consent sheet; nothing was created.
      } catch {
        // Once started, the view model's state already reports the failure
        // (.failed / .upgradeIncomplete); consent failures are reported here.
        if !started {
          vm.state = .failed(message: error.localizedDescription)
        }
      }
    }
  }

  // MARK: - Profile Hydration

  /// Resolves the roster's DIDs to profiles via batched `getProfiles` calls
  /// (25 per request, the endpoint's cap). Unresolvable DIDs keep their raw
  /// DID row; a failed batch never clears profiles already loaded.
  private func hydrateMemberProfiles() async {
    guard let vm = viewModel, !vm.members.isEmpty,
          let client = appState.atProtoClient
    else { return }

    let missing = vm.members.filter { memberProfiles[$0.didString()] == nil }
    guard !missing.isEmpty else { return }

    for chunkStart in stride(from: 0, to: missing.count, by: 25) {
      let chunk = Array(missing[chunkStart..<min(chunkStart + 25, missing.count)])
      do {
        let actors = try chunk.map { try ATIdentifier(string: $0.didString()) }
        let (code, response) = try await client.app.bsky.actor.getProfiles(
          input: AppBskyActorGetProfiles.Parameters(actors: actors)
        )
        guard (200..<300).contains(code), let profiles = response?.profiles else { continue }
        for profile in profiles {
          memberProfiles[profile.did.didString()] = profile
          vm.knownHandles[profile.did.didString()] = "\(profile.handle)"
        }
      } catch {
        // Leave this chunk's rows as raw DIDs; the next appearance retries.
        continue
      }
    }
  }
}
