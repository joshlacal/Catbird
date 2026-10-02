import SwiftUI

struct AppearanceSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @State private var isShowingResetConfirmation = false

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

  private var accentColor: Binding<String> {
    Binding(
      get: { appState.appSettings.accentColor },
      set: { appState.appSettings.accentColor = $0 }
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

  var body: some View {
    Form {
      SettingsPersistenceStatusSection(settings: appState.appSettings)

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
      .disabled(!appState.appSettings.canEditPersistedSettings)

      #if os(iOS)
        if UIApplication.shared.supportsAlternateIcons {
          Section("App Icon") {
            NavigationLink(destination: AppIconSettingsView()) {
              HStack {
                Text("App Icon")
                Spacer()
                if let alternateName = UIApplication.shared.alternateIconName {
                  Text(alternateName == "CatbirdClassic" ? "Classic" : alternateName)
                    .foregroundStyle(.secondary)
                } else {
                  Text("Default")
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      #endif

      // Accent Color Section
      Section("Accent Color") {
        AccentColorPicker(selection: accentColor)
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)

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

        FontPreviewRow()
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)

      Section {
        NavigationLink("Text Scaling & Accessibility") {
          AccessibilitySettingsView()
        }
      } footer: {
        Text("System text scaling, contrast, motion, and reading aids are managed in Accessibility.")
      }

      // Colors Section
      Section("App Appearance") {
        ColorSchemePreview(
          theme: theme.wrappedValue,
          darkThemeMode: darkThemeMode.wrappedValue,
          systemIsDark: colorScheme == .dark,
          accentColorKey: accentColor.wrappedValue
        )
      }

      Section {
        Button("Reset Appearance…", role: .destructive) {
          isShowingResetConfirmation = true
        }
        .disabled(!appState.appSettings.canEditPersistedSettings)
      } footer: {
        Text("Resets the theme, accent color, and custom typography for this account. Your app icon and accessibility settings are kept.")
      }
    }
    .navigationTitle("Appearance")
    .confirmationDialog("Reset appearance?", isPresented: $isShowingResetConfirmation, titleVisibility: .visible) {
      Button("Reset Appearance", role: .destructive) {
        appState.appSettings.resetAppearanceToDefaults()
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)
      Button("Cancel", role: .cancel) { }
    } message: {
      Text("Reset the theme, accent color, and custom typography for this account? Accessibility, content, privacy, languages, and accounts will stay as they are.")
    }
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    // No manual sync needed - direct binding to AppSettings
  }
}

// MARK: - Accent Color Picker

struct AccentColorPicker: View {
  @Binding var selection: String

  private let columns = [GridItem(.adaptive(minimum: 60), spacing: 12)]

  var body: some View {
    LazyVGrid(columns: columns, spacing: 12) {
      ForEach(AccentColorOption.allCases) { option in
        Button {
          selection = option.rawValue
        } label: {
          VStack(spacing: 6) {
            Circle()
              .fill(option.color)
              .frame(width: 36, height: 36)
              .overlay {
                if selection == option.rawValue {
                  Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                }
              }
              .shadow(color: option.color.opacity(0.4), radius: 3, y: 1)

            Text(option.displayName)
              .font(.caption2)
              .foregroundStyle(selection == option.rawValue ? option.color : .secondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.displayName)
        .accessibilityAddTraits(selection == option.rawValue ? .isSelected : [])
      }
    }
    .padding(.vertical, 8)
  }
}

// MARK: - Preview Components

struct FontPreviewRow: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Font Preview")
        .appFont(AppTextRole.subheadline)
        .foregroundStyle(.secondary)
      GroupBox {
        VStack(alignment: .leading, spacing: 12) {
          Text("Catbird for Bluesky")
            .appFont(AppTextRole.headline)
          Text("A preview of Catbird’s post typography, including your text-size and readability choices.")
            .appFont(AppTextRole.body)
          Text("@username · 21h")
            .appFont(AppTextRole.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
  var accentColorKey: String = "default"

  private var accent: Color {
    (AccentColorOption(rawValue: accentColorKey) ?? .catbird).color
  }

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

      VStack(alignment: .leading, spacing: 12) {
        Label {
          Text("@username")
            .foregroundStyle(textColor)
        } icon: {
          Circle().fill(accent).frame(width: 32, height: 32)
        }
        VStack(alignment: .leading, spacing: 8) {
          Text("Post content")
            .appFont(AppTextRole.headline)
          Text("This is how your timeline colors will look with these settings.")
            .appFont(AppTextRole.body)
        }
        .foregroundStyle(textColor)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackgroundColor, in: .rect(cornerRadius: 8))
        Label("128 likes", systemImage: "heart")
          .appFont(AppTextRole.caption)
          .foregroundStyle(textColor)
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(backgroundColor, in: .rect(cornerRadius: 12))

      Text("Current Theme: \(isDarkMode ? (isBlackMode ? "True Black" : "Dark (Dim)") : "Light")")
        .appFont(AppTextRole.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}

#Preview {
  AsyncPreviewContent { appState in
    NavigationStack {
      AppearanceSettingsView()
    }
  }
}
