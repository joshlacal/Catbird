import SwiftUI

/// After a person is picked: the kinds of conversation that can be started with them. Encrypted
/// chat (with a lock) comes first when they can use it; Bluesky DM is always offered.
struct ConversationKindChooserView: View {
  @Bindable var model: NewConversationKindModel
  let onChoose: (ChatConversationKind) -> Void
  let onChangePerson: () -> Void

  var body: some View {
    List {
      Section {
        HStack(spacing: 12) {
          AsyncProfileImage(url: model.recipient.avatarURL, size: 44)
          VStack(alignment: .leading, spacing: 2) {
            if let displayName = model.recipient.displayName, !displayName.isEmpty {
              Text(verbatim: displayName).appFont(AppTextRole.headline).lineLimit(1)
            }
            Text(verbatim: "@\(model.recipient.handle)")
              .appFont(AppTextRole.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          Button("Change", action: onChangePerson)
            .appFont(AppTextRole.subheadline)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("newConversation.changePerson")
        }
      }

      Section {
        if model.state == .checking {
          HStack(spacing: 10) {
            ProgressView()
            Text("Checking encrypted chat…")
              .foregroundStyle(.secondary)
          }
          .accessibilityIdentifier("newConversation.checking")
        }
        ForEach(model.options) { kind in
          optionRow(kind)
        }
      } footer: {
        footer
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
  }

  private func optionRow(_ kind: ChatConversationKind) -> some View {
    Button {
      onChoose(kind)
    } label: {
      HStack(spacing: 14) {
        Image(systemName: kind.optionSystemImage)
          .appFont(AppTextRole.title3)
          .foregroundStyle(kind.showsLock ? Color.green : Color.accentColor)
          .frame(width: 28)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(kind.optionTitle)
            .appFont(AppTextRole.body).fontWeight(.semibold)
            .foregroundStyle(.primary)
          Text(kind.optionDetail)
            .appFont(AppTextRole.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        if model.isStarting {
          ProgressView()
        } else {
          Image(systemName: "chevron.forward")
            .appFont(AppTextRole.footnote).fontWeight(.semibold)
            .foregroundStyle(.tertiary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(model.isStarting)
    .accessibilityIdentifier("newConversation.option.\(kind.rawValue)")
  }

  @ViewBuilder
  private var footer: some View {
    if let notice = model.notice {
      HStack(spacing: 8) {
        Text(notice)
          .accessibilityIdentifier("newConversation.notice")
        if model.canRetry {
          Button("Try again") {
            Task { await model.retry() }
          }
          .appFont(AppTextRole.footnote).fontWeight(.semibold)
          .accessibilityIdentifier("newConversation.retry")
        }
      }
    }
  }
}
