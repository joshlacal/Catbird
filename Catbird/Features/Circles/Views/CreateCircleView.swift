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
  @State private var showingErrorAlert = false

  var body: some View {
    NavigationStack {
      Form {
        Section("Circle Name") {
          TextField("e.g. Close Friends, Family", text: $name)
            .accessibilityLabel("Circle name")
            .accessibilityHint("Name must be between 1 and 64 characters")

          Text("\(name.trimmingCharacters(in: .whitespacesAndNewlines).count)/64 characters")
            .font(.caption2)
            .foregroundStyle(name.trimmingCharacters(in: .whitespacesAndNewlines).count > 64 ? .red : .secondary)
        }

        Section {
          ForEach(selectedMembers, id: \.did) { profile in
            HStack(spacing: 12) {
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
              Spacer()
              Button(role: .destructive) {
                selectedMembers.removeAll { $0.did.didString() == profile.did.didString() }
              } label: {
                Image(systemName: "minus.circle.fill")
                  .foregroundStyle(.red)
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Remove \(profile.displayName ?? "@\(profile.handle)")")
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
          Text("Initial Members (\(selectedMembers.count)/150)")
        } footer: {
          Text("You can also add members after the Circle is created.")
        }

        Section("Privacy & History Disclosure") {
          Label {
            Text(CircleManagementCopy.addMemberDisclosure)
              .font(.subheadline)
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
                Text("Creating Circle...")
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
                Label("Circle created, but AppView sync is pending", systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .font(.subheadline.weight(.semibold))
                Text(message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Button("Retry AppView Sync") {
                  Task {
                    try? await vm.retryActivation()
                    if vm.state == .complete {
                      dismiss()
                    }
                  }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry AppView sync")
              }
            }
          case .complete:
            Section {
              Label("Circle Created Successfully", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.subheadline.weight(.semibold))
            }
          case .idle:
            EmptyView()
          }
        }
      }
      .navigationTitle("New Circle")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
          .accessibilityLabel("Cancel creating circle")
        }

        ToolbarItem(placement: .confirmationAction) {
          if viewModel?.state == .submitting {
            ProgressView()
          } else {
            Button("Create") {
              createCircle()
            }
            .fontWeight(.semibold)
            .disabled(!isFormValid || viewModel?.state == .submitting)
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
  private func ensureCirclePermission() async throws {
    let expectedDID = appState.userDID
    try await appStateManager.authentication.ensureGatewayPermission(.circleSpaces) { authURL in
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
    guard appState.userDID == expectedDID else {
      throw GatewayPermissionError.stateChanged
    }
  }

  private func createCircle() {
    guard let vm = viewModel else { return }
    let memberDIDs = selectedMembers.map(\.did)

    Task {
      do {
        try await ensureCirclePermission()
        _ = try await vm.createCircle(name: name, memberDIDs: memberDIDs)
        if vm.state == .complete {
          dismiss()
        }
      } catch is CancellationError {
        // User dismissed the consent sheet; nothing to surface.
      } catch GatewayPermissionError.cancelled {
        // User dismissed the consent sheet; nothing to surface.
      } catch {
        vm.state = .failed(message: error.localizedDescription)
        showingErrorAlert = true
      }
    }
  }
}
