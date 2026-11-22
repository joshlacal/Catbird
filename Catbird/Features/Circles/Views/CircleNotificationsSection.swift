//
//  CircleNotificationsSection.swift
//  Catbird
//

import NukeUI
import Petrel
import PetrelCatbird
import SwiftUI

/// Section displaying private Circle notifications inside `NotificationsView`.
struct CircleNotificationsSection: View {
  let appState: AppState
  let navigationPath: Binding<NavigationPath>

  init(appState: AppState, navigationPath: Binding<NavigationPath>) {
    self.appState = appState
    self.navigationPath = navigationPath
  }

  var body: some View {
    let model = appState.circleNotificationsModel
    if !model.notifications.isEmpty || model.error != nil {
      Section {
        if let error = model.error {
          HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundColor(.orange)
              .imageScale(.medium)
            VStack(alignment: .leading, spacing: 2) {
              Text("Unable to load Circle activity")
                .enhancedAppSubheadline()
                .fontWeight(.medium)
                .foregroundColor(.primary)
              Text(contentFreeErrorMessage(for: error))
                .enhancedAppCaption()
                .foregroundColor(.secondary)
            }
            Spacer()
            Button {
              Task {
                do {
                  try await model.refresh()
                } catch {
                  // Error is recorded in model.error
                }
              }
            } label: {
              Text("Retry")
                .enhancedAppCaption()
                .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .listRowSeparator(.visible)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        }

        ForEach(model.notifications, id: \.id) { notification in
          CircleNotificationRow(
            notification: notification,
            onTap: {
              handleNotificationTap(notification)
            },
            onAvatarTap: {
              navigationPath.wrappedValue.append(NavigationDestination.profile(notification.actor.did.didString()))
            }
          )
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .listRowSeparator(.visible)
          .themedListRowBackground(appState.themeManager, appSettings: appState.appSettings)
        }
#if DEBUG
        if let transport = appState.e2eCircleTransport {
          Button("Trigger Circle Push") {
            Task {
              await transport.enqueueGenericActivity()
              await appState.notificationManager.handlePush(["kind": "circle_activity"])
            }
          }
          .accessibilityIdentifier("e2e.circleActivityPush")
        }
#endif
      } header: {
        HStack(spacing: 6) {
          Image(systemName: "person.2.circle.fill")
            .foregroundColor(.accentColor)
          Text("Circle Activity")
            .enhancedAppSubheadline()
            .fontWeight(.semibold)
        }
        .textCase(nil)
        .padding(.vertical, 4)
      }
    }
  }

  private func handleNotificationTap(_ notification: BlueCatbirdCircleDefs.Notification) {
    switch notification.reason {
    case .value_reply, .value_like:
      if let subject = notification.subject {
        navigationPath.wrappedValue.append(NavigationDestination.circlePost(subject, notification.circle))
      }
      // If subject is nil, fail closed: do not navigate
    case .value_invite:
      navigationPath.wrappedValue.append(NavigationDestination.circleDetail(notification.circle))
    }
  }

  static func contentFreeErrorMessage(for error: CircleError) -> String {
    switch error {
    case .upstreamUnavailable:
      return String(localized: "Circle service is temporarily unavailable.", comment: "Content-free error message in Circle notifications when the service is down.")
    case .accessRemoved:
      return String(localized: "Access to Circle activity was removed.", comment: "Content-free error message in Circle notifications when membership was removed.")
    case .accessExpired:
      return String(localized: "Circle access expired. Please reauthorize.", comment: "Content-free error message in Circle notifications when authorization expired.")
    case .unsupportedPDS, .protocolRevisionMismatch:
      return String(localized: "Circle features are not supported by this server.", comment: "Content-free error message in Circle notifications when server lacks Circle support.")
    case .authRequired:
      return String(localized: "Authentication required to view Circle activity.", comment: "Content-free error message in Circle notifications when authentication is required.")
    case .notAuthorized:
      return String(localized: "Not authorized to view Circle activity.", comment: "Content-free error message in Circle notifications when not authorized.")
    case .networkError, .clientNotInitialized, .invalidResponse, .missingLikeUri, .spaceWriteRejected, .invalidParameter,
      .keyVersionConflict, .encryptionUnavailable, .ineligibleMember, .ownerMismatch, .keysTemporarilyUnavailable,
      .keyStoreUnavailable:
      return String(localized: "Unable to load Circle activity. Please check your connection and try again.", comment: "Generic content-free error message when Circle notifications fail to load.")
    }
  }

  private func contentFreeErrorMessage(for error: CircleError) -> String {
    Self.contentFreeErrorMessage(for: error)
  }
}

/// Row view for an individual Circle notification.
struct CircleNotificationRow: View {
  let notification: BlueCatbirdCircleDefs.Notification
  let onTap: () -> Void
  let onAvatarTap: () -> Void
  @Environment(\.locale) private var locale

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 12) {
        reasonIcon
          .padding(.top, 2)

        Button(action: onAvatarTap) {
          if let avatarURLString = notification.actor.avatar?.uriString(),
             let avatarURL = URL(string: avatarURLString) {
            LazyImage(url: avatarURL) { state in
              if let image = state.image {
                image
                  .resizable()
                  .scaledToFill()
              } else {
                Circle()
                  .fill(Color.secondary.opacity(0.2))
              }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
          } else {
            Circle()
              .fill(Color.secondary.opacity(0.2))
              .frame(width: 36, height: 36)
              .overlay {
                Image(systemName: "person.fill")
                  .foregroundColor(.secondary)
                  .font(.caption)
              }
          }
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 4) {
            Text(notification.actor.displayName ?? notification.actor.handle.description)
              .fontWeight(.semibold)
              .foregroundColor(.primary)
            Text(actionDescription)
              .foregroundColor(.secondary)
            Spacer()
            Text(formattedTimestamp(notification.indexedAt.date))
              .font(.caption)
              .foregroundColor(.secondary)
          }
          .font(.subheadline)

          HStack(spacing: 4) {
            Image(systemName: "person.2.circle")
              .font(.caption2)
            Text(notification.circle.name)
              .font(.caption)
              .fontWeight(.medium)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.12))
          .cornerRadius(12)
          .foregroundColor(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilitySummary)
    .accessibilityIdentifier("circle.notification.\(notification.id)")
  }

  @ViewBuilder
  private var reasonIcon: some View {
    switch notification.reason {
    case .value_reply:
      Image(systemName: "arrowshape.turn.up.left.fill")
        .foregroundColor(.blue)
        .font(.subheadline)
    case .value_like:
      Image(systemName: "heart.fill")
        .foregroundColor(.pink)
        .font(.subheadline)
    case .value_invite:
      Image(systemName: "person.badge.plus.fill")
        .foregroundColor(.green)
        .font(.subheadline)
    }
  }

  private var actionDescription: LocalizedStringResource {
    switch notification.reason {
    case .value_reply:
      return LocalizedStringResource("replied in", comment: "Verb phrase after actor name for a Circle reply notification (followed by the Circle name pill).")
    case .value_like:
      return LocalizedStringResource("liked your post in", comment: "Verb phrase after actor name for a Circle like notification (followed by the Circle name pill).")
    case .value_invite:
      return LocalizedStringResource("invited you to", comment: "Verb phrase after actor name for a Circle invitation notification (followed by the Circle name pill).")
    }
  }

  private var accessibilitySummary: Text {
    let actorName = notification.actor.displayName ?? notification.actor.handle.description
    switch notification.reason {
    case .value_reply:
      return Text(
        "\(actorName) replied in \(notification.circle.name)",
        comment: "Accessibility label for a Circle reply notification — %1$@ is the actor's name, %2$@ is the Circle name."
      )
    case .value_like:
      return Text(
        "\(actorName) liked your post in \(notification.circle.name)",
        comment: "Accessibility label for a Circle like notification — %1$@ is the actor's name, %2$@ is the Circle name."
      )
    case .value_invite:
      return Text(
        "\(actorName) invited you to \(notification.circle.name)",
        comment: "Accessibility label for a Circle invitation notification — %1$@ is the actor's name, %2$@ is the Circle name."
      )
    }
  }

  private func formattedTimestamp(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = locale
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
