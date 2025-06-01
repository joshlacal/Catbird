import SwiftUI

/// Test view to demonstrate the comprehensive font settings system
struct FontSettingsTestView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Current Settings Display
                    currentSettingsSection
                    
                    // Font Role Examples
                    fontRoleExamplesSection
                    
                    // Interactive Example
                    interactiveExampleSection
                    
                    // Accessibility Features
                    accessibilityFeaturesSection
                }
                .padding()
            }
            .navigationTitle("Font Settings Demo")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: - Sections
    
    private var currentSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Font Settings")
                .appHeadline()
                .foregroundStyle(.primary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Style:")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appState.fontManager.fontStyle.capitalized)
                            .appCaption()
                            .foregroundStyle(.primary)
                    }
                    
                    HStack {
                        Text("Size:")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appState.fontManager.fontSize.capitalized)
                            .appCaption()
                            .foregroundStyle(.primary)
                    }
                    
                    HStack {
                        Text("Line Spacing:")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appState.fontManager.lineSpacing.capitalized)
                            .appCaption()
                            .foregroundStyle(.primary)
                    }
                    
                    HStack {
                        Text("Dynamic Type:")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(appState.fontManager.dynamicTypeEnabled ? "Enabled" : "Disabled")
                            .appCaption()
                            .foregroundStyle(.primary)
                    }
                    
                    HStack {
                        Text("Scale Factor:")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f%%", appState.fontManager.sizeScale * 100))
                            .appCaption()
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }
    
    private var fontRoleExamplesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Font Role Examples")
                .appHeadline()
                .foregroundStyle(.primary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Large Title Example")
                        .appFont(AppTextRole.largeTitle)
                        .lineLimit(1)
                    
                    Text("Title 1 Example")
                        .appFont(AppTextRole.title1)
                        .lineLimit(1)
                    
                    Text("Headline Example")
                        .appHeadline()
                        .lineLimit(1)
                    
                    Text("Subheadline Example")
                        .appSubheadline()
                        .lineLimit(1)
                    
                    Text("Body text example that demonstrates how the font settings affect readability throughout the app. This text will scale according to your preferences.")
                        .appBody()
                        .lineLimit(nil)
                    
                    Text("Caption Example")
                        .appCaption()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var interactiveExampleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Example")
                .appHeadline()
                .foregroundStyle(.primary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 16) {
                    // Post-like example
                    HStack(alignment: .top, spacing: 12) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 40, height: 40)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("John Doe")
                                    .appFont(AppTextRole.subheadline)
                                    .fontWeight(.semibold)
                                
                                Text("@johndoe")
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                                
                                Text("2h")
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                            
                            Text("This is an example post that shows how the font settings affect the readability of social media content. The text should scale appropriately based on your preferences. 📱✨")
                                .appBody()
                                .multilineTextAlignment(.leading)
                            
                            HStack(spacing: 20) {
                                Label("12", systemImage: "bubble.left")
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                                
                                Label("43", systemImage: "arrow.2.squarepath")
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                                
                                Label("128", systemImage: "heart")
                                    .appCaption()
                                    .foregroundStyle(.secondary)
                                
                                Spacer()
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private var accessibilityFeaturesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Accessibility Features")
                .appHeadline()
                .foregroundStyle(.primary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility Status")
                                .appCaption()
                                .foregroundStyle(.secondary)
                            Text(appState.fontManager.isAccessibilityOptimized ? "Optimized" : "Not Optimized")
                                .appBody()
                                .foregroundStyle(appState.fontManager.isAccessibilityOptimized ? .green : .orange)
                        }
                        
                        Spacer()
                        
                        if !appState.fontManager.isAccessibilityOptimized {
                            Button("Optimize") {
                                // Apply accessibility-optimized settings via AppSettings
                                appState.appSettings.fontSize = "large"
                                appState.appSettings.lineSpacing = "relaxed"
                                appState.appSettings.dynamicTypeEnabled = true
                                appState.appSettings.maxDynamicTypeSize = "accessibility3"
                                // FontManager will be updated automatically via notification
                            }
                            .buttonStyle(.bordered)
                            .appFont(AppTextRole.caption)
                        }
                    }
                    
                    Text("Benefits of Optimized Settings")
                        .appCaption()
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Larger, more readable text sizes", systemImage: "textformat.size")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        
                        Label("Improved line spacing for better readability", systemImage: "line.3.horizontal")
                            .appCaption()
                            .foregroundStyle(.secondary)
                        
                        Label("Dynamic Type support for system accessibility", systemImage: "accessibility")
                            .appCaption()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

#Preview {
    FontSettingsTestView()
        .environment(AppState())
}
