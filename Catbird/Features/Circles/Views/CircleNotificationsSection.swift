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
              Text(error.localizedDescription)
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
}

/// Row view for an individual Circle notification.
struct CircleNotificationRow: View {
  let notification: BlueCatbirdCircleDefs.Notification
  let onTap: () -> Void
  let onAvatarTap: () -> Void

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
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(notification.actor.displayName ?? notification.actor.handle.description) \(actionDescription) in \(notification.circle.name)")
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

  private var actionDescription: String {
    switch notification.reason {
    case .value_reply:
      return "replied in"
    case .value_like:
      return "liked your post in"
    case .value_invite:
      return "invited you to"
    }
  }

  private func formattedTimestamp(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
