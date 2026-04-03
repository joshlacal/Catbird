import CatbirdMLSCore
import SwiftUI

#if os(iOS)

/// Group configuration step for creating a Catbird Group.
/// Shows group name field and participant summary.
struct GroupConfigView: View {
  @Binding var groupName: String
  let participants: [MLSParticipantViewModel]
  var onEditSelection: (() -> Void)?

  var body: some View {
    List {
      Section {
        groupPreviewCard
          .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
      }

      Section {
        TextField("Group Name (optional)", text: $groupName)
          .designBody()
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
      } header: {
        Label("Group Name", systemImage: "text.bubble")
          .designCaption()
      } footer: {
        Text("Give your secure group a name, or leave blank for a default.")
          .designCaption()
      }

      Section {
        SelectedParticipantsSummaryList(participants: participants)
          .padding(.vertical, DesignTokens.Spacing.sm)

        if let onEditSelection {
          Button {
            onEditSelection()
          } label: {
            Label("Edit Selection", systemImage: "slider.horizontal.3")
              .fontWeight(.semibold)
          }
        }
      } header: {
        Text("Participants (\(participants.count))")
          .designCaption()
      } footer: {
        Text("Everyone listed will join this secure group once it is created.")
          .designCaption()
      }

      Section {
        encryptionRow(icon: "lock.shield.fill", title: "MLS Protocol", detail: "RFC 9420 standard")
        encryptionRow(icon: "key.fill", title: "Forward Secrecy", detail: "Unique keys per message")
        encryptionRow(icon: "checkmark.seal.fill", title: "Verified Identity", detail: "AT Protocol DIDs")
      } header: {
        Label("Security", systemImage: "checkmark.shield")
          .designCaption()
      }
    }
    .listStyle(.insetGrouped)
  }

  @ViewBuilder
  private var groupPreviewCard: some View {
    HStack(spacing: DesignTokens.Spacing.base) {
      ZStack {
        Circle()
          .fill(Color.accentColor.opacity(0.2))
          .frame(width: 56, height: 56)
        Image(systemName: "person.3.fill")
          .font(.system(size: 24))
          .foregroundColor(.accentColor)
      }

      VStack(alignment: .leading, spacing: 4) {
        Text(groupName.isEmpty ? "Secure Group" : groupName)
          .font(.title3)
          .fontWeight(.semibold)
          .lineLimit(1)

        HStack(spacing: 4) {
          Image(systemName: "lock.shield.fill")
            .font(.system(size: 12))
            .foregroundColor(.green)
          Text("\(participants.count) member\(participants.count == 1 ? "" : "s") \u{00B7} E2E Encrypted")
            .designCaption()
            .foregroundColor(.secondary)
        }
      }

      Spacer()
    }
    .padding()
    .background(Color.secondary.opacity(0.05))
    .cornerRadius(DesignTokens.Size.radiusMD)
  }

  @ViewBuilder
  private func encryptionRow(icon: String, title: String, detail: String) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: DesignTokens.Size.iconMD))
        .foregroundColor(.green)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).designCallout()
        Text(detail).designCaption().foregroundColor(.secondary)
      }
      Spacer()
    }
  }
}

#endif
