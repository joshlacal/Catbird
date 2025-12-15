import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    // Direct binding to AppSettings - no local state needed
    private var theme: Binding<String> {
        Binding(
            get: { appState.appSettings.theme },
            set: { appState.appSettings.theme = $0 }
        )
    }
    
    private var darkThemeMode: Binding<String> {
        Binding(
            get: { appState.appSettings.darkThemeMode },
            set: { appState.appSettings.darkThemeMode = $0 }
        )
    }
    
    private var fontStyle: Binding<String> {
        Binding(
            get: { appState.appSettings.fontStyle },
            set: { appState.appSettings.fontStyle = $0 }
        )
    }
    
    private var fontSize: Binding<String> {
        Binding(
            get: { appState.appSettings.fontSize },
            set: { appState.appSettings.fontSize = $0 }
        )
    }
    
    private var lineSpacing: Binding<String> {
        Binding(
            get: { appState.appSettings.lineSpacing },
            set: { appState.appSettings.lineSpacing = $0 }
        )
    }
    
    private var dynamicTypeEnabled: Binding<Bool> {
        Binding(
            get: { appState.appSettings.dynamicTypeEnabled },
            set: { appState.appSettings.dynamicTypeEnabled = $0 }
        )
    }
    
    private var maxDynamicTypeSize: Binding<String> {
        Binding(
            get: { appState.appSettings.maxDynamicTypeSize },
            set: { appState.appSettings.maxDynamicTypeSize = $0 }
        )
    }
    
    var body: some View {
        Form {
            // Theme Section
            Section("Theme") {
                Picker("App Theme", selection: theme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                
                if theme.wrappedValue == "dark" || (theme.wrappedValue == "system" && colorScheme == .dark) {
                    Picker("Dark Mode Style", selection: darkThemeMode) {
                        Text("Dim").tag("dim")
                        Text("True Black").tag("black")
                    }
                }
            }
            .pickerStyle(.menu)
            
            // Typography Section
            Section("Typography") {
                Picker("Font Style", selection: fontStyle) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Rounded").tag("rounded")
                    Text("Monospaced").tag("monospaced")
                }
                
                Picker("Font Size", selection: fontSize) {
                    Text("Small").tag("small")
                    Text("Default").tag("default")
                    Text("Large").tag("large")
                    Text("Extra Large").tag("extraLarge")
                }
                
                Picker("Line Spacing", selection: lineSpacing) {
                    Text("Tight").tag("tight")
                    Text("Normal").tag("normal")
                    Text("Relaxed").tag("relaxed")
                }
                
                FontPreviewRow(
                    fontStyle: fontStyle.wrappedValue,
                    fontSize: fontSize.wrappedValue,
                    lineSpacing: lineSpacing.wrappedValue,
                    dynamicTypeEnabled: dynamicTypeEnabled.wrappedValue
                )
            }
            
            // Accessibility Section
            Section("Accessibility") {
                #if !targetEnvironment(macCatalyst)
                // Dynamic Type is iOS-specific; on Mac Catalyst it conflicts with app preferences
                Toggle("Dynamic Type", isOn: dynamicTypeEnabled)
                
                if dynamicTypeEnabled.wrappedValue {
                    Picker("Maximum Text Size", selection: maxDynamicTypeSize) {
                        Text("Extra Extra Large").tag("xxLarge")
                        Text("Extra Extra Extra Large").tag("xxxLarge")
                        Text("Accessibility Medium").tag("accessibility1")
                        Text("Accessibility Large").tag("accessibility2")
                        Text("Accessibility Extra Large").tag("accessibility3")
                        Text("Accessibility Extra Extra Large").tag("accessibility4")
                        Text("Accessibility Extra Extra Extra Large").tag("accessibility5")
                    }
                }
                #endif
                
                AccessibilityQuickActionsRow()
            }
            .pickerStyle(.menu)
            
            // Colors Section
            Section("App Appearance") {
                ColorSchemePreview(
                    theme: theme.wrappedValue,
                    darkThemeMode: darkThemeMode.wrappedValue,
                    systemIsDark: colorScheme == .dark
                )
            }
            
            // Reset Section
            Section {
                Button("Reset to Defaults") {
                    // Reset all settings to defaults
                    appState.appSettings.resetToDefaults()
                }
                .foregroundStyle(.red)
            }
        }
        .navigationTitle("Appearance")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
        .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
        // No manual sync needed - direct binding to AppSettings
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
            return isBlackMode ? .black : Color.systemGray6
        }
    }
    
    var cardBackgroundColor: Color {
        if !isDarkMode {
            return Color(platformColor: PlatformColor.platformSecondarySystemBackground)
        } else {
            return isBlackMode ? Color.systemGray6 : Color.systemGray5
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
                    // Apply settings for optimal reading experience
                    appState.appSettings.fontSize = "large"
                    appState.appSettings.lineSpacing = "relaxed"
                    #if !targetEnvironment(macCatalyst)
                    appState.appSettings.dynamicTypeEnabled = true
                    #endif
                    // Force immediate font manager update
                    // Force font update
                    appState.fontManager.applyFontSettings(
                        fontStyle: appState.appSettings.fontStyle,
                        fontSize: appState.appSettings.fontSize,
                        lineSpacing: appState.appSettings.lineSpacing,
                        letterSpacing: appState.appSettings.letterSpacing,
                        dynamicTypeEnabled: appState.appSettings.dynamicTypeEnabled,
                        maxDynamicTypeSize: appState.appSettings.maxDynamicTypeSize
                    )
                }
                .buttonStyle(.bordered)
                .appFont(AppTextRole.caption)
                
                Button("Maximum Accessibility") {
                    // Apply settings for maximum accessibility
                    appState.appSettings.fontSize = "extraLarge"
                    appState.appSettings.lineSpacing = "relaxed"
                    #if !targetEnvironment(macCatalyst)
                    appState.appSettings.dynamicTypeEnabled = true
                    appState.appSettings.maxDynamicTypeSize = "accessibility3"
                    #endif
                    // Force immediate font manager update
                    // Force font update
                    appState.fontManager.applyFontSettings(
                        fontStyle: appState.appSettings.fontStyle,
                        fontSize: appState.appSettings.fontSize,
                        lineSpacing: appState.appSettings.lineSpacing,
                        letterSpacing: appState.appSettings.letterSpacing,
                        dynamicTypeEnabled: appState.appSettings.dynamicTypeEnabled,
                        maxDynamicTypeSize: appState.appSettings.maxDynamicTypeSize
                    )
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
    @Previewable @Environment(AppState.self) var appState
    NavigationStack {
        AppearanceSettingsView()
            .applyAppStateEnvironment(appState)
    }
}
