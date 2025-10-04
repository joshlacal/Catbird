import SwiftUI
import OSLog
import DeviceCheck

/// View that allows users to configure their notification settings
struct NotificationSettingsView: View {
    // MARK: - Environment
    @Environment(AppState.self) private var appState
    
    // MARK: - State
    @State private var isRequestingPermission = false
    @State private var showSystemSettingsPrompt = false
    @State private var showDebugInfo = false
    @State private var debugStatus: AppAttestEnvironmentStatus?
    @State private var testResult: AppAttestKeyTestResult?
    @State private var isTestingKey = false
    
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
            
            if notificationManager.status == .registered && notificationManager.notificationsEnabled {
                #if os(iOS)
                chatNotificationsSection
                #endif
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

    // Section for chat notifications
    #if os(iOS)
    private var chatNotificationsSection: some View {
        Section("Chat Notifications") {
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
                    .padding(.leading, 32) // Align with label text
            }
            .opacity(notificationManager.notificationsEnabled ? 1.0 : 0.6)
        }
    }
    #endif

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
            
            // MARK: - Debug Section (only in DEBUG builds)
            #if DEBUG
            Section {
                if #available(iOS 26.0, *) {
                    Button {
                        showDebugInfo.toggle()
                        if showDebugInfo {
                            debugStatus = AppAttestDebugger.performEnvironmentCheck()
                            AppAttestDebugger.logDiagnostics()
                        }
                    } label: {
                        HStack {
                            Image(systemName: showDebugInfo ? "chevron.down" : "chevron.right")
                                .font(.caption)
                            Text("App Attest Diagnostics")
                                .appFont(AppTextRole.body)
                        }
                    }

                    if showDebugInfo, let status = debugStatus {
                        VStack(alignment: .leading, spacing: 8) {
                            DiagnosticRow(
                                title: "Platform",
                                value: status.platform.rawValue,
                                isGood: status.platform == .physicalDevice
                            )

                            DiagnosticRow(
                                title: "DCAppAttest Support",
                                value: status.isSupported ? "Supported" : "Not Supported",
                                isGood: status.isSupported
                            )

                            DiagnosticRow(
                                title: "OS Version",
                                value: status.osVersionSupported ? "Compatible" : "Too Old",
                                isGood: status.osVersionSupported
                            )

                            DiagnosticRow(
                                title: "Bundle ID",
                                value: status.bundleIdentifier ?? "None",
                                isGood: status.bundleIdentifier != nil
                            )

                            DiagnosticRow(
                                title: "Entitlement",
                                value: status.hasAppAttestEntitlement ? "Present" : "Missing",
                                isGood: status.hasAppAttestEntitlement
                            )

                            if status.canUseAppAttest {
                                Label {
                                    Text("App Attest should work")
                                        .foregroundStyle(Color.green)
                                        .appFont(AppTextRole.caption)
                                } icon: {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.green)
                                }
                                .padding(.top, 4)
                            } else {
                                Label {
                                    Text(AppAttestDebugger.getUserFriendlyMessage())
                                        .foregroundStyle(Color.orange)
                                        .appFont(AppTextRole.caption)
                                } icon: {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(Color.orange)
                                }
                                .padding(.top, 4)
                            }

                            if status.canUseAppAttest {
                                Button {
                                    isTestingKey = true
                                    Task {
                                        testResult = await AppAttestDebugger.testKeyGeneration()
                                        isTestingKey = false
                                    }
                                } label: {
                                    HStack {
                                        if isTestingKey {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text(isTestingKey ? "Testing..." : "Test Key Generation")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isTestingKey)
                                .padding(.top, 8)

                                if let result = testResult {
                                    Text(result.userMessage)
                                        .foregroundStyle(result.isSuccess ? Color.green : Color.red)
                                        .appFont(AppTextRole.caption)
                                        .padding(.top, 4)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Text("App Attest diagnostics require iOS 26 or newer.")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(Color.secondary)
                        .padding(.vertical, 4)
                }
            } header: {
                Text("Developer Tools")
            } footer: {
                Text("Debug tools for App Attest. Only visible in DEBUG builds.")
            }
            #endif
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

// MARK: - Diagnostic Row Helper

private struct DiagnosticRow: View {
    let title: String
    let value: String
    let isGood: Bool
    
    var body: some View {
        HStack {
            Text(title)
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            HStack(spacing: 4) {
                Image(systemName: isGood ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(isGood ? Color.green : Color.red)
                
                Text(value)
                    .appFont(AppTextRole.caption)
                    .foregroundStyle(isGood ? Color.primary : Color.red)
            }
        }
    }
}
