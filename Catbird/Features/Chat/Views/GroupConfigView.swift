import CatbirdMLSCore
import SwiftUI

/// Group configuration step for creating a Catbird Group.
/// Shows group name field and participant summary.
struct GroupConfigView: View {
  enum GroupKind {
    case bluesky
    case mls
  }

  @Binding var groupName: String
  let participants: [MLSParticipantViewModel]
  var kind: GroupKind = .mls
  var onEditSelection: (() -> Void)?

  private var defaultGroupName: String {
    switch kind {
    case .bluesky: return "Group Chat"
    case .mls: return "Secure Group"
    }
  }

  private var namePlaceholder: String {
    switch kind {
    case .bluesky: return "Group Name"
    case .mls: return "Group Name (optional)"
    }
  }

  private var nameFooter: String {
    switch kind {
    case .bluesky: return "Choose a name for this Bluesky group chat."
    case .mls: return "Give your secure group a name, or leave blank for a default."
    }
  }

  private var participantsFooter: String {
    switch kind {
    case .bluesky: return "Everyone listed will be invited when this group chat is created."
    case .mls: return "Everyone listed will join this secure group once it is created."
    }
  }

  var body: some View {
    List {
      Section {
        groupPreviewCard
          .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
      }

      Section {
        TextField(namePlaceholder, text: $groupName)
          .designBody()
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
      } header: {
        Label("Group Name", systemImage: "text.bubble")
          .designCaption()
      } footer: {
        Text(nameFooter)
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
        Text(participantsFooter)
          .designCaption()
      }

      securitySection
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #else
    .listStyle(.inset)
    #endif
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
        Text(groupName.isEmpty ? defaultGroupName : groupName)
          .font(.title3)
          .fontWeight(.semibold)
          .lineLimit(1)

        HStack(spacing: 4) {
          Image(systemName: kind == .mls ? "lock.shield.fill" : "person.3.fill")
            .font(.system(size: 12))
            .foregroundColor(kind == .mls ? .green : .accentColor)
          Text(previewSubtitle)
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

  private var previewSubtitle: String {
    let memberText = "\(participants.count) member\(participants.count == 1 ? "" : "s")"

    switch kind {
    case .bluesky:
      return memberText
    case .mls:
      return "\(memberText) - E2E Encrypted"
    }
  }

  @ViewBuilder
  private var securitySection: some View {
    switch kind {
    case .bluesky:
      Section {
        detailRow(
          icon: "bubble.left.and.bubble.right.fill",
          title: "Bluesky Chat",
          detail: "Native chat.bsky group",
          iconColor: .accentColor
        )
        detailRow(
          icon: "lock.slash.fill",
          title: "Encryption",
          detail: "Not end-to-end encrypted",
          iconColor: .secondary
        )
      } header: {
        Label("Delivery", systemImage: "person.3")
          .designCaption()
      }
    case .mls:
      Section {
        detailRow(icon: "lock.shield.fill", title: "MLS Protocol", detail: "RFC 9420 standard", iconColor: .green)
        detailRow(icon: "key.fill", title: "Forward Secrecy", detail: "Unique keys per message", iconColor: .green)
        detailRow(icon: "checkmark.seal.fill", title: "Verified Identity", detail: "AT Protocol DIDs", iconColor: .green)
      } header: {
        Label("Security", systemImage: "checkmark.shield")
          .designCaption()
      }
    }
  }

  @ViewBuilder
  private func detailRow(icon: String, title: String, detail: String, iconColor: Color) -> some View {
    HStack(spacing: DesignTokens.Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: DesignTokens.Size.iconMD))
        .foregroundColor(iconColor)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).designCallout()
        Text(detail).designCaption().foregroundColor(.secondary)
      }
      Spacer()
    }
  }
}
