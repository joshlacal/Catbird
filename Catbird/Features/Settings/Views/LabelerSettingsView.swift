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
              Text("@\(labeler.creator.handle.description)").appFont(AppTextRole.caption).foregroundStyle(.secondary)
              if labeler.creator.did.didString() == Self.defaultDID {
                Text("Always active").appFont(AppTextRole.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
        NavigationLink("Add Moderation Service", destination: AddLabelerView())
          .disabled(!hasConfirmedPreferences || isSaving)
      } footer: {
        Text("Settings for a service’s own labels take precedence over your global settings. Bluesky moderation is always active; up to 19 additional services can be subscribed.")
      }
      .settingsControl(.init(rawValue: "moderation.labelers"))
      if !unavailable.isEmpty {
        Section("Unavailable Services") {
          Text("These services couldn’t be reached. They stay in your subscriptions until you remove them.")
            .appFont(AppTextRole.caption).foregroundStyle(.secondary)
          ForEach(unavailable, id: \.self) { did in
            HStack {
              Text("Unavailable Service")
              Spacer()
              Button("Remove", role: .destructive) { removeUnavailable(did) }.disabled(!hasConfirmedPreferences || isSaving)
            }
          }
        }
      }
      if let errorMessage {
        Section {
          Text(errorMessage).foregroundStyle(.secondary)
          Button("Try Again") { Task { await load() } }.disabled(isLoading || isSaving)
            .accessibilityIdentifier("moderation.labelers.retry")
        }
      }
    }
    .navigationTitle("Moderation Services")
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) { await load() }
    .refreshable { await load() }
  }

  static let defaultDID = "did:plc:ar7c4by46qjdydhdevvrndac"
  private func load() async {
    let token = UUID(); request = token
    let account = appState.userDID
    let manager = appState.preferencesManager
    let client = appState.atProtoClient
    isLoading = true; isSaving = false; errorMessage = nil; hasConfirmedPreferences = false
    defer { if request == token { isLoading = false } }
    do {
      guard let client else { throw PreferencesManagerError.clientNotInitialized }
      let preferences = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
      var dids = [try DID(didString: Self.defaultDID)]
      for item in preferences.labelers where !dids.contains(item.did) { dids.append(item.did) }
      let bounded = Array(dids.prefix(20))
      let finishAccountIO = try manager.beginSettingsAccountIO()
      defer { finishAccountIO?() }
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
      errorMessage = UserFacingError.message(for: error, action: "load moderation services")
    }
  }

  private func removeUnavailable(_ did: DID) {
    guard hasConfirmedPreferences, !isSaving else { return }
    let account = appState.userDID; let manager = appState.preferencesManager
    let editRequest = request
    isSaving = true
    Task { @MainActor in
      defer { if request == editRequest, manager.accountDID == account, appState.userDID == account { isSaving = false } }
      do {
        try await manager.removeLabelers([did.didString()], expectedAccountDID: account)
        guard request == editRequest, appState.userDID == account, manager.accountDID == account else { return }
        unavailable.removeAll { $0 == did }
      } catch {
        guard request == editRequest, manager.accountDID == account, appState.userDID == account else { return }
        hasConfirmedPreferences = false
        errorMessage = UserFacingError.message(for: error, action: "remove this service")
      }
    }
  }
}

/// One moderation service's labels, configured with the keys the moderation engine reads.
struct ModerationServiceSettingsView: View {
  let labeler: AppBskyLabelerDefs.LabelerViewDetailed
  @Environment(AppState.self) private var appState
  /// The account this screen last confirmed its preferences for with the server.
  @State private var confirmedAccountDID: String?
  @State private var isLoading = true
  @State private var isSaving = false
  @State private var pending: PendingLabelChoice?
  @State private var errorMessage: String?
  @State private var request = UUID()

  private var serviceDID: DID { labeler.creator.did }
  private var isDefaultService: Bool { serviceDID.didString() == LabelerSettingsView.defaultDID }

  /// The moderation engine's preferences for this account, once confirmed by this screen.
  private var confirmedPrefs: ModerationPrefs? {
    let policy = appState.moderationPolicy
    guard confirmedAccountDID == appState.userDID, policy.isConfirmed,
          policy.accountDID == appState.userDID else { return nil }
    return policy.prefs
  }

  var body: some View {
    let prefs = confirmedPrefs
    Form {
      Section {
        if let description = labeler.creator.description { Text(description).foregroundStyle(.secondary) }
        if isDefaultService { Text("Always active").foregroundStyle(.secondary) }
        else {
          Toggle("Subscribed", isOn: Binding(
            get: { prefs.map { LabelerLabelSettings.isSubscribed(serviceDID.didString(), prefs: $0) } ?? false },
            set: { setSubscribed($0) }))
            .disabled(prefs == nil || isSaving)
        }
      }
      if isLoading && prefs == nil { Section { ProgressView("Loading content settings…") } }
      if let prefs {
        let rows = LabelerLabelSettings.rows(
          labelValues: labeler.policies.labelValues.map(\.rawValue),
          definitions: labeler.policies.labelValueDefinitions ?? [],
          labelerDID: serviceDID.didString(), prefs: prefs)
        if rows.isEmpty {
          Section { Text("This service doesn’t publish any labels you can configure.").foregroundStyle(.secondary) }
        }
        ForEach(rows) { row in
          Section {
            LabelerLabelRowView(
              row: row, pending: pending?.preference(for: row.identifier), isSaving: isSaving,
              accessibilityID: "moderation.service.\(row.identifier)",
              onSelect: { save(identifier: row.identifier, preference: $0) },
              onReset: { reset(identifier: row.identifier) })
          }
        }
      }
      if isSaving { Section { ProgressView("Saving…") } }
      if let errorMessage {
        Section {
          Text(errorMessage).foregroundStyle(.secondary)
          Button("Reload Settings") { Task { await load() } }.disabled(isLoading || isSaving)
            .accessibilityIdentifier("moderation.service.retry")
        }
      }
    }
    .navigationTitle(labeler.creator.displayName ?? labeler.creator.handle.description)
    #if os(iOS)
    .toolbarTitleDisplayMode(.inline)
    #endif
    .task(id: appState.userDID) { await load() }
  }

  private func load() async {
    let token = UUID(); request = token
    let account = appState.userDID; let manager = appState.preferencesManager
    if confirmedAccountDID != account { confirmedAccountDID = nil }
    isLoading = true; isSaving = false; pending = nil; errorMessage = nil
    defer { if request == token { isLoading = false } }
    do {
      // A confirmed fetch rebuilds `appState.moderationPolicy` before it returns.
      _ = try await manager.refreshSettingsPreferences(expectedAccountDID: account)
      guard request == token, manager.accountDID == account, appState.userDID == account else { return }
      confirmedAccountDID = account
    } catch {
      guard request == token, manager.accountDID == account else { return }
      confirmedAccountDID = nil
      errorMessage = UserFacingError.message(for: error, action: "load this service’s settings")
    }
  }

  private func save(identifier: String, preference: LabelPreference) {
    let write = LabelerLabelSettings.serviceWrite(identifier: identifier, preference: preference, labelerDID: serviceDID)
    edit(pending: PendingLabelChoice(identifier: identifier, preference: preference)) { manager, account in
      try await manager.updateContentLabelPreferences([write], expectedAccountDID: account)
    }
  }

  private func reset(identifier: String) {
    let did = serviceDID
    edit { manager, account in
      try await manager.removeContentLabelOverride(label: identifier, labelerDid: did, expectedAccountDID: account)
    }
  }

  private func setSubscribed(_ enabled: Bool) {
    guard !isDefaultService, let prefs = confirmedPrefs,
          enabled != LabelerLabelSettings.isSubscribed(serviceDID.didString(), prefs: prefs) else { return }
    let did = serviceDID
    edit { manager, account in
      if enabled { try await manager.addLabeler(did, expectedAccountDID: account) }
      else { try await manager.removeLabeler(did, expectedAccountDID: account) }
    }
  }

  /// Runs one confirmed write. A confirmed write rebuilds `appState.moderationPolicy` before it returns.
  private func edit(
    pending choice: PendingLabelChoice? = nil,
    _ operation: @escaping @MainActor (PreferencesManager, String) async throws -> Void
  ) {
    guard confirmedPrefs != nil, !isLoading, !isSaving else { return }
    let account = appState.userDID; let manager = appState.preferencesManager
    let editRequest = request
    isSaving = true; pending = choice; errorMessage = nil
    Task { @MainActor in
      defer {
        if request == editRequest, manager.accountDID == account, appState.userDID == account {
          isSaving = false; pending = nil
        }
      }
      do {
        try await operation(manager, account)
      } catch {
        guard request == editRequest, manager.accountDID == account, appState.userDID == account else { return }
        confirmedAccountDID = nil
        errorMessage = UserFacingError.message(for: error, action: "save this setting")
      }
    }
  }
}

/// One label a moderation service publishes: a choice for a label the service defines, or the value in
/// effect and the reason it can't be changed here.
struct LabelerLabelRowView: View {
  let row: LabelerLabelRow
  /// A choice being saved for this row.
  let pending: LabelPreference?
  let isSaving: Bool
  let accessibilityID: String
  let onSelect: (LabelPreference) -> Void
  /// Removes this service's saved choice. `nil` hides the button.
  var onReset: (() -> Void)?

  var body: some View {
    switch row.control {
    case .selectable(let value, let canWarn, let source):
      VStack(alignment: .leading, spacing: 4) {
        LabelPreferenceSelector(
          title: row.name, description: row.description, canWarn: canWarn,
          selection: Binding(get: { pending ?? value }, set: { onSelect($0) }))
          .disabled(isSaving)
          .accessibilityIdentifier(accessibilityID)
        Text(Self.note(for: source))
          .appFont(AppTextRole.caption)
          .foregroundStyle(.secondary)
        if source == .service, let onReset {
          Button("Use Default Setting") { onReset() }
            .disabled(isSaving)
            .accessibilityIdentifier("\(accessibilityID).reset")
        }
      }
    case .configuredGlobally(let value, let hasServiceOverride):
      VStack(alignment: .leading, spacing: 4) {
        LabelPreferenceStatusRow(
          title: row.name, description: row.description, value: value,
          note: hasServiceOverride ? "This service has its own setting for this label."
            : "Set in Moderation settings for every service.",
          systemImage: "slider.horizontal.3")
        if hasServiceOverride, let onReset {
          Button("Use Moderation Setting") { onReset() }
            .disabled(isSaving)
            .accessibilityIdentifier("\(accessibilityID).reset")
        }
      }
    case .hiddenWhileAdultContentOff:
      LabelPreferenceStatusRow(
        title: row.name, description: row.description, value: .hide,
        note: "Hidden while adult content is off.", systemImage: "lock.fill")
    case .requiresSubscription:
      LabelPreferenceStatusRow(
        title: row.name, description: row.description, value: nil,
        note: "Subscribe to this service to use its labels.", systemImage: "info.circle")
    }
  }

  private static func note(for source: LabelerLabelRow.Source) -> String {
    switch source {
    case .service: "Saved for this service."
    case .global: "Using your global setting for this label."
    case .serviceDefault: "Using this service’s default."
    }
  }
}
