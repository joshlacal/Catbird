import SwiftUI

struct FeedFilterSettingsView: View {
  @Environment(AppState.self) private var appState
  var initialFocus: SettingsControlID? = nil
  @State private var editor: FeedPreferenceEditor?
  @State private var reconciledFilter: String?

  private var isEditable: Bool {
    editor?.hasLoaded == true && editor?.isSaving == false && editor?.pending == nil
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: editor?.isLoading == false) {
      SettingsScopeSection()
      SettingsPersistenceStatusSection(settings: appState.appSettings)
      Section {
        if let editor, editor.hasLoaded {
          visibilityRow("Replies", localID: "Hide Replies", synced: editor.confirmed?.hideReplies ?? false, control: "feed.replies")
          visibilityRow("Reposts", localID: "Hide Reposts", synced: editor.confirmed?.hideReposts ?? false, control: "feed.reposts")
          visibilityRow("Quote Posts", localID: "Hide Quote Posts", synced: editor.confirmed?.hideQuotePosts ?? false, control: "feed.quotes")
        } else if editor?.isLoading != false {
          ProgressView("Loading Bluesky preferences…")
        } else {
          Text("Load Bluesky preferences to see every active source before changing visibility.").foregroundStyle(.secondary)
          Button("Retry Loading") { Task { await editor?.load() } }
        }
      } header: { Text("Post Visibility") } footer: {
        Text("These rows combine Bluesky preferences and existing filters on this device. Choosing Show clears each source that hides that post type. Your own replies remain visible.")
      }
      .disabled(!isEditable && editor?.hasLoaded == true)

      if let editor, editor.hasLoaded {
        Section {
          Toggle("Hide Replies to People You Don’t Follow", isOn: Binding(
            get: { editor.confirmed?.hideRepliesByUnfollowed ?? false },
            set: { value in Task { await editor.submit(.unfollowedReplies(value)) } }
          )).settingsControl(.init(rawValue: "feed.unfollowedReplies"))
          Toggle("Minimum Likes for Replies", isOn: Binding(
            get: { editor.confirmed?.hideRepliesByLikeCount != nil },
            set: { value in Task { await editor.submit(.minimumLikes(value ? 2 : nil)) } }
          )).settingsControl(.init(rawValue: "feed.replyLikeThreshold"))
          if let minimum = editor.confirmed?.hideRepliesByLikeCount {
            if !(0...100).contains(minimum) {
              Text("Saved minimum: \(minimum). Choose a value from 0 to 100 below to replace it.").font(.caption).foregroundStyle(.secondary)
            }
            Stepper(value: Binding(
              get: { min(100, max(0, minimum)) },
              set: { value in Task { await editor.submit(.minimumLikes(value)) } }
            ), in: 0...100) { Text("Minimum Likes: \(minimum)") }
          }
        } header: { Text("Reply Details · Syncs with Bluesky") } footer: {
          Text("Reply details are retained while replies are hidden. They take effect again when replies are shown.")
        }
        .disabled(!isEditable || repliesAreHidden)
      }

      Section {
        Picker("Post Types", selection: Binding(
          get: { appState.feedFilterSettings.contentType },
          set: { appState.feedFilterSettings.setContentType($0) }
        )) {
          ForEach(FeedContentType.allCases.filter { $0 != .conflicting || appState.feedFilterSettings.contentType == .conflicting }) { type in
            Text(type.title).tag(type)
          }
        }.settingsControl(.init(rawValue: "feed.contentType"))
        if appState.feedFilterSettings.contentType == .conflicting {
          Text("Text Only and Images and Videos Only are both stored as enabled. Together they hide every post. Choose a post type to replace those two choices explicitly.")
            .font(.footnote).foregroundStyle(.secondary)
        }
        localToggle("Hide Link Posts", id: "Hide Link Posts", control: "feed.hideLinkPosts")
        localToggle("Hide Repeated Parent Posts", id: "Hide Duplicate Posts", control: "feed.duplicates")
      } header: { Text("On This Device · Current Account") } footer: {
        Text("Post types and link filters apply to Catbird feeds on this device. Repeated parent filtering hides a standalone post when it already appears in a reply thread. Changes refresh loaded feeds.")
      }
      Section {
        NavigationLink {
          LanguageSettingsView(initialFocus: .init(rawValue: "languages.hideOtherLanguages"))
        } label: {
          SettingsNavigationRow(title: "Reading Languages", summary: languageSummary, systemImage: "globe", family: .language)
        }.settingsControl(.init(rawValue: "feed.languageFilter"))
      } footer: {
        Text("Reading-language preferences and an existing Filter by Language choice combine. Manage both sources in Languages.")
      }
      if let editor {
        if editor.isSaving { Section { ProgressView("Saving Bluesky preference…") } }
        if let error = editor.error {
          Section {
            Text(error).foregroundStyle(.red)
            if editor.pending != nil {
              Button("Retry Saving") { Task { await editor.retry() } }.disabled(editor.isSaving)
              Button("Discard Attempt", role: .cancel) { editor.discardAttempt() }.disabled(editor.isSaving)
            }
          }
        }
      }
    }
    .navigationTitle("Feed Filtering")
    .task(id: appState.userDID) {
      let editor = FeedPreferenceEditor(appState: appState)
      self.editor = editor
      await editor.load()
    }
    .confirmationDialog("Show \(reconciledTitle)?", isPresented: Binding(
      get: { reconciledFilter != nil }, set: { if !$0 { reconciledFilter = nil } }
    ), titleVisibility: .visible) {
      Button("Show \(reconciledTitle)") {
        guard let id = reconciledFilter else { return }
        reconciledFilter = nil
        changeVisibility(id, hidden: false)
      }
      Button("Cancel", role: .cancel) { reconciledFilter = nil }
    } message: {
      Text("This clears the filter on this device and turns off the Bluesky hide preference when enabled. Other filters still apply.")
    }
  }

  private var repliesAreHidden: Bool { appState.feedFilterSettings.hideReplies || (editor?.confirmed?.hideReplies ?? false) }
  private var reconciledTitle: String { reconciledFilter?.replacingOccurrences(of: "Hide ", with: "") ?? "Posts" }
  private var languageSummary: String {
    appState.appSettings.hideNonPreferredLanguages || appState.feedFilterSettings.isFilterEnabled(name: "Filter by Language")
      ? "Filtering to preferred reading languages" : "Showing every language"
  }
  private func visibilityRow(_ title: String, localID: String, synced: Bool, control: String) -> some View {
    let sources = FeedFilterSources(local: appState.feedFilterSettings.isFilterEnabled(name: localID), synced: synced)
    return Toggle(isOn: Binding(get: { sources.isHidden }, set: { hidden in
      if !hidden && sources.local { reconciledFilter = localID }
      else { changeVisibility(localID, hidden: hidden) }
    })) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Hide \(title)")
        Text(sources.description).font(.caption).foregroundStyle(.secondary)
      }
    }.settingsControl(.init(rawValue: control))
  }
  private func localToggle(_ title: String, id: String, control: String) -> some View {
    Toggle(title, isOn: Binding(
      get: { appState.feedFilterSettings.isFilterEnabled(name: id) },
      set: { appState.feedFilterSettings.setFilter(id: id, enabled: $0) }
    )).settingsControl(.init(rawValue: control))
  }
  private func changeVisibility(_ id: String, hidden: Bool) {
    guard let editor, isEditable else { return }
    let synced: Bool
    let edit: FeedPreferenceEdit
    switch id {
    case "Hide Replies": synced = editor.confirmed?.hideReplies ?? false; edit = .replies(hidden)
    case "Hide Reposts": synced = editor.confirmed?.hideReposts ?? false; edit = .reposts(hidden)
    case "Hide Quote Posts": synced = editor.confirmed?.hideQuotePosts ?? false; edit = .quotes(hidden)
    default: return
    }
    if !hidden && !synced { appState.feedFilterSettings.setFilter(id: id, enabled: false); return }
    Task {
      await editor.submit(edit) {
        if !hidden { appState.feedFilterSettings.setFilter(id: id, enabled: false) }
      }
    }
  }
}
