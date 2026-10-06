import SwiftUI

struct AccessibilitySettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.legibilityWeight) private var legibilityWeight
  @Environment(\.colorSchemeContrast) private var accessibilityContrast
  var initialFocus: SettingsControlID? = nil
  private var canEdit: Bool { appState.appSettings.canEditPersistedSettings }
  private var accent: Color {
    let palette = AccentColorOption(rawValue: appState.appSettings.accentColor) ?? .catbird
    return colorScheme == .dark ? palette.darkColor : palette.color
  }

  private func bool(_ path: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
    Binding(get: { appState.appSettings[keyPath: path] }, set: { appState.appSettings[keyPath: path] = $0 })
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: appState.appSettings.persistenceState != .unavailable) {
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        NavigationLink {
          TextReadabilitySettingsView()
        } label: {
          SettingsNavigationRow(title: "Text & Readability", summary: "Font, spacing, system text size and reading aids", systemImage: "textformat.size", family: .accessibility)
        }
      } footer: {
        Text("Catbird follows system accessibility accommodations. These account choices add accommodations in Catbird on this device.")
      }

      Section {
        Toggle("Require Alt Text Before Posting", isOn: bool(\.requireAltText))
          .settingsControl(.init(rawValue: "accessibility.altText"))
        Toggle("Display Larger Alt Text Badges", isOn: bool(\.largerAltTextBadges))
          .settingsControl(.init(rawValue: "accessibility.altBadges"))
      } header: { Text("Alt Text") } footer: {
        Text("Alt text describes an image for people who cannot see it. Requiring it applies to image posts you create in Catbird.")
      }
      .disabled(!canEdit)

      Section {
        Toggle("Reduce Motion in Catbird", isOn: bool(\.reduceMotion))
          .settingsControl(.init(rawValue: "accessibility.reduceMotion"))
        if appState.appSettings.systemAccessibility.reduceMotion {
          Label("Reduce Motion is on in system settings.", systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
        }
        Toggle("Prefer Crossfade Transitions", isOn: bool(\.prefersCrossfade))
          .disabled(!appState.appSettings.effectiveReduceMotion)
          .settingsControl(.init(rawValue: "accessibility.crossfade"))
        if appState.appSettings.systemAccessibility.prefersCrossfade {
          Text("The system also prefers crossfade transitions.").foregroundStyle(.secondary)
        }
      } header: { Text("Motion") } footer: {
        Text("Reduce Motion limits supported interface animations. Turning this app choice off keeps the system accommodation. Crossfade replaces supported sliding transitions; video autoplay is managed in Media & Links.")
      }
      .disabled(!canEdit)

      Section {
        Toggle("Increase Contrast in Catbird", isOn: bool(\.increaseContrast))
          .settingsControl(.init(rawValue: "accessibility.increaseContrast"))
        if accessibilityContrast == .increased || appState.appSettings.systemAccessibility.increaseContrast {
          Label("Increase Contrast is on in system settings.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        Toggle("Bold Text in Catbird", isOn: bool(\.boldText))
          .settingsControl(.init(rawValue: "accessibility.boldText"))
        if legibilityWeight == .bold || appState.appSettings.systemAccessibility.boldText {
          Label("Bold Text is on in system settings.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        }
        FontPreviewRow()
      } header: { Text("Contrast & Text Weight") } footer: {
        Text("These choices add contrast and text weight. System contrast and Bold Text remain active when the app choices are off.")
      }
      .disabled(!canEdit)

      Section {
        Toggle("Confirm Social Actions", isOn: bool(\.confirmBeforeActions))
          .settingsControl(.init(rawValue: "accessibility.confirmActions"))
      } header: { Text("Interactions") } footer: {
        Text("Ask before muting an account or thread, or unfollowing someone. Deleting posts and blocking accounts always require confirmation.")
      }
      .disabled(!canEdit)

      Section("Haptics") {
        Toggle("Disable Haptic Feedback", isOn: bool(\.disableHaptics))
          .settingsControl(.init(rawValue: "accessibility.haptics"))
      }
      .disabled(!canEdit)
    }
    .navigationTitle("Accessibility")
    .tint(accent)
    .contrastAwareBackground(appState: appState, defaultColor: Color.systemBackground)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
  }
}
