import SwiftUI
import NukeUI
import WebKit
import Nuke

struct AboutSettingsView: View {
    @Environment(AppState.self) private var appState
    
    @State private var isClearingCache = false
    
    var body: some View {
        Form {
            Section {
                Link(destination: URL(string: "https://bsky.social/about/support/tos")!) {
                    HStack {
                        Text("Terms of Service")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Link(destination: URL(string: "https://bsky.social/about/support/privacy-policy")!) {
                    HStack {
                        Text("Privacy Policy")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Link(destination: URL(string: "https://status.bsky.app")!) {
                    HStack {
                        Text("Status Page")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Section("Support") {
                NavigationLink("System Log") {
                    SystemLogView()
                }
                
                Button {
                    clearImageCache()
                } label: {
                    if isClearingCache {
                        HStack {
                            Text("Clearing cache...")
                            Spacer()
                            ProgressView()
                        }
                    } else {
                        Text("Clear Image Cache")
                    }
                }
                .disabled(isClearingCache)
            }
            
            Section {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(Bundle.main.appVersionString)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("Build")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
                        .foregroundStyle(.secondary)
                }
            }
            
            Section {
                Image(systemName: "bird.fill")
                    .appFont(size: 48)
                    .foregroundStyle(.blue)
                    .padding(.top, 8)

                VStack(alignment: .center, spacing: 12) {
                    Text("Catbird")
                        .appFont(AppTextRole.headline)
                    
                    Text("A native Bluesky client for iOS")
                        .appFont(AppTextRole.subheadline)
                        .foregroundStyle(.secondary)
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func clearImageCache() {
        isClearingCache = true
        
        // Clear Nuke image cache
        ImagePipeline.shared.cache.removeAll()
        
        // Clear WKWebView cache
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            DispatchQueue.main.async {
                isClearingCache = false
            }
        }
    }
}

struct SystemLogView: View {
    @State private var logEntries: [LogEntry] = []
    @State private var isLoading = true
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: LogLevel
        let message: String
        let subsystem: String
        let category: String
        
        enum LogLevel: String {
            case debug = "DEBUG"
            case info = "INFO"
            case warning = "WARNING"
            case error = "ERROR"
            
            var color: Color {
                switch self {
                case .debug: return .secondary
                case .info: return .blue
                case .warning: return .orange
                case .error: return .red
                }
            }
        }
    }
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
                    .padding()
            } else if logEntries.isEmpty {
                Text("No log entries found")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(logEntries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.level.rawValue)
                                    .appFont(AppTextRole.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(entry.level.color)
                                
                                Text(entry.subsystem)
                                    .appFont(AppTextRole.caption)
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                                
                                Text(formatDate(entry.timestamp))
                                    .appFont(AppTextRole.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Text(entry.message)
                                .appFont(AppTextRole.callout)
                                .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle("System Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        shareLog()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    
                    Button(role: .destructive) {
                        logEntries = []
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            loadLogs()
        }
    }
    
    private func loadLogs() {
        isLoading = true
        
        // This is a mock implementation - in a real app, you would load actual logs
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            logEntries = [
                LogEntry(
                    timestamp: Date(),
                    level: .info,
                    message: "App started successfully",
                    subsystem: "blue.catbird",
                    category: "AppState"
                ),
                LogEntry(
                    timestamp: Date().addingTimeInterval(-60),
                    level: .debug,
                    message: "Fetched timeline with 50 posts",
                    subsystem: "blue.catbird",
                    category: "FeedManager"
                ),
                LogEntry(
                    timestamp: Date().addingTimeInterval(-120),
                    level: .warning,
                    message: "Network request timeout, retrying",
                    subsystem: "blue.catbird",
                    category: "NetworkManager"
                ),
                LogEntry(
                    timestamp: Date().addingTimeInterval(-180),
                    level: .error,
                    message: "Failed to load images: Connection error",
                    subsystem: "blue.catbird",
                    category: "ImageLoader"
                )
            ]
            isLoading = false
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    private func shareLog() {
        // Create a log string
        let logString = logEntries.map { entry in
            "[\(formatDate(entry.timestamp))] [\(entry.level.rawValue)] [\(entry.subsystem)] \(entry.message)"
        }.joined(separator: "\n")
        
        // Create a temporary file
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory
        let temporaryFileURL = temporaryDirectoryURL.appendingPathComponent("catbird_log.txt")
        
        do {
            try logString.write(to: temporaryFileURL, atomically: true, encoding: .utf8)
            
            // Share the file
            let activityVC = UIActivityViewController(
                activityItems: [temporaryFileURL],
                applicationActivities: nil
            )
            
            // Present the share sheet
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(activityVC, animated: true)
            }
        } catch {
            logger.debug("Error creating log file: \(error)")
        }
    }
}

#Preview {
    NavigationStack {
        AboutSettingsView()
            .environment(AppState())
    }
}
