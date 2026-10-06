import SwiftUI
import Nuke
import WebKit

struct AdvancedSettingsHubView: View {
    let initialFocus: SettingsControlID?
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            Section("Current account") {
                SettingsLink(screen: .providers, summary: "Content and chat servers; changes apply when saved", systemImage: "server.rack", family: .advanced)
            }
            Section("This device") {
                #if DEBUG
                SettingsLink(screen: .systemLogs, summary: "View and export diagnostic logs", systemImage: "doc.text.magnifyingglass", family: .advanced)
                #endif
                SettingsLink(screen: .cache, summary: "Cached images and web media only", systemImage: "externaldrive", family: .advanced)
            }
        }
        .navigationTitle("Advanced")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
    }
}

struct SettingsCacheView: View {
    let initialFocus: SettingsControlID?
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var completed = false
    init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }
    var body: some View {
        SettingsFocusedForm(initialFocus: initialFocus) {
            SettingsScopeSection(scope: "This device")
            Section {
                Button("Clear Image & Web Cache", role: .destructive) { confirmingClear = true }
                    .disabled(clearing)
                    .settingsControl(.init(rawValue: "advanced.cache"))
                if clearing { ProgressView("Clearing cache…") }
                if completed { Text("Image and web caches cleared.").foregroundStyle(.secondary) }
            } footer: {
                Text("Removes cached images and web media stored by Catbird. Drafts, account data, and saved preferences are kept.")
            }
        }
        .navigationTitle("Image & Web Cache")
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog("Clear Image & Web Cache?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Cache", role: .destructive) { clearCache() }
            Button("Cancel", role: .cancel) { }
        }
    }
    private func clearCache() {
        clearing = true
        completed = false
        ImagePipeline.shared.cache.removeAll()
        WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {
            Task { @MainActor in clearing = false; completed = true }
        }
    }
}
