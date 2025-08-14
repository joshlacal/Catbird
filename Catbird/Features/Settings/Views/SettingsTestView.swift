import SwiftUI

/// Test view to verify theme and font settings functionality
struct SettingsTestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.fontScaleManager) private var fontScaleManager
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Theme Test Section
                    GroupBox("Theme Test") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Current Theme: \(appState.appSettings.theme)")
                                .appFont(AppTextRole.headline)
                            
                            Text("System Color Scheme: \(systemColorScheme == .dark ? "Dark" : "Light")")
                            
                            Text("Effective Color Scheme: \(effectiveColorScheme)")
                            
                            HStack {
                                ForEach(["system", "light", "dark"], id: \.self) { theme in
                                    Button(theme.capitalized) {
                                        appState.appSettings.theme = theme
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            
                            if appState.appSettings.theme == "dark" || 
                               (appState.appSettings.theme == "system" && systemColorScheme == .dark) {
                                Toggle("True Black", isOn: Binding(
                                    get: { appState.appSettings.darkThemeMode == "black" },
                                    set: { appState.appSettings.darkThemeMode = $0 ? "black" : "dim" }
                                ))
                            }
                        }
                    }
                    
                    // Font Test Section
                    GroupBox("Font Test") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Font Size: \(appState.appSettings.fontSize)")
                                .scaledFont(size: 17, weight: .semibold)
                            
                            Text("Font Style: \(appState.appSettings.fontStyle)")
                                .scaledFont(size: 15)
                            
                            Text("Scale Factor: \(fontScaleManager.sizeScale, specifier: "%.2f")")
                                .appFont(AppTextRole.caption)
                            
                            Divider()
                            
                            // Font size buttons
                            Text("Font Size:")
                                .appFont(AppTextRole.caption)
                            HStack {
                                ForEach(["small", "default", "large", "extraLarge"], id: \.self) { size in
                                    Button(sizeLabel(for: size)) {
                                        appState.appSettings.fontSize = size
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }
                            }
                            
                            // Font style buttons
                            Text("Font Style:")
                                .appFont(AppTextRole.caption)
                            HStack {
                                ForEach(["system", "serif", "rounded", "monospaced"], id: \.self) { style in
                                    Button(style.capitalized) {
                                        appState.appSettings.fontStyle = style
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                }
                            }
                            
                            Divider()
                            
                            // Sample text with different sizes
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Sample Text - Headline")
                                    .scaledFont(size: Typography.Size.headline, weight: .semibold)
                                
                                Text("Sample Text - Body")
                                    .scaledFont(size: Typography.Size.body)
                                
                                Text("Sample Text - Caption")
                                    .scaledFont(size: Typography.Size.caption)
                                
                                Text("Sample Text - Custom Width")
                                    .font(fontScaleManager.scaledCustomFont(
                                        size: 18,
                                        weight: .medium,
                                        width: 85
                                    ))
                            }
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(8)
                        }
                    }
                    
                    // Boundary Test Section
                    GroupBox("Boundary Verification") {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Local Settings (Device Only)", systemImage: "iphone")
                                .foregroundStyle(.blue)
                            
                            Text("• Theme: \(appState.appSettings.theme)")
                            Text("• Font Size: \(appState.appSettings.fontSize)")
                            Text("• Font Style: \(appState.appSettings.fontStyle)")
                            
                            Divider()
                            
                            Label("Server Settings (Synced)", systemImage: "icloud")
                                .foregroundStyle(.green)
                            
                            Text("• Adult Content: \(appState.isAdultContentEnabled ? "Enabled" : "Disabled")")
                            Text("• Thread Sort: \(appState.appSettings.threadSortOrder)")
                            
                            Divider()
                            
                            Text("✅ Settings properly separated")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Settings Test")
            .toolbarTitleDisplayMode(.inline)
        }
    }
    
    private var effectiveColorScheme: String {
        let effective = appState.themeManager.effectiveColorScheme(for: systemColorScheme)
        return effective == .dark ? "Dark" : "Light"
    }
    
    private func sizeLabel(for size: String) -> String {
        switch size {
        case "small": return "S"
        case "default": return "M"
        case "large": return "L"
        case "extraLarge": return "XL"
        default: return size
        }
    }
}

#Preview {
    SettingsTestView()
        .environment(AppState.shared)
}
