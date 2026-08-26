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
  @State private var newMemberDIDText: String = ""
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
        }
      }
      .sheet(isPresented: $showingAddMemberSheet) {
        addMemberSheet
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
          HStack {
            Image(systemName: "person.circle")
              .foregroundStyle(.secondary)
            Text(did.didString())
              .font(.subheadline)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button(role: .destructive) {
              memberToRemove = did
              showingRemoveConfirmation = true
            } label: {
              Image(systemName: "minus.circle.fill")
                .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove member \(did.didString())")
            .accessibilityHint("Removes member from this Circle")
          }
        }
      }

      Button {
        showingAddMemberSheet = true
      } label: {
        Label("Add Member", systemImage: "person.badge.plus")
      }
      .disabled(vm.members.count >= 150)
      .accessibilityLabel("Add Member")
      .accessibilityHint("Add a new member by DID to this Circle")
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

  // MARK: - Add Member Sheet

  private var isValidNewMemberDID: Bool {
    let trimmed = newMemberDIDText.trimmingCharacters(in: .whitespacesAndNewlines)
    return (try? DID(didString: trimmed)) != nil
  }

  private var addMemberSheet: some View {
    NavigationStack {
      Form {
        Section("Member DID") {
          TextField("did:plc:...", text: $newMemberDIDText)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Member DID to add")
        }

        Section("Disclosure") {
          Text(CircleManagementCopy.addMemberDisclosure)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Add Member")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            showingAddMemberSheet = false
            newMemberDIDText = ""
          }
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            if let did = try? DID(didString: newMemberDIDText.trimmingCharacters(in: .whitespacesAndNewlines)) {
              Task {
                _ = try? await viewModel?.addMember(did: did)
                showingAddMemberSheet = false
                newMemberDIDText = ""
              }
            }
          }
          .disabled(!isValidNewMemberDID)
          .accessibilityLabel("Confirm add member")
        }
      }
    }
  }
}
