import SwiftUI

/// Component for rendering system events and grouped system updates in unified chat streams
struct UnifiedSystemMessageView: View {
  let message: BlueskyMessageAdapter
  @Binding var navigationPath: NavigationPath
  var onToggleGroup: (() -> Void)? = nil
  var onInviteLinkAction: (() -> Void)? = nil

  var body: some View {
    if message.isSystemGroup {
      systemGroupView
    } else if let event = message.systemEvent {
      singleEventView(event)
    } else {
      EmptyView()
    }
  }

  // MARK: - Single Event

  private func singleEventView(_ event: UnifiedSystemEvent) -> some View {
    HStack(spacing: 6) {
      Image(systemName: event.iconName)
        .font(.caption2)
        .foregroundStyle(.secondary)

      eventText(event)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 16)
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(event.messageText)
  }

  @ViewBuilder
  private func eventText(_ event: UnifiedSystemEvent) -> some View {
    switch event.actionTarget {
    case .profile(let did):
      if let name = event.referencedNames[did], let range = event.messageText.range(of: name) {
        let prefix = String(event.messageText[..<range.lowerBound])
        let suffix = String(event.messageText[range.upperBound...])
        HStack(spacing: 0) {
          if !prefix.isEmpty { Text(prefix) }
          Button {
            navigationPath.append(NavigationDestination.profile(did))
          } label: {
            Text(name)
              .fontWeight(.medium)
              .foregroundStyle(.primary)
          }
          .buttonStyle(.plain)
          if !suffix.isEmpty { Text(suffix) }
        }
      } else {
        renderWithAnyReferencedName(event)
      }
    case .inviteLink:
      Button {
        onInviteLinkAction?()
      } label: {
        Text(event.messageText)
          .fontWeight(.medium)
          .foregroundStyle(.primary)
      }
      .buttonStyle(.plain)
    case .none:
      renderWithAnyReferencedName(event)
    }
  }

  @ViewBuilder
  private func renderWithAnyReferencedName(_ event: UnifiedSystemEvent) -> some View {
    if let firstDID = event.referencedDIDs.first, let name = event.referencedNames[firstDID], let range = event.messageText.range(of: name) {
      let prefix = String(event.messageText[..<range.lowerBound])
      let suffix = String(event.messageText[range.upperBound...])
      HStack(spacing: 0) {
        if !prefix.isEmpty { Text(prefix) }
        Button {
          navigationPath.append(NavigationDestination.profile(firstDID))
        } label: {
          Text(name)
            .fontWeight(.medium)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        if !suffix.isEmpty { Text(suffix) }
      }
    } else {
      Text(event.messageText)
    }
  }

  // MARK: - Grouped View

  private var systemGroupView: some View {
    Button {
      onToggleGroup?()
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "bubble.left.and.bubble.right")
          .font(.caption2)
          .foregroundStyle(.secondary)

        Text("\(message.systemGroupEvents?.count ?? 0) chat updates")
          .font(.caption)
          .fontWeight(.medium)
          .foregroundStyle(.secondary)

        Image(systemName: message.isExpanded ? "chevron.up" : "chevron.down")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(
        Capsule()
          .fill(Color.secondary.opacity(0.12))
      )
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 4)
    .accessibilityLabel("\(message.systemGroupEvents?.count ?? 0) chat updates, \(message.isExpanded ? "expanded" : "collapsed")")
    .accessibilityHint("Double tap to \(message.isExpanded ? "collapse" : "expand")")
  }
}

// MARK: - UnifiedSystemEvent Action Target

extension UnifiedSystemEvent {
  enum ActionTarget: Hashable, Sendable {
    case profile(did: String)
    case inviteLink
  }

  var actionTarget: ActionTarget? {
    switch kind {
    case .memberAdded(let memberDID, _):
      return .profile(did: memberDID)
    case .memberRemoved(let memberDID, _):
      return .profile(did: memberDID)
    case .memberJoined(let memberDID, _):
      return .profile(did: memberDID)
    case .memberLeave(let memberDID):
      return .profile(did: memberDID)
    case .convoLocked(let byDID):
      return byDID.map { .profile(did: $0) }
    case .convoUnlocked(let byDID):
      return byDID.map { .profile(did: $0) }
    case .convoEnded(let byDID):
      return byDID.map { .profile(did: $0) }
    case .joinLinkCreated, .joinLinkEdited, .joinLinkEnabled, .joinLinkDisabled:
      return .inviteLink
    case .groupEdited, .generic:
      return nil
    }
  }
}
