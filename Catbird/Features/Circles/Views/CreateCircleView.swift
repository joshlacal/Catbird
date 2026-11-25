import SwiftUI
import Petrel
import PetrelCatbird

/// View for creating a new named Circle Space.
struct CreateCircleView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(AppStateManager.self) private var appStateManager
  @Environment(\.webAuthenticationSession) private var webAuthenticationSession

  @State private var viewModel: CircleManagementViewModel?
  @State private var name: String = ""
  @State private var selectedMembers: [AppBskyActorDefs.ProfileViewBasic] = []
  @State private var showingMemberPicker = false
  @State private var isSubmitting = false
  private var authCoordinator: CircleAppViewAuthCoordinator { .shared }

  var body: some View {
    NavigationStack {
      Form {
        Section("Circle Name") {
          TextField("e.g. Close Friends, Family", text: $name)
            .accessibilityLabel("Circle name")
            .accessibilityHint("Name must be between 1 and 64 characters")

          Text(
            "\(name.trimmingCharacters(in: .whitespacesAndNewlines).count)/64 characters",
            comment: "Character count indicator for Circle name out of 64 maximum characters — %1$lld is the current character count."
          )
            .appFont(AppTextRole.caption2)
            .foregroundStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).count > 64 ? .red : .secondary)
        }

        Section {
          ForEach(selectedMembers, id: \.did) { profile in
            let targetName = profile.displayName ?? "@\(profile.handle)"
            HStack(spacing: 12) {
              AsyncProfileImage(url: URL(string: profile.avatar?.uriString() ?? ""), size: 36)
              VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: profile.displayName ?? "@\(profile.handle)")
                  .appFont(AppTextRole.subheadline).fontWeight(.medium)
                  .lineLimit(1)
                Text(verbatim: "@\(profile.handle)")
                  .appFont(AppTextRole.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Button(role: .destructive) {
                selectedMembers.removeAll { $0.did.didString() == profile.did.didString() }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel(Text(
                "Remove \(targetName)",
                comment: "Accessibility label for button to remove an initial member while creating a Circle — %1$@ is their display name or @handle."
              ))
            }
          }

          Button {
            showingMemberPicker = true
          } label: {
            Label("Add Members", systemImage: "person.badge.plus")
          }
          .disabled(selectedMembers.count >= 150)
          .accessibilityLabel("Add Members")
          .accessibilityHint("Search for people to add to this Circle")
        } header: {
          Text(
            "Initial Members (\(selectedMembers.count)/150)",
            comment: "Section header showing initial Circle members out of maximum 150 — %1$lld is the selected member count."
          )
        } footer: {
          Text("You can also add members after the Circle is created.")
        }

        if let vm = viewModel, vm.encryptionAvailability != nil {
          if vm.encryptionAvailability == .checkFailed {
            Section {
              Label(CircleManagementCopy.encryptionCheckFailed, systemImage: "exclamationmark.triangle")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
          } else if !vm.createEncrypted {
            Section {
              Text(CircleManagementCopy.encryptionUnavailableHint)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            }
          } else if !vm.createIneligible.isEmpty {
            Section {
              ForEach(vm.createIneligible, id: \.did) { entry in
                Label(vm.ineligibleMessage(for: entry.did), systemImage: "lock.slash")
                  .appFont(AppTextRole.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }

        Section("Privacy & History Disclosure") {
          Label {
            Text(CircleManagementCopy.addMemberDisclosure)
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
          } icon: {
            Image(systemName: "clock.arrow.circlepath")
              .foregroundStyle(Color.accentColor)
          }
          .accessibilityLabel("Membership history disclosure")
        }

        if let vm = viewModel {
          switch vm.state {
          case .submitting:
            Section {
              HStack {
                ProgressView()
                  .padding(.trailing, 8)
                Group {
                  if vm.hasCreatedSpace {
                    Text("Activating Circle...", comment: "Progress message while activating a newly created Circle with the AppView.")
                  } else {
                    Text("Creating Circle...", comment: "Progress message while creating a new Circle Space on the user's PDS.")
                  }
                }
                  .appFont(AppTextRole.subheadline)
                  .foregroundStyle(.secondary)
              }
            }
          case .failed(let message), .upgradeIncomplete(let message):
            Section {
              Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .appFont(AppTextRole.subheadline)
            }
          case .activationFailed(let message):
            Section {
              VStack(alignment: .leading, spacing: 8) {
                Label("Circle created, but AppView activation failed", systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .appFont(AppTextRole.subheadline).fontWeight(.semibold)
                Text(message)
                  .appFont(AppTextRole.caption)
                  .foregroundStyle(.secondary)
                Button("Retry Activation") {
                  retryActivation()
                }
                .buttonStyle(.catbird(.tonal, size: .md))
                .disabled(isSubmitting)
                .accessibilityLabel("Retry Circle activation")
              }
            }
          case .complete:
            Section {
              Label("Circle Created Successfully", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .appFont(AppTextRole.subheadline).fontWeight(.semibold)
            }
          case .idle:
            if isSubmitting {
              Section {
                HStack {
                  ProgressView()
                    .padding(.trailing, 8)
                  Text("Authorizing...")
                    .appFont(AppTextRole.subheadline)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .scrollContentBackground(.hidden)
      .themedGroupedBackground(appState.themeManager, appSettings: appState.appSettings)
      .navigationTitle("New Circle")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .disabled(isSubmitting)
          .accessibilityLabel("Cancel creating circle")
        }

        ToolbarItem(placement: .confirmationAction) {
          if isSubmitting || viewModel?.state == .submitting {
            ProgressView()
          } else if viewModel?.canRetryActivation == true || viewModel?.hasCreatedSpace == true {
            Button("Retry") {
              retryActivation()
            }
            .fontWeight(.semibold)
            .accessibilityLabel("Retry Activation")
          } else {
            Button("Create") {
              createCircle()
            }
            .fontWeight(.semibold)
            .disabled(!isFormValid || isSubmitting || viewModel?.state == .submitting)
            .accessibilityLabel("Create Circle")
            .accessibilityHint("Validates name and member DIDs, then creates the Circle")
          }
        }
      }
      .sheet(isPresented: $showingMemberPicker) {
        CircleMemberPickerView(
          selection: $selectedMembers,
          disclosure: CircleManagementCopy.addMemberDisclosure
        )
      }
      .task {
        if viewModel == nil {
          viewModel = CircleManagementViewModel(
            service: appState.circleService,
            userDID: appState.userDID ?? ""
          )
        }
      }
      .task(id: selectedMembers.map { $0.did.didString() }) {
        // Spec §9: shows whether this Circle will be encrypted and which picked
        // members an encrypted create would leave out, before Create.
        if viewModel == nil {
          viewModel = CircleManagementViewModel(
            service: appState.circleService,
            userDID: appState.userDID ?? ""
          )
        }
        guard let vm = viewModel else { return }
        for profile in selectedMembers {
          vm.knownHandles[profile.did.didString()] = "\(profile.handle)"
        }
        await vm.prepareCreate(memberDIDs: selectedMembers.map(\.did))
      }
    }
  }

  private var isFormValid: Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return (1...64).contains(trimmed.count)
  }

  /// Ensures the Circle Space scope is granted, presenting the gateway's
  /// consent page if the session lacks it. Creating a Space requires
  /// `manage=create` on `space:blue.catbird.circle`, which is not part of the
  /// initial sign-in grant.
  @MainActor
  private func ensureCirclePermission(_ permission: GatewayPermission) async throws {
    let expectedDID = appState.userDID
    try await appStateManager.authentication.ensureGatewayPermission(permission) { authURL in
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
    guard appState.userDID == expectedDID,
          appStateManager.lifecycle.userDID == expectedDID else {
      throw GatewayPermissionError.stateChanged
    }
  }

  /// Ensures standalone AppView OAuth consent is granted for the active account before Space creation or activation.
  @MainActor
  private func ensureAppViewConsent() async throws {
    let currentDID = appState.userDID
    guard !currentDID.isEmpty,
          appStateManager.lifecycle.userDID == currentDID,
          let did = try? DID(didString: currentDID) else {
      throw GatewayPermissionError.stateChanged
    }
    try await authCoordinator.ensureAuthorization(did: did, using: webAuthenticationSession)
    guard appState.userDID == currentDID,
          appStateManager.lifecycle.userDID == currentDID else {
      throw GatewayPermissionError.stateChanged
    }
  }

  private func createCircle() {
    guard let vm = viewModel, vm.userDID == appState.userDID else { return }
    guard !isSubmitting, vm.state != .submitting else { return }
    if vm.canRetryActivation || vm.hasCreatedSpace {
      retryActivation()
      return
    }
    guard isFormValid else { return }

    let memberDIDs = selectedMembers.map(\.did)
    isSubmitting = true

    Task {
      defer { isSubmitting = false }
      do {
        // An encrypted create (spec §9) needs the encrypted Space type's scope.
        try await ensureCirclePermission(vm.createEncrypted ? .circleEncryptedSpaces : .circleSpaces)
        try await ensureAppViewConsent()
        guard vm.userDID == appStateManager.lifecycle.userDID else {
          throw GatewayPermissionError.stateChanged
        }
        _ = try await vm.createCircle(name: name, memberDIDs: memberDIDs)
        if vm.state == .complete {
          dismiss()
        }
      } catch is CancellationError, GatewayPermissionError.cancelled {
        // User dismissed the consent sheet; preserve form in idle state unless Space was created
        if !vm.hasCreatedSpace && !vm.canRetryActivation {
          vm.state = .idle
        }
      } catch {
        vm.state = vm.hasCreatedSpace
          ? .activationFailed(message: error.localizedDescription)
          : .failed(message: error.localizedDescription)
      }
    }
  }

  private func retryActivation() {
    guard let vm = viewModel, vm.userDID == appState.userDID else { return }
    guard vm.canRetryActivation || vm.hasCreatedSpace else { return }
    guard !isSubmitting, vm.state != .submitting else { return }

    isSubmitting = true

    Task {
      defer { isSubmitting = false }
      do {
        try await ensureAppViewConsent()
        guard vm.userDID == appStateManager.lifecycle.userDID else {
          throw GatewayPermissionError.stateChanged
        }
        try await vm.retryActivation()
        if vm.state == .complete {
          dismiss()
        }
      } catch is CancellationError, GatewayPermissionError.cancelled {
        // User dismissed the consent sheet; preserve partial state (.activationFailed)
      } catch {
        vm.state = .activationFailed(message: error.localizedDescription)
      }
    }
  }
}
