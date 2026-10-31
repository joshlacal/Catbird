import SwiftUI

#if DEBUG
/// Used only by the Settings layout fixtures; the shipping app reaches these pages from Settings directly.
struct ContentMediaSettingsView: View {
  var body: some View {
    SettingsFocusedForm(initialFocus: nil) {
      Section {
        NavigationLink { FeedsDiscoverySettingsView() } label: {
          SettingsNavigationRow(title: "Feeds & Discovery", summary: "Filtering, threads, trending content and feed library", systemImage: "rectangle.stack", family: .feeds)
        }
        NavigationLink { MediaLinksSettingsView() } label: {
          SettingsNavigationRow(title: "Media & Links", summary: "Playback, browser and external media permissions", systemImage: "play.rectangle", family: .media)
        }
        NavigationLink { LanguageSettingsView() } label: {
          SettingsNavigationRow(title: "Languages", summary: "App, reading and posting languages", systemImage: "globe", family: .language)
        }
      }
    }.navigationTitle("Content & Media")
  }
}
#endif
