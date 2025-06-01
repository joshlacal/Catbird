import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    // Local state for AppSettings - initialize with defaults
    @State private var theme: String = "system"
    @State private var darkThemeMode: String = "dim"
    @State private var fontStyle: String = "system"
    @State private var fontSize: String = "default"
    @State private var lineSpacing: String = "normal"
    @State private var dynamicTypeEnabled: Bool = true
    @State private var maxDynamicTypeSize: String = "accessibility1"
    
    var body: some View {
        Form {
            // Theme Section
            Section("Theme") {
                Picker("App Theme", selection: $theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .onChange(of: theme) {
                    appState.appSettings.theme = theme
                }
                
                if theme == "dark" || (theme == "system" && colorScheme == .dark) {
                    Picker("Dark Mode Style", selection: $darkThemeMode) {
                        Text("Dim").tag("dim")
                        Text("True Black").tag("black")
                    }
                    .onChange(of: darkThemeMode) {
                        appState.appSettings.darkThemeMode = darkThemeMode
                    }
                }
            }
            .pickerStyle(.menu)
            
            // Typography Section
            Section("Typography") {
                Picker("Font Style", selection: $fontStyle) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Rounded").tag("rounded")
                    Text("Monospaced").tag("monospaced")
                }
                .onChange(of: fontStyle) {
                    appState.appSettings.fontStyle = fontStyle
                    // FontManager will be updated automatically via AppSettings notification
                }
                
                Picker("Font Size", selection: $fontSize) {
                    Text("Small").tag("small")
                    Text("Default").tag("default")
                    Text("Large").tag("large")
                    Text("Extra Large").tag("extraLarge")
                }
                .onChange(of: fontSize) {
                    appState.appSettings.fontSize = fontSize
                    // FontManager will be updated automatically via AppSettings notification
                }
                
                Picker("Line Spacing", selection: $lineSpacing) {
                    Text("Tight").tag("tight")
                    Text("Normal").tag("normal")
                    Text("Relaxed").tag("relaxed")
                }
                .onChange(of: lineSpacing) {
                    appState.appSettings.lineSpacing = lineSpacing
                    // FontManager will be updated automatically via AppSettings notification
                }
                
                FontPreviewRow(
                    fontStyle: fontStyle,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing,
                    dynamicTypeEnabled: dynamicTypeEnabled
                )
            }
            
            // Accessibility Section
            Section("Accessibility") {
                Toggle("Dynamic Type", isOn: $dynamicTypeEnabled)
                    .onChange(of: dynamicTypeEnabled) {
                        appState.appSettings.dynamicTypeEnabled = dynamicTypeEnabled
                        // FontManager will be updated automatically via AppSettings notification
                    }
                
                if dynamicTypeEnabled {
                    Picker("Maximum Text Size", selection: $maxDynamicTypeSize) {
                        Text("Extra Extra Large").tag("xxLarge")
                        Text("Extra Extra Extra Large").tag("xxxLarge")
                        Text("Accessibility Medium").tag("accessibility1")
                        Text("Accessibility Large").tag("accessibility2")
                        Text("Accessibility Extra Large").tag("accessibility3")
                        Text("Accessibility Extra Extra Large").tag("accessibility4")
                        Text("Accessibility Extra Extra Extra Large").tag("accessibility5")
                    }
                    .onChange(of: maxDynamicTypeSize) {
                        appState.appSettings.maxDynamicTypeSize = maxDynamicTypeSize
                        // FontManager will be updated automatically via AppSettings notification
                    }
                }
                
                AccessibilityQuickActionsRow()
            }
            .pickerStyle(.menu)
            
            // Colors Section
            Section("App Appearance") {
                ColorSchemePreview(
                    theme: theme,
                    darkThemeMode: darkThemeMode,
                    systemIsDark: colorScheme == .dark
                )
            }
            
            // Reset Section
            Section {
                Button("Reset to Defaults") {
                    // Reset to default values
                    theme = "system"
                    darkThemeMode = "dim"
                    fontStyle = "system"
                    fontSize = "default"
                    lineSpacing = "normal"
                    dynamicTypeEnabled = true
                    maxDynamicTypeSize = "accessibility1"
                    
                    // Update app settings
                    appState.appSettings.theme = theme
                    appState.appSettings.darkThemeMode = darkThemeMode
                    appState.appSettings.fontStyle = fontStyle
                    appState.appSettings.fontSize = fontSize
                    appState.appSettings.lineSpacing = lineSpacing
                    appState.appSettings.dynamicTypeEnabled = dynamicTypeEnabled
                    appState.appSettings.maxDynamicTypeSize = maxDynamicTypeSize
                    // FontManager will be updated automatically via AppSettings notification
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Sync local state with AppSettings safely with retry mechanism
            syncSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AppSettingsChanged"))) { _ in
            // Update local state when app settings change
            syncSettings()
        }
    }
    
    // MARK: - Helper Methods
    
    private func syncSettings() {
        // Use async dispatch to avoid blocking and ensure we're on main thread
        DispatchQueue.main.async {
            // Safely read settings with fallback values
            self.theme = self.appState.appSettings.theme
            self.darkThemeMode = self.appState.appSettings.darkThemeMode
            self.fontStyle = self.appState.appSettings.fontStyle
            self.fontSize = self.appState.appSettings.fontSize
            self.lineSpacing = self.appState.appSettings.lineSpacing
            self.dynamicTypeEnabled = self.appState.appSettings.dynamicTypeEnabled
            self.maxDynamicTypeSize = self.appState.appSettings.maxDynamicTypeSize
        }
    }
}

// MARK: - Preview Components

struct FontPreviewRow: View {
    let fontStyle: String
    let fontSize: String
    let lineSpacing: String
    let dynamicTypeEnabled: Bool
    
    var previewFont: Font {
        let size: CGFloat
        
        switch fontSize {
        case "small":
            size = 14
        case "large":
            size = 18
        case "extraLarge":
            size = 22
        default: // default
            size = 16
        }
        
        let design: Font.Design
        switch fontStyle {
        case "serif":
            design = .serif
        case "rounded":
            design = .rounded
        case "monospaced":
            design = .monospaced
        default: // system
            design = .default
        }
        
        if dynamicTypeEnabled {
            return .system(.body, design: design)
        } else {
            return .system(size: size, design: design)
        }
    }
    
    var previewLineSpacing: CGFloat {
        let baseSize: CGFloat = 16
        switch lineSpacing {
        case "tight":
            return baseSize * 0.3
        case "relaxed":
            return baseSize * 0.8
        default: // normal
            return baseSize * 0.5
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Preview")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Catbird for Bluesky")
                        .font(previewFont.bold())
                        .lineLimit(1)
                    
                    Text("This is how your text will appear throughout the app.")
                        .font(previewFont)
                        .lineSpacing(previewLineSpacing)
                        .lineLimit(2)
                    
                    HStack {
                        Text("@username")
                            .font(previewFont)
                            .foregroundStyle(.blue)
                        
                        Spacer()
                        
                        Text("21h")
                            .font(previewFont)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("#hashtag with 🔥 emojis")
                        .font(previewFont)
                        .foregroundStyle(.indigo)
                }
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 8)
    }
}

struct ColorSchemePreview: View {
    let theme: String
    let darkThemeMode: String
    let systemIsDark: Bool
    
    var isDarkMode: Bool {
        switch theme {
        case "light":
            return false
        case "dark":
            return true
        default: // "system"
            return systemIsDark
        }
    }
    
    var isBlackMode: Bool {
        return isDarkMode && darkThemeMode == "black"
    }
    
    var backgroundColor: Color {
        if !isDarkMode {
            return .white
        } else {
            return isBlackMode ? .black : Color(.systemGray6)
        }
    }
    
    var cardBackgroundColor: Color {
        if !isDarkMode {
            return Color(.secondarySystemBackground)
        } else {
            return isBlackMode ? Color(.systemGray6) : Color(.systemGray5)
        }
    }
    
    var textColor: Color {
        return isDarkMode ? .white : .black
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Preview")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            
            ZStack {
                Rectangle()
                    .fill(backgroundColor)
                    .frame(height: 220)
                    .cornerRadius(12)
                
                VStack(spacing: 12) {
                    HStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 32, height: 32)
                        Text("@username")
                            .foregroundStyle(textColor)
                        Spacer()
                    }
                    
                    Rectangle()
                        .fill(cardBackgroundColor)
                        .frame(height: 100)
                        .cornerRadius(8)
                        .overlay(
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Post content")
                                        .fontWeight(.medium)
                                        .foregroundStyle(textColor)
                                    
                                    Text("This is how your timeline will look with these settings")
                                        .appFont(AppTextRole.caption)
                                        .foregroundStyle(isDarkMode ? .gray : .secondary)
                                }
                                .padding(.leading, 10)
                                Spacer()
                            }
                        )
                    
                    HStack(spacing: 20) {
                        Label("12", systemImage: "bubble.left")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(isDarkMode ? .gray : .secondary)
                        
                        Label("43", systemImage: "arrow.2.squarepath")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(isDarkMode ? .gray : .secondary)
                        
                        Label("128", systemImage: "heart")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(isDarkMode ? .gray : .secondary)
                        
                        Spacer()
                    }
                }
                .padding()
            }
            
            Text("Current Theme: \(isDarkMode ? (isBlackMode ? "True Black" : "Dark (Dim)") : "Light")")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct AccessibilityQuickActionsRow: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .appFont(AppTextRole.subheadline)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Optimize for Reading") {
                    appState.appSettings.fontSize = "large"
                    appState.appSettings.lineSpacing = "relaxed"
                    appState.appSettings.dynamicTypeEnabled = true
                }
                .buttonStyle(.bordered)
                .appFont(AppTextRole.caption)
                
                Button("Maximum Accessibility") {
                    appState.appSettings.fontSize = "large"
                    appState.appSettings.lineSpacing = "relaxed"
                    appState.appSettings.dynamicTypeEnabled = true
                    appState.appSettings.maxDynamicTypeSize = "accessibility3"
                }
                .buttonStyle(.bordered)
                .appFont(AppTextRole.caption)
            }
        }
        .padding(.vertical, 8)
    }
    
    // Font manager updates are handled automatically via AppSettings notifications
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
            .environment(AppState())
    }
}
