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
  private let participantsFooter = "Everyone listed will be added when this group chat is created. Group chats on Bluesky aren’t end-to-end encrypted."

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
}
