#if DEBUG
import Foundation
import Petrel
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Production Settings, only on a fresh Root-owned simulator with disposable app
/// and app-group domains. AppSettings still mirrors confirmed scoped defaults.
/// Uses Root-accepted final Settings views without authenticated account adoption.
@MainActor
struct SettingsUIFixture: View {
  @State private var appState: AppState?
  @State private var sceneContext: SceneNavigationContext?
  @State private var container: ModelContainer?
  @State private var failure: String?
  @State private var supportStore: SupportTipStore?
  @State private var evidence: SettingsFixtureEvidence?
  @State private var draftGuard = SettingsDraftGuard()

  private let arguments = ProcessInfo.processInfo.arguments

  private var screen: String {
    let prefix = "--settings-screen="
    return arguments.first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)) } ?? "root"
  }

  var body: some View {
    Group {
      if let appState, let container, let sceneContext, let supportStore, let evidence {
        Group {
          if screen == "root" {
            SettingsView()
          } else {
            NavigationStack {
              destination(supportStore: supportStore)
                .navigationDestination(for: SettingsTarget.self) { target in
                  // Nested About is excluded from offline journeys: its normal
                  // production route owns StoreKit rather than this local store.
                  SettingsDestinationView(target: target)
                }
            }
            .environment(\.settingsDraftGuard, draftGuard)
          }
        }
        .environment(appState)
        .environment(sceneContext)
        .environment(AppStateManager.shared)
        .environment(\.fontManager, appState.fontManager)
        .environment(\.feedPreferenceLoadObserver, { [weak evidence] event in
          evidence?.observeFeedLoad(event)
        })
        .modelContainer(container)
        .preferredColorScheme(arguments.contains("--settings-dark") ? .dark : .light)
        .overlay(alignment: .bottomLeading) {
          #if os(iOS)
          SettingsFixtureNativeProbe(evidence: evidence)
            .frame(width: 2, height: 2)
          #else
          Text("Native Settings qualification requires iOS")
          #endif
        }
      } else if let failure {
        ContentUnavailableView("Settings fixture failed", systemImage: "exclamationmark.triangle", description: Text(failure))
          .accessibilityIdentifier("settings.fixture.failure")
      } else {
        ProgressView("Preparing Settings")
      }
    }
    .task { await prepare() }
    .onDisappear {
      sceneContext?.invalidate()
      appState?.cleanup()
      SettingsFixtureRefusalProtocol.uninstall()
    }
  }

  @ViewBuilder
  private func destination(supportStore: SupportTipStore) -> some View {
    switch screen {
    // Retain direct historical screens; new tests use canonical typed targets.
    case "content": ContentMediaSettingsView()
    case "about": AboutSettingsView(supportStore: supportStore)
    default:
      if let target = SettingsScreenID(rawValue: screen), target != .about {
        SettingsDestinationView(target: SettingsTarget(screen: target))
      } else {
        ContentUnavailableView("Unsupported local Settings target", systemImage: "exclamationmark.triangle")
          .accessibilityIdentifier("settings.fixture.failure")
      }
    }
  }

  @MainActor
  private func prepare() async {
    guard appState == nil else { return }
    do {
      // This precedes client, AppState, model store and support-store creation.
      try Self.requireUnauthenticatedHost()
      guard SettingsFixtureRefusalProtocol.install() else { throw FixtureSetupError.protocolUnavailable }
      let accountDID = "did:plc:settingsfixture" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
      let suiteName = "settings.native.fixture.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { throw FixtureSetupError.defaultsUnavailable }
      let baseline = SettingsFixtureEvidence.defaultsSnapshot(accountDID: accountDID)
      let container = try ModelContainer(
        for: AppSettingsModel.self, Preferences.self, DraftPost.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
      )
      // Inserting first prevents migration from any unrelated preference row.
      let settings = AppSettingsModel(accountDID: accountDID)
      if arguments.contains("--settings-appearance-custom") {
        settings.theme = "dark"
      }
      if arguments.contains("--settings-large-text") {
        settings.maxDynamicTypeSize = "accessibility5"
      }
      container.mainContext.insert(settings)
      container.mainContext.insert(Preferences(accountDID: accountDID))
      try container.mainContext.save()
      let client = await ATProtoClient(baseURL: URL(string: "https://settings-fixture.invalid")!)
      try Task.checkCancellation()
      try Self.requireUnauthenticatedHost()
      let state = AppState(userDID: accountDID, client: client, regulatoryChecker: NoAgePrompt())
      state.composerDraftManager.configureForTesting(modelContext: container.mainContext)
      let manager = ComposerDraftManager(accountDID: accountDID, modelContext: container.mainContext, defaults: defaults)
      let sceneID = UUID()
      let session = SceneComposerEditingSession(manager: manager, accountDID: accountDID,
        sceneID: sceneID, defaults: defaults)
      let persistenceFixture = SettingsPersistenceFixture(
        failFirstFetch: arguments.contains("--settings-storage-unavailable")
      )
      state.appSettings.persistence = persistenceFixture.persistence
      if arguments.contains("--settings-server-unavailable") {
        state.appSettings.initialize(with: container.mainContext, accountDID: accountDID)
      } else {
        state.initializePreferencesManager(with: container.mainContext)
      }
      // Initialization uses a real, pre-seeded in-memory row. Only the first user edit fails.
      persistenceFixture.failNextSave = arguments.contains("--settings-save-failure")
      // Do not initialize AppState networking or attach a PreferencesManager client.
      // Account/server controls intentionally exercise their unavailable state.
      let tipClient = SettingsTipFixtureClient()
      self.supportStore = SupportTipStore(client: tipClient)
      self.evidence = SettingsFixtureEvidence(appState: state, session: session,
        suiteName: suiteName, baseline: baseline, persistence: persistenceFixture, tipClient: tipClient)
      self.container = container
      self.sceneContext = SceneNavigationContext(appState: state, sceneID: sceneID, composerEditingSession: session)
      self.appState = state
      #if os(iOS)
      logger.info("[SettingsFixture] preferredContentSizeCategory=\(UIApplication.shared.preferredContentSizeCategory.rawValue, privacy: .public)")
      print("SETTINGS_FIXTURE_CATEGORY \(UIApplication.shared.preferredContentSizeCategory.rawValue)")
      #endif
    } catch {
      SettingsFixtureRefusalProtocol.uninstall()
      failure = error.localizedDescription
    }
  }

  private static func requireUnauthenticatedHost() throws {
    let shared = AppStateManager.shared
    guard shared.authentication.client == nil, shared.authentication.state.userDID == nil,
      !shared.authentication.state.isAuthenticating, shared.lifecycle.appState == nil,
      shared.lifecycle.userDID == nil else { throw FixtureSetupError.authenticatedHost }
  }

  private enum FixtureSetupError: LocalizedError {
    case authenticatedHost, protocolUnavailable, defaultsUnavailable
    var errorDescription: String? {
      switch self {
      case .authenticatedHost: "Use a fresh unauthenticated Root-owned simulator with disposable app and app-group domains."
      case .protocolUnavailable: "The local HTTP(S) refusal protocol could not be installed."
      case .defaultsUnavailable: "The isolated editing-session defaults suite could not be created."
      }
    }
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    #if os(iOS)
    @MainActor func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
    #endif
  }
}

@MainActor
private final class SettingsPersistenceFixture {
  private var failNextFetch: Bool
  var failNextSave = false
  private(set) var fetchCalls = 0
  private(set) var saveCalls = 0

  init(failFirstFetch: Bool) {
    self.failNextFetch = failFirstFetch
  }

  var persistence: AppSettings.Persistence {
    let live = AppSettings.Persistence.live
    return AppSettings.Persistence(
      fetch: { context, accountDID in
        self.fetchCalls += 1
        if self.failNextFetch {
          self.failNextFetch = false
          throw FixtureFailure()
        }
        return try live.fetch(context, accountDID)
      },
      save: { context in
        self.saveCalls += 1
        if self.failNextSave {
          self.failNextSave = false
          throw FixtureFailure()
        }
        try live.save(context)
      }
    )
  }

  private struct FixtureFailure: LocalizedError {
    var errorDescription: String? { "The isolated Settings test store is temporarily unavailable." }
  }
}

/// Predictable presentation data derived from the existing local catalog, never a store purchase.
@MainActor
private final class SettingsTipFixtureClient: SupportTipClient {
  private(set) var loadCount = 0
  private(set) var purchaseAttempts = 0

  func products(for identifiers: Set<String>) async throws -> [SupportTipProduct] {
    loadCount += 1
    if ProcessInfo.processInfo.arguments.contains("--settings-support-retry"), loadCount == 1 {
      return []
    }
    return [
      SupportTipProduct(id: "blue.catbird.support.onetime.small", displayName: "Small Support", displayPrice: "$4.99", price: 4.99),
      SupportTipProduct(id: "blue.catbird.support.onetime.medium", displayName: "Medium Support", displayPrice: "$9.99", price: 9.99),
      SupportTipProduct(id: "blue.catbird.support.onetime.large", displayName: "Large Support", displayPrice: "$19.99", price: 19.99),
      SupportTipProduct(id: "blue.catbird.support.onetime.extralarge", displayName: "Extra Large Support", displayPrice: "$49.99", price: 49.99)
    ].filter { identifiers.contains($0.id) }
  }

  func purchase(productID: String) async throws -> SupportTipPurchaseResult {
    purchaseAttempts += 1
    return .cancelled
  }
  func transactionUpdates() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
  func unfinishedTransactions() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
  func storefrontUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// Records the actual intercepted HTTP(S) request, then always rejects it. It
/// never forwards, resolves, manufactures service data, or performs a write.
private final class SettingsFixtureRefusalProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var records: [[String: String]] = []
  nonisolated(unsafe) private static var requests = 0
  nonisolated(unsafe) private static var writes = 0
  nonisolated(unsafe) private static var unexpected = 0

  static func install() -> Bool {
    lock.withLock { records = []; requests = 0; writes = 0; unexpected = 0 }
    return URLProtocol.registerClass(Self.self)
  }
  static func uninstall() { URLProtocol.unregisterClass(Self.self) }
  static var snapshot: [String: Any] {
    lock.withLock { ["refusedRequests": requests, "attemptedWrites": writes,
      "unexpectedRequests": unexpected, "records": records, "recordLimit": 64] }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let method = (request.httpMethod ?? "GET").uppercased()
    let path = request.url?.path ?? ""
    // The category-only root may request profile data. Preferences failures
    // normally occur before HTTP because the fixture manager has no client.
    let declaredReads = ["/xrpc/app.bsky.actor.getProfile", "/xrpc/app.bsky.actor.getPreferences"]
    Self.lock.withLock {
      Self.requests += 1
      if !["GET", "HEAD"].contains(method) { Self.writes += 1 }
      if !declaredReads.contains(path) { Self.unexpected += 1 }
      if Self.records.count < 64 {
        Self.records.append(["method": method, "host": request.url?.host ?? "", "path": path])
      }
    }
    client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
  }
  override func stopLoading() {}
}

@MainActor
private final class SettingsFixtureEvidence {
  let appState: AppState
  let session: SceneComposerEditingSession
  let suiteName: String
  let baseline: [String: String]
  let persistence: SettingsPersistenceFixture
  let tipClient: SettingsTipFixtureClient
  private var feedEditorID: UUID?
  private var feedEditorChanged = false
  private var feedEntries = 0
  private var feedRefusals = 0
  private var feedNotCurrentRefusals = 0
  private var feedReadEntries = 0
  private var feedFinishedAttempts = 0
  private var feedLastEnteredAttempt: UInt64 = 0
  private var feedLastRefusedAttempt: UInt64 = 0
  private var feedLastRefusalReason = ""
  private var feedLastFinishedAttempt: UInt64 = 0
  private var feedLastFinishedRefusalReason = ""
  init(appState: AppState, session: SceneComposerEditingSession, suiteName: String,
    baseline: [String: String], persistence: SettingsPersistenceFixture, tipClient: SettingsTipFixtureClient) {
    self.appState = appState; self.session = session; self.suiteName = suiteName
    self.baseline = baseline; self.persistence = persistence; self.tipClient = tipClient
  }
  func observeFeedLoad(_ event: FeedPreferenceEditor.DebugLoadEvent) {
    if let feedEditorID {
      guard feedEditorID == event.editorID else { feedEditorChanged = true; return }
    } else {
      feedEditorID = event.editorID
    }
    switch event.phase {
    case .entered:
      feedEntries += 1
      feedLastEnteredAttempt = event.attemptSequence
    case .refused(let reason):
      feedRefusals += 1
      if reason == .notCurrentAccount { feedNotCurrentRefusals += 1 }
      feedLastRefusedAttempt = event.attemptSequence
      feedLastRefusalReason = reason.rawValue
    case .readEntered:
      feedReadEntries += 1
    case .finished(let reason):
      feedFinishedAttempts += 1
      feedLastFinishedAttempt = event.attemptSequence
      feedLastFinishedRefusalReason = reason?.rawValue ?? ""
    }
  }
  static func defaultsSnapshot(accountDID: String) -> [String: String] {
    let keys = ["theme", "darkThemeMode", "accentColor", "fontStyle", "fontSize", "lineSpacing",
      "letterSpacing", "dynamicTypeEnabled", "maxDynamicTypeSize", "useWebViewEmbeds"]
      + ExternalMediaProvider.allCases.map { "externalMediaConsent.\($0.rawValue)" }
    var values: [String: String] = [:]
    for key in keys {
      values["scoped." + key] = String(describing: UserDefaults.standard.object(
        forKey: AppSettingsModel.scopedKey(key, accountDID: accountDID)))
      values["global." + key] = String(describing: UserDefaults.standard.object(forKey: key))
    }
    for key in ["theme", "darkThemeMode"] {
      values["group." + key] = String(describing: AppSettingsModel.sharedDefaults().object(forKey: key))
    }
    values["global.lastActiveSettingsAccountDID"] = String(describing:
      UserDefaults.standard.object(forKey: "lastActiveSettingsAccountDID"))
    return values
  }
  #if os(iOS)
  func sample(window: UIWindow, sampleCount: Int) -> [String: Any] {
    let shared = AppStateManager.shared
    let defaults = Self.defaultsSnapshot(accountDID: appState.userDID)
    let changed = defaults.keys.filter { defaults[$0] != baseline[$0] }.sorted()
    return ["ready": true, "sampleCount": sampleCount, "accountDID": appState.userDID,
      "sceneID": session.sceneID.uuidString, "editingDefaultsSuite": suiteName,
      "noAuthenticatedHost": shared.authentication.client == nil && shared.authentication.state.userDID == nil
        && !shared.authentication.state.isAuthenticating && shared.lifecycle.appState == nil
        && shared.lifecycle.userDID == nil,
      "draftTestingConfigurationApplied": true, "currentDraftAbsent": session.currentDraft == nil,
      "persistenceState": String(describing: appState.appSettings.persistenceState),
      "canEditLocalSettings": appState.appSettings.canEditPersistedSettings,
      "localFetchCalls": persistence.fetchCalls, "localSaveCalls": persistence.saveCalls,
      "maxTextSize": appState.appSettings.maxDynamicTypeSize,
      "scopedDefaultsChangedKeys": changed.filter { $0.hasPrefix("scoped.") },
      "globalOrGroupDefaultsChangedKeys": changed.filter { !$0.hasPrefix("scoped.") },
      "defaultsBoundary": "Actual AppSettings scoped writes in disposable domains; session recovery uses UUID suite.",
      "transport": SettingsFixtureRefusalProtocol.snapshot,
      "feedLoad": ["editorID": feedEditorID?.uuidString ?? "", "editorChanged": feedEditorChanged,
        "sceneID": session.sceneID.uuidString, "entries": feedEntries, "refusals": feedRefusals,
        "notCurrentAccountRefusals": feedNotCurrentRefusals, "readEntries": feedReadEntries,
        "finishedAttempts": feedFinishedAttempts, "lastEnteredAttempt": feedLastEnteredAttempt,
        "lastRefusedAttempt": feedLastRefusedAttempt, "lastRefusalReason": feedLastRefusalReason,
        "lastFinishedAttempt": feedLastFinishedAttempt, "lastFinishedRefusalReason": feedLastFinishedRefusalReason],
      "fakeSupportLoads": tipClient.loadCount, "fakeSupportPurchaseAttempts": tipClient.purchaseAttempts,
      "systemTextCategory": UIApplication.shared.preferredContentSizeCategory.rawValue,
      "fontManagerTextCategory": appState.fontManager.currentContentSizeCategory.uiContentSizeCategory.rawValue,
      "nativeWindowStyle": window.traitCollection.userInterfaceStyle.rawValue,
      "nativeWindowWidth": Double(window.bounds.width), "nativeWindowHeight": Double(window.bounds.height)]
  }
  #endif
}

#if os(iOS)
private struct SettingsFixtureNativeProbe: UIViewRepresentable {
  let evidence: SettingsFixtureEvidence
  func makeUIView(context: Context) -> ProbeView { ProbeView(evidence: evidence) }
  func updateUIView(_ view: ProbeView, context: Context) { view.publish() }
  static func dismantleUIView(_ view: ProbeView, coordinator: ()) { view.stop() }
  @MainActor final class ProbeView: UIView {
    private let evidence: SettingsFixtureEvidence
    private var timer: Timer?
    private var sampleCount = 0
    init(evidence: SettingsFixtureEvidence) {
      self.evidence = evidence
      super.init(frame: .zero)
      isAccessibilityElement = true
      accessibilityIdentifier = "settings.fixture.counters"
      accessibilityLabel = "Actual native Settings fixture state and refused requests"
      accessibilityTraits = .staticText
      isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func didMoveToWindow() {
      super.didMoveToWindow(); stop()
      guard window != nil else { return }
      let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.publish() }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
      publish()
    }
    func stop() { timer?.invalidate(); timer = nil }
    func publish() {
      guard let window else { return }
      sampleCount += 1
      if let data = try? JSONSerialization.data(withJSONObject: evidence.sample(window: window,
        sampleCount: sampleCount), options: [.sortedKeys]) {
        accessibilityValue = String(decoding: data, as: UTF8.self)
      }
    }
  }
}
#endif
#endif
