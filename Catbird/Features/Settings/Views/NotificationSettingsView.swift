import SwiftUI
import OSLog

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
            
            if notificationManager.status == .registered && notificationManager.notificationsEnabled {
                notificationPreferencesSection
            } else if notificationManager.notificationsEnabled {
                Section("Notification Types") {
                    HStack {
                        Text("Setting up notifications...")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
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
                // Open System Preferences on macOS
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                #endif
            }
        } message: {
            Text("To receive notifications, you need to enable them in the system settings.")
        }
        .task {
            await appState.notificationManager.checkNotificationStatus()
        }
    }
    
    // Section for notification preferences
    private var notificationPreferencesSection: some View {
        Section("Notification Types") {
            Group {
                Toggle("Mentions", isOn: Binding(
                    get: { notificationManager.preferences.mentions },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.mentions = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Replies", isOn: Binding(
                    get: { notificationManager.preferences.replies },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.replies = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Likes", isOn: Binding(
                    get: { notificationManager.preferences.likes },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.likes = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Follows", isOn: Binding(
                    get: { notificationManager.preferences.follows },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.follows = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Reposts", isOn: Binding(
                    get: { notificationManager.preferences.reposts },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.reposts = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Quotes", isOn: Binding(
                    get: { notificationManager.preferences.quotes },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.quotes = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Likes on Reposts", isOn: Binding(
                    get: { notificationManager.preferences.likeViaRepost },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.likeViaRepost = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
                
                Toggle("Reposts of Reposts", isOn: Binding(
                    get: { notificationManager.preferences.repostViaRepost },
                    set: { newValue in
                        Task {
                            var prefs = notificationManager.preferences
                            prefs.repostViaRepost = newValue
                            await notificationManager.updatePreferences(prefs)
                        }
                    }
                ))
                .disabled(!notificationManager.notificationsEnabled)
            }
        }
    }
    
    // Request notification permission
    private func requestNotificationPermission() async {
        await notificationManager.requestNotificationPermission()
    }
    
    // Enable all notifications
    @MainActor
    private func enableAllNotifications() async {
        logger.info("User enabling all notifications via master toggle")
        await notificationManager.requestNotificationPermission()
    }
    
    // Disable all notifications and unregister device
    private func disableAllNotifications() async {
        logger.info("User disabling all notifications via master toggle")
        await notificationManager.cleanupNotifications()
    }
}
