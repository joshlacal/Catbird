import SwiftUI
import OSLog
import Petrel

/// View that allows users to configure their notification settings
struct NotificationSettingsView: View {
    // MARK: - Environment
    @Environment(AppState.self) private var appState
    
    // MARK: - State
    @State private var isRequestingPermission = false
    @State private var showSystemSettingsPrompt = false
    
    // MARK: - Properties
    private var notificationManager: NotificationManager {
        appState.notificationManager
    }
    
    // Logger
    private let logger = Logger(subsystem: "blue.catbird", category: "NotificationSettings")
    
    var body: some View {
        List {
            // MARK: - Master Toggle Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Push Notifications")
                            .appFont(AppTextRole.headline)
                    } icon: {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(.blue)
                    }
                    
                    Text("Receive notifications about activity on your account")
                        .foregroundStyle(.secondary)
                        .appFont(AppTextRole.subheadline)
                }
                .padding(.vertical, 4)
                
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable All Notifications")
                            .appFont(AppTextRole.body)
                        Text("Master control for all push notifications")
                            .foregroundStyle(.secondary)
                            .appFont(AppTextRole.caption)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: Binding(
                        get: { notificationManager.notificationsEnabled },
                        set: { newValue in
                            Task {
                                isRequestingPermission = true
                                if newValue {
                                    await enableAllNotifications()
                                } else {
                                    await disableAllNotifications()
                                }
                                isRequestingPermission = false
                            }
                        }
                    ))
                    .disabled(isRequestingPermission || notificationManager.status == .waitingForPermission)
                }
                .opacity(notificationManager.status == .permissionDenied ? 0.6 : 1.0)
                
                if notificationManager.status == .permissionDenied {
                    HStack {
                        Text("Notifications Disabled")
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Enable in Settings") {
                            showSystemSettingsPrompt = true
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }
                } else if case .registrationFailed(let error) = notificationManager.status {
                    VStack(alignment: .leading, spacing: 8) {
                        Label {
                            Text("Registration Failed")
                                .foregroundStyle(.red)
                                .appFont(AppTextRole.body)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }

                        Text(error.localizedDescription)
                            .foregroundStyle(.secondary)
                            .appFont(AppTextRole.caption)

                        Button("Try Again Later") {
                            Task {
                                await disableAllNotifications()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    .padding(.vertical, 4)
                } else if notificationManager.status == .unknown || notificationManager.status == .disabled {
                    HStack {
                        Text("Notifications Not Set Up")
                            .foregroundStyle(.secondary)
                        
                        Spacer()
                        
                        Button(action: {
                            Task {
                                isRequestingPermission = true
                                await requestNotificationPermission()
                                isRequestingPermission = false
                            }
                        }) {
                            if isRequestingPermission {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Enable")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRequestingPermission)
                    }
                }
            }
            
            #if os(iOS)
            if notificationManager.status == .registered && notificationManager.notificationsEnabled {
                chatNotificationsSection
            }
            #endif
            
            notificationPreferencesSection
        }
        .navigationTitle("Notifications")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .alert("Enable Notifications", isPresented: $showSystemSettingsPrompt) {
            Button("Cancel", role: .cancel) { }
            Button("Open Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #elseif os(macOS)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                #endif
            }
        } message: {
            Text("To receive notifications, you need to enable them in the system settings.")
        }
        .task {
            await appState.notificationManager.checkNotificationStatus()
            await appState.notificationManager.refreshNotificationPreferences()
        }
    }

    #if os(iOS)
    private var chatNotificationsSection: some View {
        Group {
            Section("Bluesky Direct Messages") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text("Direct Messages")
                                .appFont(AppTextRole.body)
                        } icon: {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(.green)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { notificationManager.chatNotificationsEnabled },
                            set: { newValue in
                                notificationManager.chatNotificationsEnabled = newValue
                                logger.info("Chat notifications toggled to: \(newValue)")
                            }
                        ))
                        .disabled(!notificationManager.notificationsEnabled)
                    }

                    Text("Get notifications for new chat messages when the app is not active")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
                .opacity(notificationManager.notificationsEnabled ? 1.0 : 0.6)
            }

            Section("Encrypted Chats") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text("Encrypted Messages")
                                .appFont(AppTextRole.body)
                        } icon: {
                            Image(systemName: "lock.shield")
                                .foregroundStyle(.blue)
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { notificationManager.mlsChatNotificationsEnabled },
                            set: { newValue in
                                notificationManager.mlsChatNotificationsEnabled = newValue
                                logger.info("MLS chat notifications toggled to: \(newValue)")
                            }
                        ))
                        .disabled(!notificationManager.notificationsEnabled)
                    }

                    Text("Get notifications for new encrypted chat messages")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 32)
                }
                .opacity(notificationManager.notificationsEnabled ? 1.0 : 0.6)
            }
        }
    }
    #endif

    // Section for granular notification preferences
    private var notificationPreferencesSection: some View {
        Section("Notification Types") {
            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Mentions",
                    preference: notificationManager.preferences.mention,
                    onSave: { updated in
                        updatePreferences { $0.mention = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Mentions",
                    summary: notificationManager.preferences.mention.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Replies",
                    preference: notificationManager.preferences.reply,
                    onSave: { updated in
                        updatePreferences { $0.reply = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Replies",
                    summary: notificationManager.preferences.reply.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Likes",
                    preference: notificationManager.preferences.like,
                    onSave: { updated in
                        updatePreferences { $0.like = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Likes",
                    summary: notificationManager.preferences.like.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "New followers",
                    preference: notificationManager.preferences.follow,
                    onSave: { updated in
                        updatePreferences { $0.follow = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "New followers",
                    summary: notificationManager.preferences.follow.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Reposts",
                    preference: notificationManager.preferences.repost,
                    onSave: { updated in
                        updatePreferences { $0.repost = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Reposts",
                    summary: notificationManager.preferences.repost.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Quotes",
                    preference: notificationManager.preferences.quote,
                    onSave: { updated in
                        updatePreferences { $0.quote = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Quotes",
                    summary: notificationManager.preferences.quote.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Likes of your reposts",
                    preference: notificationManager.preferences.likeViaRepost,
                    onSave: { updated in
                        updatePreferences { $0.likeViaRepost = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Likes of your reposts",
                    summary: notificationManager.preferences.likeViaRepost.summaryDescription
                )
            }

            NavigationLink {
                FilterablePreferenceEditorView(
                    title: "Reposts of your reposts",
                    preference: notificationManager.preferences.repostViaRepost,
                    onSave: { updated in
                        updatePreferences { $0.repostViaRepost = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Reposts of your reposts",
                    summary: notificationManager.preferences.repostViaRepost.summaryDescription
                )
            }

            NavigationLink {
                PlainPreferenceEditorView(
                    title: "Activity from others",
                    preference: notificationManager.preferences.subscribedPost,
                    onSave: { updated in
                        updatePreferences { $0.subscribedPost = updated }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Activity from others",
                    summary: notificationManager.preferences.subscribedPost.summaryDescription
                )
            }

            NavigationLink {
                EverythingElsePreferenceEditorView(
                    starterpackJoined: notificationManager.preferences.starterpackJoined,
                    verified: notificationManager.preferences.verified,
                    unverified: notificationManager.preferences.unverified,
                    onSave: { list, push in
                        updatePreferences { prefs in
                            let pref = AppBskyNotificationDefs.Preference(list: list, push: push)
                            prefs.starterpackJoined = pref
                            prefs.verified = pref
                            prefs.unverified = pref
                        }
                    }
                )
            } label: {
                NotificationCategoryRow(
                    title: "Everything else",
                    summary: everythingElseSummary
                )
            }
        }
    }

    private var everythingElseSummary: String {
        let starterpackJoined = notificationManager.preferences.starterpackJoined
        let verified = notificationManager.preferences.verified
        let unverified = notificationManager.preferences.unverified
        return AppBskyNotificationDefs.Preference(
            list: starterpackJoined.list || verified.list || unverified.list,
            push: starterpackJoined.push || verified.push || unverified.push
        ).summaryDescription
    }
    
    // Request notification permission
    private func requestNotificationPermission() async {
        await notificationManager.requestNotificationPermission()
    }
    
    // Enable all notifications
    @MainActor
    private func enableAllNotifications() async {
        logger.info("User enabling all notifications via master toggle")
        await notificationManager.enableNotifications()
    }
    
    // Disable all notifications
    @MainActor
    private func disableAllNotifications() async {
        logger.info("User disabling all notifications via master toggle")
        await notificationManager.disableNotifications()
    }
    
    // Mutate preferences via serialized mutation API
    private func updatePreferences(_ mutate: @escaping (inout NotificationPreferences) -> Void) {
        Task {
            do {
                try await notificationManager.updatePreferences(mutate)
            } catch {
                logger.error("Failed to update notification preferences: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Row Component

struct NotificationCategoryRow: View {
    let title: String
    let summary: String

    var body: some View {
        HStack {
            Text(title)
                .appFont(AppTextRole.body)
            Spacer()
            Text(summary)
                .foregroundStyle(.secondary)
                .appFont(AppTextRole.subheadline)
        }
    }
}

// MARK: - Filterable Preference Editor View

struct FilterablePreferenceEditorView: View {
    let title: String
    let preference: AppBskyNotificationDefs.FilterablePreference
    let onSave: (AppBskyNotificationDefs.FilterablePreference) -> Void

    init(
        title: String,
        preference: AppBskyNotificationDefs.FilterablePreference,
        onSave: @escaping (AppBskyNotificationDefs.FilterablePreference) -> Void
    ) {
        self.title = title
        self.preference = preference
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Notification Channels") {
                Toggle("In-App", isOn: Binding(
                    get: { preference.list },
                    set: { newValue in
                        let updated = AppBskyNotificationDefs.FilterablePreference(
                            include: preference.include,
                            list: newValue,
                            push: preference.push
                        )
                        onSave(updated)
                    }
                ))

                Toggle("Push Notifications", isOn: Binding(
                    get: { preference.push },
                    set: { newValue in
                        let updated = AppBskyNotificationDefs.FilterablePreference(
                            include: preference.include,
                            list: preference.list,
                            push: newValue
                        )
                        onSave(updated)
                    }
                ))
            }

            Section("Audience") {
                Picker("Show from", selection: Binding(
                    get: { preference.include },
                    set: { newValue in
                        let updated = AppBskyNotificationDefs.FilterablePreference(
                            include: newValue,
                            list: preference.list,
                            push: preference.push
                        )
                        onSave(updated)
                    }
                )) {
                    Text("Everyone").tag("all")
                    Text("People I follow").tag("follows")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(!preference.list && !preference.push)
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Plain Preference Editor View

struct PlainPreferenceEditorView: View {
    let title: String
    let preference: AppBskyNotificationDefs.Preference
    let onSave: (AppBskyNotificationDefs.Preference) -> Void

    init(
        title: String,
        preference: AppBskyNotificationDefs.Preference,
        onSave: @escaping (AppBskyNotificationDefs.Preference) -> Void
    ) {
        self.title = title
        self.preference = preference
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section("Notification Channels") {
                Toggle("In-App", isOn: Binding(
                    get: { preference.list },
                    set: { newValue in
                        let updated = AppBskyNotificationDefs.Preference(
                            list: newValue,
                            push: preference.push
                        )
                        onSave(updated)
                    }
                ))

                Toggle("Push Notifications", isOn: Binding(
                    get: { preference.push },
                    set: { newValue in
                        let updated = AppBskyNotificationDefs.Preference(
                            list: preference.list,
                            push: newValue
                        )
                        onSave(updated)
                    }
                ))
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Everything Else Preference Editor View

struct EverythingElsePreferenceEditorView: View {
    let starterpackJoined: AppBskyNotificationDefs.Preference
    let verified: AppBskyNotificationDefs.Preference
    let unverified: AppBskyNotificationDefs.Preference
    let onSave: (Bool, Bool) -> Void

    init(
        starterpackJoined: AppBskyNotificationDefs.Preference,
        verified: AppBskyNotificationDefs.Preference,
        unverified: AppBskyNotificationDefs.Preference,
        onSave: @escaping (Bool, Bool) -> Void
    ) {
        self.starterpackJoined = starterpackJoined
        self.verified = verified
        self.unverified = unverified
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(
                header: Text("Notification Channels"),
                footer: Text("Includes starter pack signups and account verification updates.")
            ) {
                Toggle("In-App", isOn: Binding(
                    get: { starterpackJoined.list || verified.list || unverified.list },
                    set: { newValue in
                        let push = starterpackJoined.push || verified.push || unverified.push
                        onSave(newValue, push)
                    }
                ))

                Toggle("Push Notifications", isOn: Binding(
                    get: { starterpackJoined.push || verified.push || unverified.push },
                    set: { newValue in
                        let list = starterpackJoined.list || verified.list || unverified.list
                        onSave(list, newValue)
                    }
                ))
            }
        }
        .navigationTitle("Everything else")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}
