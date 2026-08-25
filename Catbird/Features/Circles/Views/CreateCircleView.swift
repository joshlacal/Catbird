import SwiftUI
import Petrel
import PetrelCatbird

/// View for creating a new named Circle Space.
struct CreateCircleView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var viewModel: CircleManagementViewModel?
  @State private var name: String = ""
  @State private var memberDIDsText: String = ""
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

        Section("Initial Members") {
          TextField("did:plc:..., did:plc:...", text: $memberDIDsText, axis: .vertical)
            .lineLimit(3...6)
            .accessibilityLabel("Initial member DIDs")
            .accessibilityHint("Comma- or newline-separated DIDs, maximum 150 members")

          Text("Enter up to 150 member DIDs separated by commas or newlines.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
          case .pending(let operation):
            Section {
              VStack(alignment: .leading, spacing: 8) {
                Label("Creation Pending", systemImage: "hourglass")
                  .foregroundStyle(.orange)
                  .font(.subheadline.weight(.semibold))
                Text("Operation ID: \(operation.id)")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                Button("Retry / Check Status") {
                  Task { try? await vm.retry() }
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Retry or check status of pending creation")
              }
            }
          case .failed(let message, let retryID):
            Section {
              VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.red)
                  .font(.subheadline)
                if let retryID {
                  Text("Operation ID: \(retryID.uuidString)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                  Button("Retry") {
                    Task { try? await vm.retry(operationID: retryID) }
                  }
                  .buttonStyle(.bordered)
                  .accessibilityLabel("Retry failed creation")
                }
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
          Button("Create") {
            createCircle()
          }
          .fontWeight(.semibold)
          .disabled(!isFormValid || viewModel?.state == .submitting)
          .accessibilityLabel("Create Circle")
          .accessibilityHint("Validates name and member DIDs, then creates the Circle")
        }
      }
      .task {
        if viewModel == nil {
          viewModel = CircleManagementViewModel(
            service: appState.circleService,
            userDID: appState.userDID ?? ""
          )
        }
      }
      .onChange(of: viewModel?.state) { _, newState in
        if newState == .complete {
          dismiss()
        }
      }
    }
  }

  private var isFormValid: Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return (1...64).contains(trimmed.count)
  }

  private func createCircle() {
    guard let vm = viewModel else { return }
    vm.memberDIDsInput = memberDIDsText

    Task {
      do {
        _ = try await vm.createCircle(name: name)
      } catch {
        showingErrorAlert = true
      }
    }
  }
}
