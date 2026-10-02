import SwiftUI

/// Group configuration step for creating a Bluesky group chat.
/// Shows group name field and participant summary.
struct GroupConfigView: View {
  @Binding var groupName: String
  let participants: [ChatParticipant]
  var onEditSelection: (() -> Void)?

  private let defaultGroupName = "Group Chat"
  private let namePlaceholder = "Group Name"
  private let nameFooter = "Choose a name for this Bluesky group chat."
  private let participantsFooter = "Everyone listed will be invited when this group chat is created."

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
          Image(systemName: "person.3.fill")
            .font(.system(size: 12))
            .foregroundColor(.accentColor)
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
    "\(participants.count) member\(participants.count == 1 ? "" : "s")"
  }

  private var securitySection: some View {
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
