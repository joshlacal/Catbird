import SwiftUI

/// Test view to verify Dynamic Type integration with FontManager
struct DynamicTypeTestView: View {
    @Environment(\.fontManager) private var fontManager
    @Environment(\.sizeCategory) private var sizeCategory
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // System Dynamic Type info
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dynamic Type Test")
                        .appFont(AppTextRole.largeTitle)
                    
                    Text("Current Size Category: \(sizeCategory.description)")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("Dynamic Type Enabled: \(fontManager.dynamicTypeEnabled ? "Yes" : "No")")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("Font Size Setting: \(fontManager.fontSize)")
                        .appFont(AppTextRole.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.systemBackground))
                .cornerRadius(10)
                
                // Text samples with .appFont modifiers
                VStack(alignment: .leading, spacing: 12) {
                    Text("App Font Examples")
                        .appFont(AppTextRole.headline)
                        .padding(.bottom, 4)
                    
                    Text("Large Title")
                        .appLargeTitle()
                    
                    Text("Title 1")
                        .appTitle()
                    
                    Text("Title 2")
                        .appTitle2()
                    
                    Text("Title 3")
                        .appTitle3()
                    
                    Text("Headline")
                        .appHeadline()
                    
                    Text("Subheadline")
                        .appSubheadline()
                    
                    Text("Body - This is body text that should scale with both the app's font size preference and iOS Dynamic Type settings. When you change the text size in iOS Settings > Display & Brightness > Text Size, this text should grow or shrink accordingly.")
                        .appBody()
                    
                    Text("Callout")
                        .appCallout()
                    
                    Text("Footnote")
                        .appFootnote()
                    
                    Text("Caption")
                        .appCaption()
                    
                    Text("Caption 2")
                        .appCaption2()
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(10)
                
                // Custom sized text
                VStack(alignment: .leading, spacing: 12) {
                    Text("Custom App Font Sizes")
                        .appFont(AppTextRole.headline)
                        .padding(.bottom, 4)
                    
                    Text("14pt Custom")
                        .appText(size: 14)
                    
                    Text("16pt Custom")
                        .appText(size: 16)
                    
                    Text("18pt Custom Medium")
                        .appText(size: 18, weight: .medium)
                    
                    Text("20pt Custom Semibold")
                        .appText(size: 20, weight: .semibold)
                    
                    Text("24pt Custom Bold")
                        .appText(size: 24, weight: .bold)
                }
                .padding()
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(10)
                
                // Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Text("Testing Instructions")
                        .appFont(AppTextRole.headline)
                    
                    Text("1. Go to iOS Settings > Display & Brightness > Text Size")
                        .appFont(AppTextRole.body)
                    
                    Text("2. Adjust the slider to change Dynamic Type size")
                        .appFont(AppTextRole.body)
                    
                    Text("3. Return to this app - all text should scale accordingly")
                        .appFont(AppTextRole.body)
                    
                    Text("4. Try toggling Dynamic Type in the app's font settings")
                        .appFont(AppTextRole.body)
                    
                    Text("5. When disabled, text should only respond to the app's font size setting")
                        .appFont(AppTextRole.body)
                }
                .padding()
                .background(Color(.systemGroupedBackground))
                .cornerRadius(10)
            }
            .padding()
        }
        .navigationTitle("Dynamic Type Test")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// Helper extension for ContentSizeCategory description
extension ContentSizeCategory {
    var description: String {
        switch self {
        case .extraSmall: return "Extra Small"
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large (Default)"
        case .extraLarge: return "Extra Large"
        case .extraExtraLarge: return "Extra Extra Large"
        case .extraExtraExtraLarge: return "Extra Extra Extra Large"
        case .accessibilityMedium: return "Accessibility Medium"
        case .accessibilityLarge: return "Accessibility Large"
        case .accessibilityExtraLarge: return "Accessibility Extra Large"
        case .accessibilityExtraExtraLarge: return "Accessibility Extra Extra Large"
        case .accessibilityExtraExtraExtraLarge: return "Accessibility Extra Extra Extra Large"
        @unknown default: return "Unknown"
        }
    }
}

#Preview {
    NavigationStack {
        DynamicTypeTestView()
            .fontManager(FontManager())
    }
}
