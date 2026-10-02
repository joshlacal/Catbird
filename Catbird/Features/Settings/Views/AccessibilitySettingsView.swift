import SwiftUI

struct AccessibilitySettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    Form {
      SettingsPersistenceStatusSection(settings: appState.appSettings)

      // Alt Text Section
      Section("Alt Text") {
        Toggle("Require Alt Text Before Posting", isOn: Binding(
          get: { appState.appSettings.requireAltText },
          set: { appState.appSettings.requireAltText = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Toggle("Display Larger Alt Text Badges", isOn: Binding(
          get: { appState.appSettings.largerAltTextBadges },
          set: { appState.appSettings.largerAltTextBadges = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)
      }
      .listRowBackground(Color.systemGroupedBackground)

      // Motion Settings Section
      Section {
        Toggle("Reduce Motion", isOn: Binding(
          get: { appState.appSettings.reduceMotion },
          set: { appState.appSettings.reduceMotion = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        NavigationLink("Video Autoplay") {
          ContentMediaSettingsView()
        }

        Toggle("Prefer Cross-fade Transitions", isOn: Binding(
          get: { appState.appSettings.prefersCrossfade },
          set: { appState.appSettings.prefersCrossfade = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings || !appState.appSettings.reduceMotion)
      } header: {
        Text("Motion Settings")
      } footer: {
        Text("Reduce Motion limits supported interface animations. Cross-fade transitions replace supported sliding transitions when Reduce Motion is on.")
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
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Toggle("Bold Text", isOn: Binding(
          get: { appState.appSettings.boldText },
          set: { appState.appSettings.boldText = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        // Preview component
        DisplayPreviewView(
          increaseContrast: appState.appSettings.increaseContrast,
          boldText: appState.appSettings.boldText
        )
        .padding(.vertical, 8)
      } header: {
        Text("Display Settings")
      } footer: {
        Text("These settings affect contrast and text weight in Catbird. Choose how Catbird follows your system text size below.")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
      }

      // Font & Typography Section
      Section {
        NavigationLink("Font Style, Size & Spacing") {
          AppearanceSettingsView()
        }

        #if !targetEnvironment(macCatalyst)
          Toggle("Dynamic Type", isOn: Binding(
            get: { appState.appSettings.dynamicTypeEnabled },
            set: { appState.appSettings.dynamicTypeEnabled = $0 }
          ))
          .tint(.blue)
          .disabled(!appState.appSettings.canEditPersistedSettings)

          if appState.appSettings.dynamicTypeEnabled {
            Picker("Maximum Text Size", selection: Binding(
              get: { appState.appSettings.maxDynamicTypeSize },
              set: { appState.appSettings.maxDynamicTypeSize = $0 }
            )) {
              Text("Extra Extra Large").tag("xxLarge")
              Text("Extra Extra Extra Large").tag("xxxLarge")
              Text("Accessibility Medium").tag("accessibility1")
              Text("Accessibility Large").tag("accessibility2")
              Text("Accessibility Extra Large").tag("accessibility3")
              Text("Accessibility Extra Extra Large").tag("accessibility4")
              Text("Accessibility Extra Extra Extra Large").tag("accessibility5")
            }
            .disabled(!appState.appSettings.canEditPersistedSettings)
          }

        #endif
      } header: {
        Text("Text Size")
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
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Toggle("Highlight Links", isOn: Binding(
          get: { appState.appSettings.highlightLinks },
          set: { appState.appSettings.highlightLinks = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

        Picker("Link Style", selection: Binding(
          get: { appState.appSettings.linkStyle },
          set: { appState.appSettings.linkStyle = $0 }
        )) {
          Text("Color Only").tag("color")
          Text("Underline Only").tag("underline")
          Text("Color & Underline").tag("both")
        }
        .disabled(!appState.appSettings.canEditPersistedSettings || !appState.appSettings.highlightLinks)

        // Link preview
        LinkPreviewView(
          highlightLinks: appState.appSettings.highlightLinks,
          linkStyle: appState.appSettings.linkStyle
        )
        .padding(.vertical, 8)
      } header: {
        Text("Reading Settings")
      } footer: {
        Text("Reading time estimates appear on posts with at least 100 words. Link highlighting makes links easier to identify.")
          .appFont(AppTextRole.footnote)
          .foregroundStyle(.secondary)
      }

      // Interaction Settings Section
      Section {
        Toggle("Confirm Social Actions", isOn: Binding(
          get: { appState.appSettings.confirmBeforeActions },
          set: { appState.appSettings.confirmBeforeActions = $0 }
        ))
        .tint(.blue)
        .disabled(!appState.appSettings.canEditPersistedSettings)

      } header: {
        Text("Interaction Settings")
      } footer: {
        Text("Ask before muting an account or thread, or unfollowing someone. Deleting posts and blocking accounts always require confirmation.")
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
        .disabled(!appState.appSettings.canEditPersistedSettings)
      }

      // Info Section
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("Accessibility settings help make the app more usable for everyone.")
            .appFont(AppTextRole.footnote)
            .foregroundStyle(.secondary)

          Text("Adult content and label filtering are managed in Moderation. Video autoplay is managed in Content & Media.")
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
  AsyncPreviewContent { appState in
    NavigationStack {
      AccessibilitySettingsView()
    }
  }
}
