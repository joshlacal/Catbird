import SwiftUI
import Petrel

/// The canonical list of subscribed moderation services. Loading never changes subscriptions.
struct LabelerSettingsView: View {
  @Environment(AppState.self) private var appState
  let initialFocus: SettingsControlID?
  @State private var labelers: [AppBskyLabelerDefs.LabelerViewDetailed] = []
  @State private var unavailable: [DID] = []
  @State private var request = UUID()
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var hasConfirmedPreferences = false
  @State private var errorMessage: String?
  init(initialFocus: SettingsControlID? = nil) { self.initialFocus = initialFocus }

  var body: some View {
    SettingsFocusedForm(initialFocus: initialFocus, isReady: hasConfirmedPreferences) {
      Section {
        if isLoading { ProgressView("Loading moderation services…") }
        ForEach(labelers, id: \.uri) { labeler in
          NavigationLink {
            ModerationServiceSettingsView(labeler: labeler)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(labeler.creator.displayName ?? labeler.creator.handle.description)
              Text("@\(labeler.creator.handle)").font(.caption).foregroundStyle(.secondary)
              if labeler.creator.did.didString() == Self.defaultDID {
                Text("Always active").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        NavigationLink("Add Moderation Service", destination: AddLabelerView())
          .disabled(!hasConfirmedPreferences || isSaving)
      } footer: {
        Text("Service settings override global content settings. Bluesky moderation is always active; up to 19 additional services can be subscribed.")
      }
      .settingsControl(.init(rawValue: "moderation.labelers"))
      if !unavailable.isEmpty {
        Section("Unavailable Services") {
          Text("Details could not be returned for these subscriptions. They remain subscribed until you remove them.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(unavailable, id: \.self) { did in
            HStack {
              Text(did.didString()).font(.caption)
              Spacer()
              Button("Remove", role: .destructive) { removeUnavailable(did) }.disabled(isSaving)
            }
          }
        }
      }
      if let errorMessage {
        Section {
          Text(errorMessage).foregroundStyle(.secondary)
          Button("Retry") { Task { await load() } }.disabled(isLoading || isSaving)
            .accessibilityIdentifier("moderation.labelers.retry")
        }
      }
    }
    .navigationTitle("Moderation Services")
    .task(id: appState.userDID) { await load() }
    .refreshable { await load() }
  }

  static let defaultDID = "did:plc:ar7c4by46qjdydhdevvrndac"
  private func load() async {
    let token = UUID(); request = token
    let account = appState.userDID
    let manager = appState.preferencesManager
    let client = appState.atProtoClient
    isLoading = true; errorMessage = nil; hasConfirmedPreferences = false
    defer { if request == token { isLoading = false } }
    do {
      guard let client else { throw PreferencesManagerError.clientNotInitialized }
      let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
      var dids = [try DID(didString: Self.defaultDID)]
      for item in preferences.labelers where !dids.contains(item.did) { dids.append(item.did) }
      let bounded = Array(dids.prefix(20))
      let (code, data) = try await client.app.bsky.labeler.getServices(input: .init(dids: bounded, detailed: true))
      guard request == token, manager.accountDID == account, appState.userDID == account,
            appState.atProtoClient === client else { return }
      guard (200..<300).contains(code), let data else { throw PreferencesManagerError.invalidData }
      let detailed = data.views.compactMap { value -> AppBskyLabelerDefs.LabelerViewDetailed? in
        if case .appBskyLabelerDefsLabelerViewDetailed(let view) = value { return view }
        return nil
      }
      labelers = bounded.compactMap { did in detailed.first { $0.creator.did == did } }
      let returned = Set(labelers.map { $0.creator.did })
      unavailable = preferences.labelers.map(\.did).filter { !returned.contains($0) && $0.didString() != Self.defaultDID }
      hasConfirmedPreferences = true
    } catch {
      guard request == token, manager.accountDID == account else { return }
      errorMessage = "Could not load moderation services: \(error.localizedDescription)"
    }
  }

  private func removeUnavailable(_ did: DID) {
    guard hasConfirmedPreferences, !isSaving else { return }
    let account = appState.userDID; let manager = appState.preferencesManager
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await manager.removeLabelers([did.didString()], expectedAccountDID: account)
        guard appState.userDID == account, manager.accountDID == account else { return }
        unavailable.removeAll { $0 == did }
      } catch {
        guard manager.accountDID == account else { return }
        errorMessage = "Could not remove service: \(error.localizedDescription)"
      }
    }
  }
}

/// All supported service categories, with explicit inheritance and one-key saves.
struct ModerationServiceSettingsView: View {
  let labeler: AppBskyLabelerDefs.LabelerViewDetailed
  @Environment(AppState.self) private var appState
  @State private var preferences: [ContentLabelPreference] = []
  @State private var adultContentEnabled = false
  @State private var hasConfirmedPreferences = false
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var isSubscribed = false
  @State private var errorMessage: String?
  @State private var request = UUID()

  private var serviceDID: DID { labeler.creator.did }
  private var isDefaultService: Bool { serviceDID.didString() == LabelerSettingsView.defaultDID }
  private var categories: [String] {
    let builtins = ["nsfw", "suggestive", "graphic", "nudity"]
    let aliases = Set(builtins + ["porn", "sexual", "gore", "violence", "graphic-media"])
    return builtins + labeler.policies.labelValues.map(\.rawValue).filter { !aliases.contains($0) && !$0.hasPrefix("!") }
  }

  var body: some View {
    Form {
      Section {
        if let description = labeler.creator.description { Text(description).foregroundStyle(.secondary) }
        if isDefaultService { Text("Always active").foregroundStyle(.secondary) }
        else {
          Toggle("Subscribed", isOn: Binding(get: { isSubscribed }, set: { setSubscribed($0) }))
            .disabled(!hasConfirmedPreferences || isSaving)
        }
      }
      if isLoading { Section { ProgressView("Loading content settings…") } }
      if hasConfirmedPreferences {
        ForEach(categories, id: \.self) { label in
          Section {
            ContentVisibilitySelector(title: title(for: label), description: description(for: label),
              selection: Binding(get: { visibility(for: label) }, set: { save(label: label, visibility: $0) }))
              .disabled(isSaving || (!adultContentEnabled && ["nsfw", "suggestive", "nudity"].contains(label)))
              .accessibilityIdentifier("moderation.service.\(label)")
            if hasOverride(for: label) {
              Button("Use Inherited Setting") { inherit(label: label) }.disabled(isSaving)
                .accessibilityIdentifier("moderation.service.\(label).inherit")
            }
            Text(inheritanceDescription(for: label)).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      if isSaving { Section { ProgressView("Saving…") } }
      if let errorMessage {
        Section {
          Text(errorMessage).foregroundStyle(.secondary)
          Button("Reload Settings") { Task { await load() } }.disabled(isLoading || isSaving)
        }
      }
    }
    .navigationTitle(labeler.creator.displayName ?? labeler.creator.handle.description)
    .task(id: appState.userDID) { await load() }
  }

  private func definition(for label: String) -> ComAtprotoLabelDefs.LabelValueDefinition? {
    labeler.policies.labelValueDefinitions?.first { $0.identifier == label }
  }
  private func title(for label: String) -> String {
    switch label {
    case "nsfw": "Adult Content"
    case "suggestive": "Sexually Suggestive"
    case "graphic": "Graphic Content"
    case "nudity": "Non-Sexual Nudity"
    default: definition(for: label).flatMap { AccountLabelPresentation.localizedStrings($0.locales, preferredLanguages: Locale.preferredLanguages)?.name } ?? label
    }
  }
  private func description(for label: String) -> String {
    definition(for: label).flatMap { AccountLabelPresentation.localizedStrings($0.locales, preferredLanguages: Locale.preferredLanguages)?.description }
      ?? "Choose whether this service’s labeled content is shown, warned, or hidden."
  }
  private func hasOverride(for label: String) -> Bool {
    preferences.contains { $0.label == label && $0.labelerDid == serviceDID }
  }
  private func inheritedVisibility(for label: String) -> ContentVisibility {
    if let global = preferences.last(where: { $0.label == label && $0.labelerDid == nil }) {
      return ContentVisibility(fromPreference: global.visibility)
    }
    if let setting = definition(for: label)?.defaultSetting { return ContentVisibility(fromPreference: setting) }
    return .warn
  }
  private func visibility(for label: String) -> ContentVisibility {
    if let scoped = preferences.last(where: { $0.label == label && $0.labelerDid == serviceDID }) {
      return ContentVisibility(fromPreference: scoped.visibility)
    }
    return inheritedVisibility(for: label)
  }
  private func inheritanceDescription(for label: String) -> String {
    let origin = preferences.contains { $0.label == label && $0.labelerDid == nil } ? "Global setting" : "Service default"
    return "\(hasOverride(for: label) ? "Override active. " : "Inherited. ")\(origin): \(inheritedVisibility(for: label).displayName)."
  }
  private func load() async {
    let token = UUID(); request = token
    let account = appState.userDID; let manager = appState.preferencesManager
    isLoading = true; hasConfirmedPreferences = false; errorMessage = nil
    defer { if request == token { isLoading = false } }
    do {
      let loaded = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
      guard request == token, manager.accountDID == account, appState.userDID == account else { return }
      preferences = loaded.contentLabelPrefs; adultContentEnabled = loaded.adultContentEnabled
      isSubscribed = isDefaultService || loaded.labelers.contains { $0.did == serviceDID }
      hasConfirmedPreferences = true
    } catch {
      guard request == token, manager.accountDID == account else { return }
      errorMessage = "Could not load settings: \(error.localizedDescription)"
    }
  }
  private func save(label: String, visibility: ContentVisibility) {
    guard hasConfirmedPreferences, !isSaving else { return }
    edit { manager, account in
      try await manager.setContentLabelVisibility(label: label, visibility: visibility.preferenceValue,
        labelerDid: serviceDID, expectedAccountDID: account)
    }
  }
  private func inherit(label: String) {
    guard hasConfirmedPreferences, !isSaving else { return }
    edit { manager, account in
      try await manager.removeContentLabelOverride(label: label, labelerDid: serviceDID, expectedAccountDID: account)
    }
  }
  private func setSubscribed(_ enabled: Bool) {
    guard hasConfirmedPreferences, !isSaving, !isDefaultService, enabled != isSubscribed else { return }
    edit { manager, account in
      if enabled { try await manager.addLabeler(serviceDID, expectedAccountDID: account) }
      else { try await manager.removeLabeler(serviceDID, expectedAccountDID: account) }
    }
  }
  private func edit(_ operation: @escaping @MainActor (PreferencesManager, String) async throws -> Void) {
    let account = appState.userDID; let manager = appState.preferencesManager
    isSaving = true; errorMessage = nil
    Task { @MainActor in
      defer { isSaving = false }
      do {
        try await operation(manager, account)
        let loaded = try await manager.getPreferences()
        guard manager.accountDID == account, appState.userDID == account else { return }
        preferences = loaded.contentLabelPrefs
        isSubscribed = isDefaultService || loaded.labelers.contains { $0.did == serviceDID }
      } catch {
        guard manager.accountDID == account else { return }
        errorMessage = "Could not save settings: \(error.localizedDescription)"
      }
    }
  }
}
