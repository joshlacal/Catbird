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
  var introduction: Binding<String>?
  var onEditSelection: (() -> Void)?

  private var defaultGroupName: String {
    switch kind {
    case .bluesky:
      return String(localized: "Group Chat", comment: "Default preview title for a new Bluesky group chat")
    case .mls:
      return String(localized: "Secure Group", comment: "Default preview title for a new end-to-end encrypted group chat")
    }
  }

  private var namePlaceholder: LocalizedStringKey {
    switch kind {
    case .bluesky: return "Group Name"
    case .mls: return "Group Name (optional)"
    }
  }

  private var nameFooter: LocalizedStringKey {
    switch kind {
    case .bluesky: return "Choose a name for this Bluesky group chat."
    case .mls: return "Give your secure group a name, or leave blank for a default."
    }
  }

  private var participantsFooter: LocalizedStringKey {
    switch kind {
    case .bluesky: return "Everyone listed will be added when this group chat is created. Group chats on Bluesky aren’t end-to-end encrypted."
    case .mls: return "Everyone listed receives a separate group invitation when the group is created."
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
        Text("Participants (\(participants.count))", comment: "Section header showing count of selected group participants (%lld = participant count)")
          .designCaption()
      } footer: {
        Text(participantsFooter)
          .designCaption()
      }

      if let introduction { MLSOptionalGroupIntroductionSection(text: introduction) }

      if kind == .mls {
        securitySection
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
          .appFont(AppTextRole.title3)
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
    switch kind {
    case .bluesky:
      return String(
        localized: "\(participants.count) members",
        comment: "Subtitle showing number of members in a group conversation"
      )
    case .mls:
      return String(
        localized: "\(participants.count) members - E2E Encrypted",
        comment: "Subtitle showing number of members in an end-to-end encrypted group (%lld = member count)"
      )
    }
  }

  private var securitySection: some View {
    Section {
      detailRow(icon: "lock.shield.fill", title: "MLS Protocol", detail: "RFC 9420 standard", iconColor: .green)
      detailRow(icon: "key.fill", title: "Forward Secrecy", detail: "Unique keys per message", iconColor: .green)
      detailRow(icon: "checkmark.seal.fill", title: "Verified Identity", detail: "AT Protocol DIDs", iconColor: .green)
    } header: {
      Label("Security", systemImage: "checkmark.shield")
        .designCaption()
    }
  }

  @ViewBuilder
  private func detailRow(icon: String, title: LocalizedStringKey, detail: LocalizedStringKey, iconColor: Color) -> some View {
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
