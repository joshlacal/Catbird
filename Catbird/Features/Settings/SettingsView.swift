import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var isLoggingOut = false
    @State private var error: Error?
    @State private var handle: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text("Signed in as")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let handle {
                            Text(handle)
                                .fontWeight(.medium)
                        } else {
                            ProgressView()
                        }
                    }
                    
                    Section("Preferences") {
                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            HStack {
                                Label {
                                    Text("Notifications")
                                } icon: {
                                    Image(systemName: "bell.fill")
                                        .foregroundStyle(.blue)
                                }
                                
                                if appState.notificationManager.notificationsEnabled {
                                    Spacer()
                                    Text("On")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        
                        NavigationLink {
                            FeedFilterSettingsView()
                        } label: {
                            HStack {
                                Label {
                                    Text("Feed Filters")
                                } icon: {
                                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                                        .foregroundStyle(.indigo)
                                }
                                
                                Spacer()
                                Text("\(appState.feedFilterSettings.activeFilterIds.count) active")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        
                        NavigationLink {
                            MuteWordsSettingsView()
                        } label: {
                            Label {
                                Text("Mute Words")
                            } icon: {
                                Image(systemName: "speaker.slash.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    
                    Button(role: .destructive) {
                        Task {
                            await handleLogout()
                        }
                    } label: {
                        if isLoggingOut {
                            HStack {
                                Text("Signing out...")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Text("Sign Out")
                        }
                    }
                    .disabled(isLoggingOut)
                }
                
                Section {
                    HStack {
                        Text("Version")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Bundle.main.appVersionString)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") {
                    error = nil
                }
            } message: {
                if let error {
                    Text(error.localizedDescription)
                }
            }
            .task {
                do {
                    if let client = appState.atProtoClient {
                        handle = try await client.getHandle()
                    }
                } catch {
                    self.error = error
                }
            }
        }
    }
    
    private func handleLogout() async {
        isLoggingOut = true
        defer { isLoggingOut = false }
        
        do {
            try await appState.handleLogout()
            dismiss()
        } catch {
            self.error = error
        }
    }
}

// MARK: - Bundle Extension

extension Bundle {
    var appVersionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
