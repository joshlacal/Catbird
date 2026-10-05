import SwiftUI
import Petrel

struct NotificationSettingsView: View {
  @Environment(AppState.self) private var appState
  let initialFocus: SettingsControlID?
  @State private var isChangingPush = false

  init(initialFocus: SettingsControlID? = nil) {
    self.initialFocus = initialFocus
  }

  private var manager: NotificationManager { appState.notificationManager }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus) {
      SettingsScopeSection()
      deviceSection
      NotificationPreferencesStatusSection(manager: manager, accountDID: appState.userDID)
      Section {
        ForEach(NotificationPreferenceCategory.activity) { category in
          categoryLink(category)
        }
      } header: {
        Text("Activity Notifications")
      } footer: {
        Text("Choose what appears in your Notifications tab and which events can send a push alert. Turning off push on this device keeps your in-app activity available.")
      }
      Section("Other Activity") {
        ForEach(NotificationPreferenceCategory.otherActivity) { category in
          categoryLink(category)
        }
      }
      Section {
        if manager.hasConfirmedNotificationPreferences {
          Toggle("Direct Message Push Alerts", isOn: Binding(
            get: { manager.preferences.chat.push },
            set: { enabled in
              let origin = manager
              let did = appState.userDID
              Task {
                _ = try? await origin.updatePreferences({ preferences in
                  preferences.chat = .init(include: preferences.chat.include, push: enabled)
                }, expectedAccountDID: did)
              }
            }
          ))
          .disabled(!manager.canEditNotificationPreferences)
          .settingsControl(.init(rawValue: "notifications.messages"))
        } else {
          Text("Load saved preferences to see message alert settings.").foregroundStyle(.secondary)
            .settingsControl(.init(rawValue: "notifications.messages"))
        }
      } header: {
        Text("Messages")
      } footer: {
        Text("Choose direct message alerts for this account. Push delivery also needs device permission and a ready connection.")
      }
      Section("Post Notification Subscriptions") {
        SettingsLink(screen: .activitySubscriptions, systemImage: "bell.badge", family: .notifications)
          .settingsControl(.init(rawValue: "notifications.subscriptions"))
        SettingsLink(screen: .activityPrivacy, systemImage: "person.badge.clock", family: .privacy)
      }
    }
    .navigationTitle("Notifications")
    .modifier(NotificationSettingsTitleStyle())
    .appFont(AppTextRole.body)
    .appDisplayScale(appState: appState)
    .contrastAwareBackground(appState: appState, defaultColor: .systemBackground)
    .task(id: appState.userDID) {
      let origin = manager
      let did = appState.userDID
      await origin.checkNotificationStatus(expectedAccountDID: did)
      await origin.refreshNotificationPreferences(expectedAccountDID: did)
    }
  }

  private var deviceSection: some View {
    Section {
      Toggle("Push Alerts on This Device", isOn: Binding(
        get: { manager.isPushRequested },
        set: { enabled in
          let origin = manager
          let did = appState.userDID
          isChangingPush = true
          Task { @MainActor in
            if enabled { await origin.enableNotifications(expectedAccountDID: did) }
            else { await origin.disableNotifications(expectedAccountDID: did) }
            isChangingPush = false
          }
        }
      ))
      .disabled(isChangingPush || manager.status == .waitingForPermission)
      .settingsControl(.init(rawValue: "notifications.push"))
      LabeledContent("Push Connection", value: manager.pushDeliverySummary)
        .fixedSize(horizontal: false, vertical: true)
      LabeledContent("System Permission", value: manager.systemPermissionSummary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Open System Notification Settings", action: openSystemSettings)
        .settingsControl(.init(rawValue: "notifications.systemPermission"))
      if case .registrationFailed(let error) = manager.status {
        Text(UserFacingError.message(for: error, action: "connect push alerts on this device")
          ?? "Couldn’t connect push alerts on this device. Try again.").foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Try Push Connection Again") {
          let origin = manager
          let did = appState.userDID
          Task { await origin.enableNotifications(expectedAccountDID: did) }
        }
        .disabled(isChangingPush)
      }
      if isChangingPush { ProgressView("Updating push delivery…") }
    } header: {
      Text("On This Device")
    } footer: {
      Text("Push alerts apply to this account on this device. System notification permission applies to Catbird across your accounts.")
    }
  }

  private func categoryLink(_ category: NotificationPreferenceCategory) -> some View {
    NavigationLink {
      NotificationPreferenceEditorView(category: category, manager: manager, accountDID: appState.userDID)
    } label: {
      NotificationCategoryRow(title: category.title,
        summary: manager.hasConfirmedNotificationPreferences ? category.summary(in: manager.preferences) : "Not loaded")
    }
    .disabled(!manager.canEditNotificationPreferences)
    .settingsControl(.init(rawValue: "notifications.\(category.rawValue)"))
  }

  private func openSystemSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    #elseif os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
      NSWorkspace.shared.open(url)
    }
    #endif
  }
}

struct NotificationCategoryRow: View {
  let title: String
  let summary: String
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).appFont(AppTextRole.body)
      Text(summary).appFont(AppTextRole.subheadline).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }
}

private enum NotificationPreferenceCategory: String, Identifiable {
  case mention, reply, like, follow, repost, quote, likeViaRepost, repostViaRepost
  case subscribedPost, starterpackJoined, verified, unverified
  var id: String { rawValue }
  static let activity: [Self] = [.mention, .reply, .like, .follow, .repost, .quote, .likeViaRepost, .repostViaRepost, .subscribedPost]
  static let otherActivity: [Self] = [.starterpackJoined, .verified, .unverified]
  var title: String {
    switch self {
    case .mention: "Mentions"
    case .reply: "Replies"
    case .like: "Likes"
    case .follow: "New Followers"
    case .repost: "Reposts"
    case .quote: "Quotes"
    case .likeViaRepost: "Likes of Your Reposts"
    case .repostViaRepost: "Reposts of Your Reposts"
    case .subscribedPost: "Posts from Your Subscriptions"
    case .starterpackJoined: "Starter Pack Signups"
    case .verified: "Account Verified"
    case .unverified: "Verification Removed"
    }
  }
  var filterablePath: WritableKeyPath<NotificationPreferences, AppBskyNotificationDefs.FilterablePreference>? {
    switch self {
    case .mention: \.mention
    case .reply: \.reply
    case .like: \.like
    case .follow: \.follow
    case .repost: \.repost
    case .quote: \.quote
    case .likeViaRepost: \.likeViaRepost
    case .repostViaRepost: \.repostViaRepost
    default: nil
    }
  }
  var plainPath: WritableKeyPath<NotificationPreferences, AppBskyNotificationDefs.Preference>? {
    switch self {
    case .subscribedPost: \.subscribedPost
    case .starterpackJoined: \.starterpackJoined
    case .verified: \.verified
    case .unverified: \.unverified
    default: nil
    }
  }
  func summary(in preferences: NotificationPreferences) -> String {
    if let path = filterablePath { return preferences[keyPath: path].summaryDescription }
    if let path = plainPath { return preferences[keyPath: path].summaryDescription }
    return "Not loaded"
  }
}

private struct NotificationPreferenceEditorView: View {
  let category: NotificationPreferenceCategory
  let manager: NotificationManager
  let accountDID: String
  private var canEdit: Bool { manager.notificationAccountDID == accountDID && manager.canEditNotificationPreferences }

  var body: some View {
    Form {
      NotificationPreferencesStatusSection(manager: manager, accountDID: accountDID)
      Section {
        Toggle("Show in Notifications Tab", isOn: channelBinding(push: false))
        Toggle("Send Push Alerts", isOn: channelBinding(push: true))
        if manager.pushDeliverySummary != "Push ready" {
          Text("Push delivery: \(manager.pushDeliverySummary). Your channel choices are retained.")
            .appFont(AppTextRole.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: { Text("Notification Channels") }
      .disabled(!canEdit)
      if let path = category.filterablePath {
        Section {
          Picker("Activity From", selection: Binding(
            get: { manager.preferences[keyPath: path].include },
            set: { include in
              save { preferences in
                let preference = preferences[keyPath: path]
                preferences[keyPath: path] = .init(
                  include: include, list: preference.list, push: preference.push
                )
              }
            }
          )) {
            Text("Everyone").tag("all")
            Text("People I Follow").tag("follows")
            if !["all", "follows"].contains(manager.preferences[keyPath: path].include) {
              Text("Existing Audience").tag(manager.preferences[keyPath: path].include)
            }
          }
          .pickerStyle(.inline)
        } header: { Text("Audience") }
          footer: { Text("This audience applies to both the Notifications tab and push alerts.") }
          .disabled(!canEdit)
      }
    }
    .navigationTitle(category.title)
    .modifier(NotificationSettingsTitleStyle())
    .appFont(AppTextRole.body)
  }

  private func channelBinding(push: Bool) -> Binding<Bool> {
    Binding(get: {
      if let path = category.filterablePath {
        let preference = manager.preferences[keyPath: path]
        return push ? preference.push : preference.list
      }
      if let path = category.plainPath {
        let preference = manager.preferences[keyPath: path]
        return push ? preference.push : preference.list
      }
      return false
    }, set: { value in
      save { preferences in
        if let path = category.filterablePath {
          let preference = preferences[keyPath: path]
          preferences[keyPath: path] = .init(
            include: preference.include,
            list: push ? preference.list : value,
            push: push ? value : preference.push
          )
        } else if let path = category.plainPath {
          let preference = preferences[keyPath: path]
          preferences[keyPath: path] = .init(
            list: push ? preference.list : value,
            push: push ? value : preference.push
          )
        }
      }
    })
  }

  private func save(_ update: @escaping (inout NotificationPreferences) -> Void) {
    guard canEdit else { return }
    Task { _ = try? await manager.updatePreferences(update, expectedAccountDID: accountDID) }
  }
}

private struct NotificationPreferencesStatusSection: View {
  let manager: NotificationManager
  let accountDID: String
  var body: some View {
    switch manager.preferencesState {
    case .loading:
      Section { ProgressView("Loading saved notification preferences…") }
    case .saving:
      Section { ProgressView("Saving notification preferences…") }
    case .loadFailed(let error):
      statusSection(title: "Couldn’t Load Preferences", error: error,
        explanation: "Your saved rules have not been replaced. Load them before making changes.", retry: "Try Loading Again")
    case .saveFailed(let error):
      statusSection(title: "Couldn’t Save Preferences", error: error,
        explanation: "Your last saved rules are shown. Try saving again to apply the changes below.", retry: "Try Saving Again")
    case .unavailable:
      Section { Text("Notification preferences are not connected for this account.").foregroundStyle(.secondary) }
    case .ready:
      EmptyView()
    }
  }
  private func statusSection(title: String, error: String, explanation: String, retry: String) -> some View {
    Section {
      Text(explanation).fixedSize(horizontal: false, vertical: true)
      Text(error).appFont(AppTextRole.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let pending = manager.pendingNotificationChangesDescription {
        Text(pending).appFont(AppTextRole.caption).fixedSize(horizontal: false, vertical: true)
      }
      Button(retry) { Task { await manager.retryNotificationPreferences(expectedAccountDID: accountDID) } }
        .accessibilityIdentifier("NotificationPreferencesRetry")
    } header: { Text(title) }
    .disabled(manager.notificationAccountDID != accountDID)
  }
}

private struct NotificationSettingsTitleStyle: ViewModifier {
  func body(content: Content) -> some View {
    #if os(iOS)
    content.toolbarTitleDisplayMode(.inline)
    #else
    content
    #endif
  }
}
