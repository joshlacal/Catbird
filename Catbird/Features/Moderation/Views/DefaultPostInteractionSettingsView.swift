import SwiftUI
import Petrel

/// Confirmed account defaults for new posts; per-post overrides remain in the composer.
struct DefaultPostInteractionSettingsView: View {
  @Environment(AppState.self) private var appState
  let initialFocus: SettingsControlID?
  @State private var editor: AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>?
  @State private var userLists: [AppBskyGraphDefs.ListView] = []
  @State private var isLoadingLists = false
  @State private var listError: String?
  @State private var listLoadRevision: UInt64 = 0

  enum ReplyMode: String, CaseIterable, Identifiable {
    case everybody, nobody, custom
    var id: String { rawValue }
    var title: String {
      switch self {
      case .everybody: "Everyone"
      case .nobody: "No One"
      case .custom: "Selected Groups and Lists"
      }
    }
    var explanation: String {
      switch self {
      case .everybody: "Anyone can reply to new posts."
      case .nobody: "New posts don’t allow replies."
      case .custom: "People in any selected group or list can reply."
      }
    }
  }

  init(initialFocus: SettingsControlID? = nil) {
    self.initialFocus = initialFocus
  }

  private var replyMode: ReplyMode {
    guard let rules = editor?.displayedValue?.threadgateAllowRules else { return .everybody }
    return rules.isEmpty ? .nobody : .custom
  }

  private var requestedFocus: SettingsControlID? {
    guard let initialFocus else { return nil }
    switch editor?.state {
    case .loadFailed: return .init(rawValue: "privacy.defaultRulesRetryLoad")
    case .saveFailed: return .init(rawValue: "privacy.defaultRulesRetrySave")
    default: return initialFocus
    }
  }

  private var isFocusReady: Bool {
    switch editor?.state {
    case .ready, .loadFailed, .saveFailed: true
    default: false
    }
  }

  var body: some View {
    SettingsFocusedForm(initialFocus: requestedFocus, isReady: isFocusReady) {
      SettingsScopeSection(scope: "New posts for this account")
      Section {
        Text("These defaults apply when you create a post. You can still choose different replies and quotes for an individual post.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let editor {
        if editor.state == .unavailable {
          Section { Text("This account is no longer active. Open Settings for the current account.") }
        } else if editor.state == .loading {
          Section { ProgressView("Loading default replies and quotes…") }
        } else if editor.state == .loadFailed {
          Section {
            Text("Default replies and quotes couldn’t be loaded.")
            Text(editor.errorMessage ?? "Try again.").font(.footnote).foregroundStyle(.secondary)
            Button("Try Again") { Task { await editor.load() } }
              .settingsControl(.init(rawValue: "privacy.defaultRulesRetryLoad"))
          }
          .settingsControl(.init(rawValue: "privacy.defaultPostInteractions"))
        } else {
          Section("Who Can Reply") {
            ForEach(ReplyMode.allCases) { mode in
              Button { select(mode, in: editor) } label: {
                HStack(alignment: .top) {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).foregroundStyle(.primary)
                    Text(mode.explanation).font(.footnote).foregroundStyle(.secondary)
                  }
                  Spacer()
                  if replyMode == mode {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                  }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .disabled(!editor.canEdit)
              .accessibilityAddTraits(replyMode == mode ? .isSelected : [])
            }
          }
          .settingsControl(.init(rawValue: "privacy.defaultPostInteractions"))

          if replyMode == .custom {
            Section("Allow Replies From") {
              replyToggle("People I Follow", kind: .following, editor: editor)
              replyToggle("My Followers", kind: .followers, editor: editor)
              replyToggle("People Mentioned in the Post", kind: .mentioned, editor: editor)
              if editor.displayedValue?.threadgateAllowRules?.contains(where: {
                if case .unexpected = $0 { return true }; return false
              }) == true {
                Text("Other saved reply rules are kept when you change a group or list. Choosing Everyone or No One replaces all reply rules.")
                  .font(.footnote).foregroundStyle(.secondary)
              }
              Text("The selected groups, lists and any other saved rules are combined.")
                .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Lists") {
              if isLoadingLists {
                ProgressView("Loading my lists…")
              } else if let listError {
                Text(listError).font(.footnote).foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadUserLists() } }
              } else if userLists.isEmpty {
                Text("You have no lists.").foregroundStyle(.secondary)
              } else {
                ForEach(userLists, id: \.uri) { list in
                  let selected = hasList(list.uri.uriString(), in: editor.displayedValue)
                  Button { toggleList(list.uri, in: editor) } label: {
                    HStack {
                      Text(list.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                      Spacer()
                      if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true) }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .disabled(!editor.canEdit)
                  .accessibilityAddTraits(selected ? .isSelected : [])
                }
              }
            }
          }
          Section {
            Toggle("Allow Quote Posts", isOn: Binding(
              get: { editor.displayedValue?.postgateEmbeddingRules?.contains(where: {
                if case .appBskyFeedPostgateDisableRule = $0 { return true }
                return false
              }) != true },
              set: { allowed in setQuotes(allowed, in: editor) }
            ))
            .disabled(!editor.canEdit)
            .settingsControl(.init(rawValue: "privacy.defaultQuotes"))
            if editor.displayedValue?.postgateEmbeddingRules?.contains(where: {
              if case .unexpected = $0 { return true }; return false
            }) == true {
              Text("Other saved quote rules are kept.").font(.footnote).foregroundStyle(.secondary)
            }
          } header: {
            Text("Quote Posts")
          } footer: {
            Text("Turning this off prevents other people from quoting new posts by default.")
          }
          if editor.state == .saving {
            Section { ProgressView("Saving defaults…") }
          } else if editor.state == .saveFailed {
            Section {
              Text("This change couldn’t be confirmed.")
              Text(editor.errorMessage ?? "Try again.").font(.footnote).foregroundStyle(.secondary)
              Button("Try This Change Again") { editor.retrySave() }
                .settingsControl(.init(rawValue: "privacy.defaultRulesRetrySave"))
              Button("Reload Saved Defaults") { Task { await editor.load() } }
            }
          }
        }
      } else {
        Section { ProgressView("Loading default replies and quotes…") }
      }
    }
    .navigationTitle("Default Replies & Quotes")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) { await loadEditor() }
    .onDisappear { editor?.invalidate(); listLoadRevision &+= 1; isLoadingLists = false }
  }

  private enum GroupKind { case following, followers, mentioned }

  private func replyToggle(
    _ title: String, kind: GroupKind,
    editor: AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>
  ) -> some View {
    Toggle(title, isOn: Binding(
      get: { editor.displayedValue?.threadgateAllowRules?.contains(where: { matches($0, kind: kind) }) == true },
      set: { selected in
        guard editor.canEdit, let value = editor.confirmedValue else { return }
        var rules = value.threadgateAllowRules ?? []
        rules.removeAll { matches($0, kind: kind) }
        if selected {
          switch kind {
          case .following: rules.append(.appBskyFeedThreadgateFollowingRule(.init()))
          case .followers: rules.append(.appBskyFeedThreadgateFollowerRule(.init()))
          case .mentioned: rules.append(.appBskyFeedThreadgateMentionRule(.init()))
          }
        }
        editor.submit(.init(threadgateAllowRules: rules, postgateEmbeddingRules: value.postgateEmbeddingRules))
      }
    ))
    .disabled(!editor.canEdit)
  }

  private func matches(_ rule: AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion, kind: GroupKind) -> Bool {
    switch (rule, kind) {
    case (.appBskyFeedThreadgateFollowingRule, .following),
         (.appBskyFeedThreadgateFollowerRule, .followers),
         (.appBskyFeedThreadgateMentionRule, .mentioned): true
    default: false
    }
  }

  private func hasList(_ uri: String, in value: AppBskyActorDefs.PostInteractionSettingsPref?) -> Bool {
    value?.threadgateAllowRules?.contains(where: {
      if case .appBskyFeedThreadgateListRule(let rule) = $0 { return rule.list.uriString() == uri }
      return false
    }) == true
  }

  @MainActor
  private func select(_ mode: ReplyMode, in session: AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>) {
    guard session.canEdit, let value = session.confirmedValue, mode != replyMode else { return }
    let rules: [AppBskyActorDefs.PostInteractionSettingsPrefThreadgateAllowRulesUnion]?
    switch mode {
    case .everybody: rules = nil
    case .nobody: rules = []
    case .custom:
      rules = [.appBskyFeedThreadgateFollowingRule(.init()), .appBskyFeedThreadgateMentionRule(.init())]
    }
    session.submit(.init(threadgateAllowRules: rules, postgateEmbeddingRules: value.postgateEmbeddingRules))
  }

  @MainActor
  private func setQuotes(_ allowed: Bool, in session: AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>) {
    guard session.canEdit, let value = session.confirmedValue else { return }
    var rules = value.postgateEmbeddingRules ?? []
    rules.removeAll { if case .appBskyFeedPostgateDisableRule = $0 { return true }; return false }
    if !allowed { rules.append(.appBskyFeedPostgateDisableRule(.init())) }
    session.submit(.init(threadgateAllowRules: value.threadgateAllowRules, postgateEmbeddingRules: rules.isEmpty ? nil : rules))
  }

  @MainActor
  private func toggleList(_ uri: ATProtocolURI, in session: AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>) {
    guard session.canEdit, let value = session.confirmedValue else { return }
    var rules = value.threadgateAllowRules ?? []
    if hasList(uri.uriString(), in: value) {
      rules.removeAll {
        if case .appBskyFeedThreadgateListRule(let rule) = $0 { return rule.list == uri }
        return false
      }
    } else {
      rules.append(.appBskyFeedThreadgateListRule(.init(list: uri)))
    }
    session.submit(.init(threadgateAllowRules: rules, postgateEmbeddingRules: value.postgateEmbeddingRules))
  }

  @MainActor
  private func loadEditor() async {
    editor?.invalidate()
    let state = appState
    let account = state.userDID
    let contextRevision = AppStateManager.shared.settingsAccountContextRevision
    let manager = state.preferencesManager
    let session = AccountSettingsEditSession<AppBskyActorDefs.PostInteractionSettingsPref>(
      accountDID: account,
      allowEditingAfterSaveFailure: false,
      isCurrentAccount: {
        manager.accountDID == account && AppStateManager.shared.lifecycle.userDID == account
          && AppStateManager.shared.settingsAccountContextRevision == contextRevision
          && !state.isTransitioningAccounts
      },
      load: {
        try await manager.getConfirmedPostInteractionSettingsPref(expectedAccountDID: account)
          ?? .init(threadgateAllowRules: nil, postgateEmbeddingRules: nil)
      },
      save: { value in
        try await manager.setPostInteractionSettingsPref(value, expectedAccountDID: account)
        return value
      }
    )
    editor = session
    await session.load()
    guard session.canEdit else { return }
    await loadUserLists()
  }

  @MainActor
  private func loadUserLists() async {
    guard AppStateManager.shared.lifecycle.userDID == appState.userDID, let client = appState.atProtoClient else {
      listError = "Sign in to load your lists."
      return
    }
    let state = appState
    let account = state.userDID
    let contextRevision = AppStateManager.shared.settingsAccountContextRevision
    listLoadRevision &+= 1
    let loadRevision = listLoadRevision
    isLoadingLists = true
    listError = nil
    defer { if listLoadRevision == loadRevision { isLoadingLists = false } }
    do {
      var loaded: [AppBskyGraphDefs.ListView] = []
      var seen: Set<String> = []
      var cursor: String?
      repeat {
        let (code, output) = try await state.performSettingsAccountOperation {
          try await client.app.bsky.graph.getLists(input: .init(
            actor: try ATIdentifier(string: account), limit: 50, cursor: cursor
          ))
        }
        guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == account,
              AppStateManager.shared.settingsAccountContextRevision == contextRevision,
              listLoadRevision == loadRevision, !state.isTransitioningAccounts,
              state.atProtoClient === client else { return }
        guard code == 200, let output else {
          throw NSError(domain: "DefaultRepliesLists", code: code,
            userInfo: [NSLocalizedDescriptionKey: "Your lists couldn’t be loaded. Try again."])
        }
        loaded.append(contentsOf: output.lists)
        cursor = output.cursor
        if let cursor, !seen.insert(cursor).inserted {
          throw NSError(domain: "DefaultRepliesLists", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Your lists couldn’t be loaded completely. Try again."])
        }
      } while cursor != nil
      var unique: Set<String> = []
      userLists = loaded.filter { unique.insert($0.uri.uriString()).inserted }
    } catch {
      guard !Task.isCancelled, AppStateManager.shared.lifecycle.userDID == account,
            AppStateManager.shared.settingsAccountContextRevision == contextRevision,
            listLoadRevision == loadRevision, !state.isTransitioningAccounts else { return }
      listError = (error as NSError).domain == "DefaultRepliesLists"
        ? error.localizedDescription
        : (UserFacingError.message(for: error, action: "load your lists") ?? "Your lists couldn’t be loaded. Try again.")
    }
  }
}
