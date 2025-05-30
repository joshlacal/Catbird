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
            .listRowBackground(Color(.systemGroupedBackground))
            
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
                    .font(.footnote)
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
                
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Display Scale")
                        Spacer()
                        Text("\(Int(appState.appSettings.displayScale * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    
                    Slider(
                        value: Binding(
                            get: { appState.appSettings.displayScale },
                            set: { appState.appSettings.displayScale = $0 }
                        ),
                        in: 0.85...1.15,
                        step: 0.05
                    )
                    .tint(.blue)
                }
                
                // Preview component
                DisplayPreviewView(
                    increaseContrast: appState.appSettings.increaseContrast,
                    boldText: appState.appSettings.boldText,
                    scale: appState.appSettings.displayScale
                )
                .padding(.vertical, 8)
            } header: {
                Text("Display Settings")
            } footer: {
                Text("These settings affect how content is displayed throughout the app.")
                    .font(.footnote)
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
                    .font(.footnote)
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
                    .font(.footnote)
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    
                    Text("Content settings like adult content filtering can be found in the Content & Media section.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Preview Components

private struct DisplayPreviewView: View {
    let increaseContrast: Bool
    let boldText: Bool
    let scale: Double
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Display Preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Sample Post")
                    .font(boldText ? .headline.bold() : .headline)
                    .scaleEffect(scale)
                
                Text("This is how your posts will appear with current display settings.")
                    .font(boldText ? .subheadline.bold() : .subheadline)
                    .foregroundStyle(increaseContrast ? .primary : .secondary)
                    .scaleEffect(scale)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                increaseContrast ? Color(.label) : Color(.systemGray4),
                                lineWidth: increaseContrast ? 2 : 1
                            )
                    )
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
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Check out this ")
                .font(.subheadline) +
            linkText("example link") +
            Text(" in a post.")
                .font(.subheadline)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }
    
    private func linkText(_ text: String) -> Text {
        var result = Text(text)
            .font(.subheadline)
        
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
            .environment(AppState())
    }
}