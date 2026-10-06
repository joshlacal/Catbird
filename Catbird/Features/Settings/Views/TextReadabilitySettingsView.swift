import SwiftUI

struct TextReadabilitySettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  var initialFocus: SettingsControlID? = nil

  private var canEdit: Bool { appState.appSettings.canEditPersistedSettings }
  private var palette: AccentColorOption { AccentColorOption(rawValue: appState.appSettings.accentColor) ?? .catbird }
  private var accent: Color { colorScheme == .dark ? palette.darkColor : palette.color }
  private var linkAccent: Color { colorScheme == .dark ? palette.textDarkColor : palette.textColor }

  private func string(_ path: ReferenceWritableKeyPath<AppSettings, String>) -> Binding<String> {
    Binding(get: { appState.appSettings[keyPath: path] }, set: { appState.appSettings[keyPath: path] = $0 })
  }

  private func bool(_ path: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
    Binding(get: { appState.appSettings[keyPath: path] }, set: { appState.appSettings[keyPath: path] = $0 })
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: appState.appSettings.persistenceState != .unavailable) {
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        FontPreviewRow()
      } footer: {
        Text("These choices apply to this account in Catbird on this device.")
      }

      Section("Font & Spacing") {
        preferencePicker("Font Style", path: \.fontStyle, choices: [("system", "System"), ("serif", "Serif"), ("rounded", "Rounded"), ("monospaced", "Monospaced")], id: "text.fontStyle")
        preferencePicker("App Text Size", path: \.fontSize, choices: [("small", "Small"), ("default", "Default"), ("large", "Large"), ("extraLarge", "Extra Large")], id: "text.fontSize")
        preferencePicker("Line Spacing", path: \.lineSpacing, choices: [("tight", "Tight"), ("normal", "Normal"), ("relaxed", "Relaxed")], id: "text.lineSpacing")
        preferencePicker("Letter Spacing", path: \.letterSpacing, choices: [("tight", "Tight"), ("normal", "Normal"), ("loose", "Loose")], id: "text.letterSpacing")
      }
      .disabled(!canEdit)

      #if os(iOS) && !targetEnvironment(macCatalyst)
      Section {
        Toggle("Use System Text Size", isOn: bool(\.dynamicTypeEnabled))
          .settingsControl(.init(rawValue: "text.dynamicType"))
        if appState.appSettings.dynamicTypeEnabled || initialFocus?.rawValue == "text.maxSize" {
          maximumTextSizePicker
            .disabled(!appState.appSettings.dynamicTypeEnabled)
        }
        if !appState.appSettings.dynamicTypeEnabled {
          Text("Turn on Use System Text Size to follow the system setting and choose its maximum.")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("System Text Size")
      } footer: {
        Text("Full System Range follows every system text size, including accessibility sizes. A selected maximum keeps your existing limit. App Text Size adjusts the font size alongside this choice.")
      }
      .disabled(!canEdit)
      #else
      Section {
        Text("On this platform, Catbird uses App Text Size, Font Style and spacing. Your stored system text-size choice is kept in this account’s preferences.")
          .foregroundStyle(.secondary)
          .settingsControl(.init(rawValue: "text.dynamicType"))
        LabeledContent("Saved Maximum", value: AppTextSizeLimit.title(for: appState.appSettings.maxDynamicTypeSize))
          .settingsControl(.init(rawValue: "text.maxSize"))
      }
      #endif

      Section {
        Toggle("Show Reading Time Estimates", isOn: bool(\.showReadingTimeEstimates))
          .settingsControl(.init(rawValue: "text.readingTime"))
        Toggle("Highlight Links", isOn: bool(\.highlightLinks))
          .settingsControl(.init(rawValue: "text.highlightLinks"))
        preferencePicker("Link Style", path: \.linkStyle, choices: [("color", "Color Only"), ("underline", "Underline Only"), ("both", "Color & Underline")], id: "text.linkStyle")
          .disabled(!appState.appSettings.highlightLinks)
        linkPreview
      } header: {
        Text("Reading Aids")
      } footer: {
        Text("Reading time estimates appear on posts with at least 100 words. Link appearance follows this account's accent color.")
      }
      .disabled(!canEdit)
    }
    .navigationTitle("Text & Readability")
    .tint(accent)
    .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }

  private func preferencePicker(_ title: String, path: ReferenceWritableKeyPath<AppSettings, String>, choices: [(String, String)], id: String) -> some View {
    Picker(title, selection: string(path)) {
      ForEach(choices, id: \.0) { choice in Text(LocalizedStringKey(choice.1)).tag(choice.0) }
      if !choices.contains(where: { $0.0 == appState.appSettings[keyPath: path] }) {
        Text("Custom").tag(appState.appSettings[keyPath: path])
      }
    }
    .pickerStyle(.menu)
    .settingsControl(.init(rawValue: id))
  }

  private var maximumTextSizePicker: some View {
    Menu {
      Picker("Maximum Text Size", selection: string(\.maxDynamicTypeSize)) {
        ForEach(AppTextSizeLimit.options, id: \.value) { option in
          Text(LocalizedStringKey(option.title)).tag(option.value)
        }
        if !AppTextSizeLimit.options.contains(where: { $0.value == appState.appSettings.maxDynamicTypeSize }) {
          Text("Saved value: \(appState.appSettings.maxDynamicTypeSize)").tag(appState.appSettings.maxDynamicTypeSize)
        }
      }
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Maximum Text Size").foregroundStyle(.primary)
          Text(LocalizedStringKey(AppTextSizeLimit.title(for: appState.appSettings.maxDynamicTypeSize)))
            .foregroundStyle(.secondary)
        }
        .appFont(AppTextRole.body)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.up.chevron.down").accessibilityHidden(true)
      }
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("Maximum Text Size")
    .accessibilityValue(Text(LocalizedStringKey(AppTextSizeLimit.title(for: appState.appSettings.maxDynamicTypeSize))))
    .settingsControl(.init(rawValue: "text.maxSize"))
  }

  private var linkPreview: some View {
    let highlights = appState.appSettings.highlightLinks
    let style = appState.appSettings.linkStyle
    let usesColor = highlights && (style == "color" || style == "both")
    let usesUnderline = highlights && (style == "underline" || style == "both")
    return VStack(alignment: .leading, spacing: 8) {
      Text("Link Preview").appFont(AppTextRole.caption).foregroundStyle(.secondary)
      Text("Check out this \(Text("example link").foregroundColor(usesColor ? linkAccent : .primary).underline(usesUnderline)) in a post.")
        .appFont(AppTextRole.body)
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .combine)
  }
}
