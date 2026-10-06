import SwiftUI

struct AppearanceSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @State private var isShowingResetConfirmation = false
  #if os(iOS)
  @State private var currentAppIcon: AppIconChoice = .default
  #endif
  var initialFocus: SettingsControlID? = nil

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

  private var usesDarkTheme: Bool { theme.wrappedValue == "dark" || (theme.wrappedValue == "system" && colorScheme == .dark) }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: appState.appSettings.persistenceState != .unavailable) {
      SettingsPersistenceStatusSection(settings: appState.appSettings)

      // Theme Section
      Section("Theme") {
        Picker("App Theme", selection: theme) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
          if !["system", "light", "dark"].contains(theme.wrappedValue) {
            Text("Custom").tag(theme.wrappedValue)
          }
        }
        .settingsControl(.init(rawValue: "appearance.theme"))

        if usesDarkTheme || initialFocus?.rawValue == "appearance.darkMode" {
          Picker("Dark Mode Style", selection: darkThemeMode) {
            Text("Dim").tag("dim")
            Text("True Black").tag("black")
            if !["dim", "black"].contains(darkThemeMode.wrappedValue) {
              Text("Custom").tag(darkThemeMode.wrappedValue)
            }
          }
          .disabled(!usesDarkTheme)
          .settingsControl(.init(rawValue: "appearance.darkMode"))
          if !usesDarkTheme { Text("Dark Mode Style is available when a dark theme is active.").foregroundStyle(.secondary) }
        }
      }
      .pickerStyle(.menu)
      .disabled(!appState.appSettings.canEditPersistedSettings)

      #if os(iOS)
        if UIApplication.shared.supportsAlternateIcons {
          Section("App Icon") {
            SettingsLink(screen: .appIcon, summary: currentAppIcon.displayName, systemImage: "app.badge", family: .appearance)
              .settingsControl(.init(rawValue: "appearance.appIcon"))
          }
        } else if initialFocus?.rawValue == "appearance.appIcon" {
          Section { Text("Custom app icons are not available on this device.").settingsControl(.init(rawValue: "appearance.appIcon")) }
        }
      #endif

      // Accent Color Section
      Section("Accent Color") {
        AccentColorPicker(selection: accentColor)
          .settingsControl(.init(rawValue: "appearance.accent"))
      }
      .disabled(!appState.appSettings.canEditPersistedSettings)

      Section {
        NavigationLink {
          TextReadabilitySettingsView()
        } label: {
          SettingsNavigationRow(title: "Text & Readability", summary: "Font, spacing, system text size and reading aids", systemImage: "textformat.size", family: .accessibility)
        }
        SettingsLink(screen: .accessibility, summary: "Motion, contrast, alt text and haptics", systemImage: "accessibility", family: .accessibility)
      } footer: {
        Text("Appearance and text choices apply to this account in Catbird on this device. The app icon applies to this device.")
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
        .settingsControl(.init(rawValue: "appearance.reset"))
      } footer: {
        Text("Resets the theme, accent color, and custom typography for this account. Your app icon and accessibility settings are kept.")
      }
    }
    .navigationTitle("Appearance")
    #if os(iOS)
    .onAppear { currentAppIcon = AppIconChoice.current }
    #endif
    .confirmationDialog("Reset Appearance?", isPresented: $isShowingResetConfirmation, titleVisibility: .visible) {
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
  @Environment(\.colorScheme) private var colorScheme

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
              .appFont(AppTextRole.caption2)
              .foregroundStyle(selection == option.rawValue ? (colorScheme == .dark ? option.textDarkColor : option.textColor) : .secondary)
          }
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
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
      // Matches the app's Dim theme background (Color.dynamicBackground).
      return isBlackMode ? .black : Color(red: 0.18, green: 0.18, blue: 0.20)
    }
  }

  var cardBackgroundColor: Color {
    if !isDarkMode {
      return Color(platformColor: PlatformColor.platformSecondarySystemBackground)
    } else {
      return isBlackMode ? Color.systemGray6 : Color(red: 0.25, green: 0.25, blue: 0.27)
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
