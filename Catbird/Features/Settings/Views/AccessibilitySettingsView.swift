import SwiftUI

struct AccessibilitySettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Form {
            // Alt Text Section
            Section("Alt Text") {
                Toggle("Require Alt Text Before Posting", isOn: Binding(
                    get: { appState.appSettings.requireAltText },
                    set: { appState.appSettings.requireAltText = $0 }
                ))
                .tint(.blue)
                
                Toggle("Display Larger Alt Text Badges", isOn: Binding(
                    get: { appState.appSettings.largerAltTextBadges },
                    set: { appState.appSettings.largerAltTextBadges = $0 }
                ))
                .tint(.blue)
            }
            .listRowBackground(Color.systemGroupedBackground)
            
            // Motion Settings Section
            Section {
                Toggle("Reduce Motion", isOn: Binding(
                    get: { appState.appSettings.reduceMotion },
                    set: { appState.appSettings.reduceMotion = $0 }
                ))
                .tint(.blue)
                
                Toggle("Auto-play Videos", isOn: Binding(
                    get: { appState.appSettings.autoplayVideos },
                    set: { appState.appSettings.autoplayVideos = $0 }
                ))
                .tint(.blue)
                
                Toggle("Prefer Cross-fade Transitions", isOn: Binding(
                    get: { appState.appSettings.prefersCrossfade },
                    set: { appState.appSettings.prefersCrossfade = $0 }
                ))
                .tint(.blue)
                .disabled(!appState.appSettings.reduceMotion)
            } header: {
                Text("Motion Settings")
            } footer: {
                Text("Reduce Motion disables animations throughout the app. Cross-fade transitions replace sliding animations when Reduce Motion is on.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // Display Settings Section
            Section {
                Toggle("Increase Contrast", isOn: Binding(
                    get: { appState.appSettings.increaseContrast },
                    set: { appState.appSettings.increaseContrast = $0 }
                ))
                .tint(.blue)
                
                Toggle("Bold Text", isOn: Binding(
                    get: { appState.appSettings.boldText },
                    set: { appState.appSettings.boldText = $0 }
                ))
                .tint(.blue)
                
                // Preview component
                DisplayPreviewView(
                    increaseContrast: appState.appSettings.increaseContrast,
                    boldText: appState.appSettings.boldText
                )
                .padding(.vertical, 8)
            } header: {
                Text("Display Settings")
            } footer: {
                Text("These settings affect contrast and text weight. Text size is controlled by iOS Dynamic Type in Settings → Accessibility → Display & Text Size.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // Font & Typography Section
            Section {
                Picker("Font Style", selection: Binding(
                    get: { appState.appSettings.fontStyle },
                    set: { appState.appSettings.fontStyle = $0 }
                )) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Rounded").tag("rounded")
                    Text("Monospace").tag("monospaced")
                }
                
                Picker("Font Size", selection: Binding(
                    get: { appState.appSettings.fontSize },
                    set: { appState.appSettings.fontSize = $0 }
                )) {
                    Text("Small").tag("small")
                    Text("Default").tag("default")
                    Text("Large").tag("large")
                    Text("Extra Large").tag("extraLarge")
                }
                
                Picker("Line Spacing", selection: Binding(
                    get: { appState.appSettings.lineSpacing },
                    set: { appState.appSettings.lineSpacing = $0 }
                )) {
                    Text("Tight").tag("tight")
                    Text("Normal").tag("normal")
                    Text("Relaxed").tag("relaxed")
                }
                
                Toggle("Dynamic Type", isOn: Binding(
                    get: { appState.appSettings.dynamicTypeEnabled },
                    set: { appState.appSettings.dynamicTypeEnabled = $0 }
                ))
                .tint(.blue)
                
                if appState.appSettings.dynamicTypeEnabled {
                    Picker("Max Dynamic Type Size", selection: Binding(
                        get: { appState.appSettings.maxDynamicTypeSize },
                        set: { appState.appSettings.maxDynamicTypeSize = $0 }
                    )) {
                        Text("XXL").tag("xxLarge")
                        Text("XXXL").tag("xxxLarge")
                        Text("Accessibility 1").tag("accessibility1")
                        Text("Accessibility 2").tag("accessibility2")
                        Text("Accessibility 3").tag("accessibility3")
                        Text("Accessibility 4").tag("accessibility4")
                        Text("Accessibility 5").tag("accessibility5")
                    }
                }
                
                // Typography preview showing both custom preview and actual app fonts
                VStack(alignment: .leading, spacing: 8) {
                    TypographyPreviewView(
                        fontStyle: appState.appSettings.fontStyle,
                        fontSize: appState.appSettings.fontSize,
                        lineSpacing: appState.appSettings.lineSpacing,
                        dynamicTypeEnabled: appState.appSettings.dynamicTypeEnabled
                    )
                    
                    // Live app font preview
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live App Font Preview")
                            .appFont(AppTextRole.caption)
                            .foregroundStyle(.secondary)
                        
                        Text("App Title Example")
                            .appTitle()
                        
                        Text("App headline text that updates with your settings")
                            .appHeadline()
                        
                        Text("App body text that automatically reflects your typography preferences including font style, size, and spacing settings.")
                            .appBody()
                        
                        Text("App caption text")
                            .appCaption()
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.systemGray6)
                    )
                }
                .padding(.vertical, 8)
            } header: {
                Text("Font & Typography")
            } footer: {
                Text("Font settings affect text readability throughout the app. Dynamic Type allows the app to scale with your system accessibility settings.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // Reading Settings Section
            Section {
                Toggle("Show Reading Time Estimates", isOn: Binding(
                    get: { appState.appSettings.showReadingTimeEstimates },
                    set: { appState.appSettings.showReadingTimeEstimates = $0 }
                ))
                .tint(.blue)
                
                Toggle("Highlight Links", isOn: Binding(
                    get: { appState.appSettings.highlightLinks },
                    set: { appState.appSettings.highlightLinks = $0 }
                ))
                .tint(.blue)
                
                Picker("Link Style", selection: Binding(
                    get: { appState.appSettings.linkStyle },
                    set: { appState.appSettings.linkStyle = $0 }
                )) {
                    Text("Color Only").tag("color")
                    Text("Underline Only").tag("underline")
                    Text("Color & Underline").tag("both")
                }
                .disabled(!appState.appSettings.highlightLinks)
                
                // Link preview
                LinkPreviewView(
                    highlightLinks: appState.appSettings.highlightLinks,
                    linkStyle: appState.appSettings.linkStyle
                )
                .padding(.vertical, 8)
            } header: {
                Text("Reading Settings")
            } footer: {
                Text("Reading time estimates appear on longer posts. Link highlighting makes links easier to identify.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // Interaction Settings Section
            Section {
                Toggle("Confirm Before Actions", isOn: Binding(
                    get: { appState.appSettings.confirmBeforeActions },
                    set: { appState.appSettings.confirmBeforeActions = $0 }
                ))
                .tint(.blue)
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Long Press Duration")
                        Spacer()
                        Text("\(appState.appSettings.longPressDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                    
                    Slider(
                        value: Binding(
                            get: { appState.appSettings.longPressDuration },
                            set: { appState.appSettings.longPressDuration = $0 }
                        ),
                        in: 0.5...2.0,
                        step: 0.1
                    )
                    .tint(.blue)
                }
                
                Toggle("Shake to Undo", isOn: Binding(
                    get: { appState.appSettings.shakeToUndo },
                    set: { appState.appSettings.shakeToUndo = $0 }
                ))
                .tint(.blue)
            } header: {
                Text("Interaction Settings")
            } footer: {
                Text("Confirm Before Actions shows alerts for destructive actions like deleting posts. Long press duration affects context menus.")
                    .appFont(AppTextRole.footnote)
                    .foregroundStyle(.secondary)
            }
            
            // Haptics Section
            Section("Haptics") {
                Toggle("Disable Haptic Feedback", isOn: Binding(
                    get: { appState.appSettings.disableHaptics },
                    set: { appState.appSettings.disableHaptics = $0 }
                ))
                .tint(.blue)
            }
            
            // Info Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accessibility settings help make the app more usable for everyone.")
                        .appFont(AppTextRole.footnote)
                        .foregroundStyle(.secondary)
                    
                    Text("Content settings like adult content filtering can be found in the Content & Media section.")
                        .appFont(AppTextRole.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Accessibility")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    }
}

// MARK: - Preview Components

private struct DisplayPreviewView: View {
    let increaseContrast: Bool
    let boldText: Bool
    
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                // Sample post with accessibility settings applied
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 40, height: 40)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sample User")
                                .appFont(AppTextRole.headline)
                                .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: .light))
                            Text("@sampleuser")
                                .appFont(AppTextRole.caption)
                                .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .secondary, currentScheme: .light))
                        }
                        
                        Spacer()
                    }
                    
                    Text("This is how text will appear with your current accessibility settings. You can adjust the display scale, contrast, and bold text options above.")
                        .appFont(AppTextRole.body)
                        .foregroundStyle(Color.adaptiveText(appState: appState, themeManager: appState.themeManager, style: .primary, currentScheme: .light))
                    
                    HStack(spacing: 20) {
                        Button {} label: {
                            Label("Like", systemImage: "heart")
                                .appFont(AppTextRole.caption)
                        }
                        .buttonStyle(AccessibleButtonStyle(appState: appState))
                        
                        Button {} label: {
                            Label("Reply", systemImage: "bubble.left")
                                .appFont(AppTextRole.caption)
                        }
                        .buttonStyle(AccessibleButtonStyle(appState: appState))
                    }
                }
                .padding()
                .contrastAwareBackground(appState: appState, defaultColor: Color.systemGray6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.adaptiveBorder(appState: appState, themeManager: appState.themeManager, currentScheme: .light), lineWidth: appState.appSettings.increaseContrast ? 2 : 1)
                )
            }
        }
    }
}

private struct TypographyPreviewView: View {
    let fontStyle: String
    let fontSize: String
    let lineSpacing: String
    let dynamicTypeEnabled: Bool
    
    @Environment(AppState.self) private var appState
    
    var fontDesign: Font.Design {
        switch fontStyle {
        case "serif": return .serif
        case "rounded": return .rounded
        case "monospaced": return .monospaced
        default: return .default
        }
    }
    
    var sizeScale: CGFloat {
        let baseScale: CGFloat
        switch fontSize {
        case "small":
            baseScale = 0.85
        case "large":
            baseScale = 1.15
        case "extraLarge":
            baseScale = 1.3
        default:
            baseScale = 1.0
        }

        // Apply additional scaling for Mac Catalyst to match FontManager behavior
        #if os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return baseScale * 1.2
        }
        #endif

        return baseScale
    }
    
    var spacingMultiplier: CGFloat {
        switch lineSpacing {
        case "tight": return 0.8
        case "relaxed": return 1.3
        default: return 1.0
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Typography Preview")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Sample Headline")
                    .font(dynamicTypeEnabled ? 
                          Font.system(.headline, design: fontDesign) : 
                          .system(size: 17 * sizeScale, weight: .semibold, design: fontDesign))
                    .lineSpacing(17 * sizeScale * (spacingMultiplier - 1.0))
                
                Text("This is how your text will appear with the current typography settings. The font style, size, and spacing all contribute to readability.")
                    .font(dynamicTypeEnabled ? 
                          Font.system(.body, design: fontDesign) : 
                          .system(size: 16 * sizeScale, design: fontDesign))
                    .lineSpacing(16 * sizeScale * (spacingMultiplier - 1.0))
                    .foregroundStyle(.secondary)
                
                Text("Caption text example")
                    .font(dynamicTypeEnabled ? 
                          Font.system(.caption, design: fontDesign) : 
                          .system(size: 12 * sizeScale, design: fontDesign))
                    .lineSpacing(12 * sizeScale * (spacingMultiplier - 1.0))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.systemGray6)
            )
        }
    }
}

private struct LinkPreviewView: View {
    let highlightLinks: Bool
    let linkStyle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Link Preview")
                .appFont(AppTextRole.caption)
                .foregroundStyle(.secondary)
            
            (Text("Check out this ") +
            linkTextConcatenated("example link") +
            Text(" in a post."))
                .appFont(AppTextRole.subheadline)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.systemGray6)
        )
    }
    
    @ViewBuilder
    private func linkText(_ text: String) -> some View {
        let result = Text(text)
            .appFont(AppTextRole.subheadline)

        if highlightLinks {
            switch linkStyle {
            case "underline":
                result.underline()
            case "color":
                result.foregroundStyle(.blue)
            case "both":
                result.foregroundStyle(.blue).underline()
            default:
                result.foregroundStyle(.blue)
            }
        } else {
            result
        }
    }
    
    private func linkTextConcatenated(_ text: String) -> Text {
        var result = Text(text)
        
        if highlightLinks {
            switch linkStyle {
            case "underline":
                result = result.underline()
            case "color":
                result = result.foregroundStyle(.blue)
            case "both":
                result = result.foregroundStyle(.blue).underline()
            default:
                result = result.foregroundStyle(.blue)
            }
        }
        
        return result
    }
}

#Preview {
    NavigationStack {
        AccessibilitySettingsView()
            .environment(AppState.shared)
    }
}
