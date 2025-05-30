import SwiftUI

/// Test view to verify the new theming system works correctly
struct ThemeTestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Current theme status
                    ThemeStatusCard()
                    
                    // Theme comparison side by side
                    ThemeComparisonView()
                    
                    // Background hierarchy test
                    BackgroundHierarchyTest()
                    
                    // Glass effects test
                    GlassEffectsTest()
                    
                    // Interactive elements test
                    InteractiveElementsTest()
                    
                    // List components test
                    ListComponentsTest()
                    
                    // Accessibility test
                    AccessibilityTest()
                    
                    // Theme switching controls
                    ThemeControlsTest()
                }
                .padding()
            }
            .themedPrimaryBackground(appState.themeManager)
            .navigationTitle("Theme Test")
            .navigationBarTitleDisplayMode(.inline)
        }
        .applyTheme(appState.themeManager)
    }
}

// MARK: - Test Components

struct ThemeStatusCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Theme Status")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Color Scheme:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(colorScheme == .dark ? "Dark" : "Light")
                        .fontWeight(.medium)
                        .themedText(appState.themeManager, style: .primary)
                }
                
                HStack {
                    Text("Theme Override:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(themeOverrideText)
                        .fontWeight(.medium)
                        .themedText(appState.themeManager, style: .primary)
                }
                
                HStack {
                    Text("Dark Mode Style:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(appState.themeManager.isUsingTrueBlack ? "True Black" : "Dim")
                        .fontWeight(.medium)
                        .foregroundStyle(appState.themeManager.isUsingTrueBlack ? .red : .blue)
                }
                
                HStack {
                    Text("Is Dark Mode:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(appState.themeManager.isDarkMode(for: colorScheme) ? "Yes" : "No")
                        .fontWeight(.medium)
                        .themedText(appState.themeManager, style: .primary)
                }
            }
            .font(.body)
        }
        .padding()
        .themedElevatedBackground(appState.themeManager, elevation: .low)
        .cornerRadius(12)
        .themedSolariumCard(themeManager: appState.themeManager)
    }
    
    private var themeOverrideText: String {
        switch appState.themeManager.colorSchemeOverride {
        case .light: return "Light"
        case .dark: return "Dark"
        case nil: return "System"
        @unknown default: return "Unknown"
        }
    }
}

struct ThemeComparisonView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theme Comparison")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            HStack(spacing: 16) {
                // Dim mode preview
                VStack {
                    Text("Dim Mode")
                        .font(.caption)
                        .themedText(appState.themeManager, style: .secondary)
                    
                    MockThemePreview(isDarkMode: true, isBlackMode: false)
                }
                .frame(maxWidth: .infinity)
                
                // True black preview
                VStack {
                    Text("True Black")
                        .font(.caption)
                        .themedText(appState.themeManager, style: .secondary)
                    
                    MockThemePreview(isDarkMode: true, isBlackMode: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .themedSecondaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
}

struct MockThemePreview: View {
    let isDarkMode: Bool
    let isBlackMode: Bool
    
    var body: some View {
        VStack(spacing: 8) {
            // Mock navigation bar
            HStack {
                Text("Title")
                    .font(.caption2)
                    .foregroundColor(textColor(.primary))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor(.base))
            
            // Mock content
            VStack(spacing: 4) {
                ForEach(0..<3) { i in
                    HStack {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 20, height: 20)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Rectangle()
                                .fill(textColor(.primary))
                                .frame(height: 4)
                                .frame(maxWidth: .infinity)
                            
                            Rectangle()
                                .fill(textColor(.secondary))
                                .frame(height: 3)
                                .frame(maxWidth: 60)
                        }
                    }
                    .padding(6)
                    .background(backgroundColor(i == 1 ? .low : .base))
                    .cornerRadius(4)
                }
            }
            .padding(8)
            
            // Mock tab bar
            HStack {
                ForEach(0..<4) { _ in
                    Image(systemName: "square.fill")
                        .font(.caption2)
                        .foregroundColor(textColor(.secondary))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
            .background(backgroundColor(.base))
        }
        .background(backgroundColor(.base))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor(), lineWidth: 1)
        )
    }
    
    private func backgroundColor(_ elevation: ColorElevation) -> Color {
        if !isDarkMode {
            switch elevation {
            case .base: return Color(UIColor.systemBackground)
            case .low: return Color(UIColor.secondarySystemBackground)
            default: return Color(UIColor.tertiarySystemBackground)
            }
        }
        
        if isBlackMode {
            switch elevation {
            case .base: return Color(white: 0.0)
            case .low: return Color(white: 0.02)
            case .medium: return Color(white: 0.04)
            case .high: return Color(white: 0.06)
            case .modal: return Color(white: 0.08)
            case .popover: return Color(white: 0.10)
            }
        } else {
            switch elevation {
            case .base: return Color(red: 0.11, green: 0.11, blue: 0.118)
            case .low: return Color(red: 0.14, green: 0.14, blue: 0.153)
            case .medium: return Color(red: 0.157, green: 0.157, blue: 0.169)
            case .high: return Color(red: 0.18, green: 0.18, blue: 0.19)
            case .modal: return Color(red: 0.212, green: 0.212, blue: 0.224)
            case .popover: return Color(red: 0.24, green: 0.24, blue: 0.25)
            }
        }
    }
    
    private func textColor(_ style: TextStyle) -> Color {
        if !isDarkMode {
            switch style {
            case .primary: return .primary
            case .secondary: return .secondary
            case .tertiary: return Color(.tertiaryLabel)
            case .disabled: return Color(.quaternaryLabel)
            }
        }
        
        if isBlackMode {
            switch style {
            case .primary: return Color(white: 0.95)
            case .secondary: return Color(white: 0.70)
            case .tertiary: return Color(white: 0.50)
            case .disabled: return Color(white: 0.35)
            }
        } else {
            switch style {
            case .primary: return Color(white: 0.92)
            case .secondary: return Color(white: 0.65)
            case .tertiary: return Color(white: 0.45)
            case .disabled: return Color(white: 0.30)
            }
        }
    }
    
    private func borderColor() -> Color {
        if !isDarkMode {
            return Color(.systemGray5)
        }
        
        if isBlackMode {
            return Color(white: 0.20, opacity: 0.3)
        } else {
            return Color(white: 0.25, opacity: 0.3)
        }
    }
}

struct BackgroundHierarchyTest: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Background Hierarchy Test")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(spacing: 12) {
                BackgroundTestRow(
                    title: "Primary Background",
                    description: "Main app background"
                ) {
                    Rectangle()
                        .themedPrimaryBackground(appState.themeManager)
                }
                
                BackgroundTestRow(
                    title: "Secondary Background", 
                    description: "Content areas"
                ) {
                    Rectangle()
                        .themedSecondaryBackground(appState.themeManager)
                }
                
                BackgroundTestRow(
                    title: "Tertiary Background",
                    description: "Subtle areas"
                ) {
                    Rectangle()
                        .themedTertiaryBackground(appState.themeManager)
                }
                
                BackgroundTestRow(
                    title: "Elevated (Low)",
                    description: "Cards"
                ) {
                    Rectangle()
                        .themedElevatedBackground(appState.themeManager, elevation: .low)
                }
                
                BackgroundTestRow(
                    title: "Elevated (Medium)",
                    description: "Elevated cards"
                ) {
                    Rectangle()
                        .themedElevatedBackground(appState.themeManager, elevation: .medium)
                }
                
                BackgroundTestRow(
                    title: "Elevated (High)",
                    description: "Modals"
                ) {
                    Rectangle()
                        .themedElevatedBackground(appState.themeManager, elevation: .high)
                }
                
                BackgroundTestRow(
                    title: "Grouped Background",
                    description: "List backgrounds"
                ) {
                    Rectangle()
                        .themedGroupedBackground(appState.themeManager)
                }
            }
        }
        .padding()
        .themedSecondaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
}

struct BackgroundTestRow<Background: View>: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let description: String
    let background: () -> Background
    
    var body: some View {
        HStack(spacing: 12) {
            background()
                .frame(width: 50, height: 30)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .themedText(appState.themeManager, style: .primary)
                
                Text(description)
                    .font(.caption)
                    .themedText(appState.themeManager, style: .secondary)
            }
            
            Spacer()
        }
    }
}

struct GlassEffectsTest: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Glass Effects Test")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(spacing: 12) {
                Text("Subtle Glass Card")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .themedSolariumCard(
                        intensity: .subtle,
                        themeManager: appState.themeManager
                    )
                
                Text("Medium Glass Card")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .themedSolariumCard(
                        intensity: .medium,
                        themeManager: appState.themeManager
                    )
                
                Text("Strong Glass Card")
                    .padding()
                    .frame(maxWidth: .infinity)
                    .themedSolariumCard(
                        intensity: .strong,
                        themeManager: appState.themeManager
                    )
                
                HStack {
                    Text("Glass Button")
                        .themedSolariumButton(
                            intensity: .subtle,
                            themeManager: appState.themeManager
                        )
                    
                    Text("Glass Button")
                        .themedSolariumButton(
                            intensity: .medium,
                            themeManager: appState.themeManager
                        )
                    
                    Text("Glass Button")
                        .themedSolariumButton(
                            intensity: .strong,
                            themeManager: appState.themeManager
                        )
                }
            }
        }
        .padding()
        .themedTertiaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
}

struct InteractiveElementsTest: View {
    @Environment(AppState.self) private var appState
    @State private var isToggled = false
    @State private var sliderValue = 0.5
    @State private var selectedOption = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Interactive Elements Test")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(spacing: 12) {
                // Buttons
                HStack {
                    Button("Primary") {}
                        .buttonStyle(.borderedProminent)
                    
                    Button("Secondary") {}
                        .buttonStyle(.bordered)
                    
                    Button("Plain") {}
                        .buttonStyle(.plain)
                }
                
                Divider()
                    .themedDivider(appState.themeManager)
                
                // Toggle
                Toggle("Toggle Option", isOn: $isToggled)
                    .themedText(appState.themeManager, style: .primary)
                
                // Slider
                VStack(alignment: .leading) {
                    Text("Slider: \(Int(sliderValue * 100))%")
                        .font(.caption)
                        .themedText(appState.themeManager, style: .secondary)
                    
                    Slider(value: $sliderValue)
                }
                
                // Picker
                Picker("Options", selection: $selectedOption) {
                    Text("Option 1").tag(0)
                    Text("Option 2").tag(1)
                    Text("Option 3").tag(2)
                }
                .pickerStyle(.segmented)
            }
        }
        .padding()
        .themedElevatedBackground(appState.themeManager, elevation: .low)
        .cornerRadius(12)
    }
}

struct ListComponentsTest: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("List Components Test")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            // Simulated list rows
            VStack(spacing: 0) {
                ForEach(0..<3) { index in
                    ThemeTestListItemRow(index: index, appState: appState)
                    
                    if index < 2 {
                        Divider()
                            .themedDivider(appState.themeManager)
                    }
                }
            }
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.dynamicBorder(appState.themeManager, currentScheme: colorScheme), lineWidth: 1)
            )
        }
        .padding()
        .themedSecondaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
}

struct AccessibilityTest: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Accessibility Test")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Differentiate Without Color:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(differentiateWithoutColor ? "Enabled" : "Disabled")
                        .themedText(appState.themeManager, style: .primary)
                }
                
                HStack {
                    Text("Reduce Transparency:")
                        .themedText(appState.themeManager, style: .secondary)
                    Spacer()
                    Text(reduceTransparency ? "Enabled" : "Disabled")
                        .themedText(appState.themeManager, style: .primary)
                }
            }
            
            Text("Adaptive Contrast Example")
                .padding()
                .frame(maxWidth: .infinity)
                .themedElevatedBackground(appState.themeManager)
                .cornerRadius(8)
                .adaptiveContrast(appState.themeManager)
        }
        .padding()
        .themedTertiaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
}

struct ThemeControlsTest: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theme Controls")
                .font(.headline)
                .themedText(appState.themeManager, style: .primary)
            
            VStack(spacing: 12) {
                // Theme picker
                Picker("Theme", selection: Binding(
                    get: { appState.appSettings.theme },
                    set: { appState.appSettings.theme = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                
                // Dark mode style picker
                if appState.appSettings.theme == "dark" || 
                   (appState.appSettings.theme == "system" && colorScheme == .dark) {
                    Picker("Dark Mode Style", selection: Binding(
                        get: { appState.appSettings.darkThemeMode },
                        set: { appState.appSettings.darkThemeMode = $0 }
                    )) {
                        Text("Dim").tag("dim")
                        Text("True Black").tag("black")
                    }
                    .pickerStyle(.segmented)
                }
                
                // Quick toggle button
                Button(toggleButtonText) {
                    toggleDarkModeStyle()
                }
                .frame(maxWidth: .infinity)
                .themedSolariumButton(themeManager: appState.themeManager)
                
                // Test haptic feedback
                Button("Test Haptic Feedback") {
                    // Light haptic for theme switch
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .frame(maxWidth: .infinity)
                .themedSolariumButton(
                    intensity: .subtle,
                    themeManager: appState.themeManager
                )
            }
        }
        .padding()
        .themedSecondaryBackground(appState.themeManager)
        .cornerRadius(12)
    }
    
    private var toggleButtonText: String {
        if appState.themeManager.isDarkMode(for: colorScheme) {
            return appState.themeManager.isUsingTrueBlack ? "Switch to Dim" : "Switch to True Black"
        } else {
            return "Switch to Dark Mode"
        }
    }
    
    private func toggleDarkModeStyle() {
        // Add haptic feedback
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        
        if !appState.themeManager.isDarkMode(for: colorScheme) {
            // If in light mode, switch to dark with true black
            appState.appSettings.theme = "dark"
            appState.appSettings.darkThemeMode = "black"
        } else {
            // If in dark mode, toggle between dim and black
            appState.appSettings.darkThemeMode = appState.appSettings.darkThemeMode == "black" ? "dim" : "black"
        }
        
        // Apply the theme immediately
        appState.themeManager.applyTheme(
            theme: appState.appSettings.theme,
            darkThemeMode: appState.appSettings.darkThemeMode
        )
    }
}

// MARK: - List Item Row Component

private struct ThemeTestListItemRow: View {
    let index: Int
    let appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    
    var body: some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .themedText(appState.themeManager, style: .secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("List Item \(index + 1)")
                    .font(.body)
                    .themedText(appState.themeManager, style: .primary)
                
                Text("Subtitle text here")
                    .font(.caption)
                    .themedText(appState.themeManager, style: .secondary)
            }
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.caption)
                .themedText(appState.themeManager, style: .tertiary)
        }
        .padding()
        .background(
            index % 2 == 0
                ? Color.dynamicBackground(appState.themeManager, currentScheme: colorScheme)
                : Color.dynamicSecondaryBackground(appState.themeManager, currentScheme: colorScheme)
        )
    }
}

// MARK: - Preview

#Preview {
    ThemeTestView()
        .environment(AppState())
}