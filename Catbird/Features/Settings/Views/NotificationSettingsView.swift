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
            
            if notificationManager.status == .registered {
                notificationPreferencesSection
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
            }
        }
    }
    
    // Request notification permission
    private func requestNotificationPermission() async {
        await notificationManager.requestNotificationPermission()
    }
}
