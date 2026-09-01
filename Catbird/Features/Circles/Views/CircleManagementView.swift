import SwiftUI
import Petrel
import PetrelCatbird

/// View for managing an existing Circle's settings, mute preference, and members.
/// Owner-only controls (member list, add/remove member, delete Circle) are strictly hidden from non-owner members.
struct CircleManagementView: View {
  let circle: CircleSummary

  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var viewModel: CircleManagementViewModel?
  @State private var membersToAdd: [AppBskyActorDefs.ProfileViewBasic] = []
  /// Hydrated profiles for the member roster, keyed by DID string.
  @State private var memberProfiles: [String: AppBskyActorDefs.ProfileViewDetailed] = [:]
  @State private var showingAddMemberSheet = false
  @State private var memberToRemove: DID?
  @State private var showingDeleteConfirmation = false
  @State private var showingRemoveConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        circleInfoSection

        if let vm = viewModel, vm.canManageMembers {
          membersSection(vm: vm)
          disclosuresSection
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
          await hydrateMemberProfiles()
        }
      }
      .sheet(isPresented: $showingAddMemberSheet, onDismiss: commitPendingMembers) {
        CircleMemberPickerView(
          selection: $membersToAdd,
          excludedDIDs: Set((viewModel?.members ?? []).map { $0.didString() }),
          disclosure: CircleManagementCopy.addMemberDisclosure
        )
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
    }
  }

  @ViewBuilder
  private var disclosuresSection: some View {
    Section("Privacy & Data Disclosures") {
      VStack(alignment: .leading, spacing: 8) {
        Label {
          Text(CircleManagementCopy.addMemberDisclosure)
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
    case .activationFailed(let message):
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Label("AppView sync pending: \(message)", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.subheadline)
          Button("Retry Sync") {
            Task { try? await vm.retryActivation() }
          }
          .buttonStyle(.bordered)
          .accessibilityLabel("Retry AppView sync")
        }
      }
    case .complete, .idle:
      EmptyView()
    }
  }

  // MARK: - Add Members

  /// Adds everyone picked in the member sheet once it is dismissed. Failures
  /// surface through `viewModel.state` in `operationStateSection`.
  private func commitPendingMembers() {
    guard let vm = viewModel, !membersToAdd.isEmpty else { return }
    let dids = membersToAdd.map(\.did)
    membersToAdd = []
    Task {
      for did in dids {
        do {
          try await vm.addMember(did: did)
        } catch {
          // State already carries the failure; remaining adds would repeat it.
          break
        }
      }
      await vm.loadMembers()
      await hydrateMemberProfiles()
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
        }
      } catch {
        // Leave this chunk's rows as raw DIDs; the next appearance retries.
        continue
      }
    }
  }
}
