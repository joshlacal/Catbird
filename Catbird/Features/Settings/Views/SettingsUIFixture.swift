#if DEBUG
import Petrel
import SwiftData
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Production Settings views with an in-memory settings store and no authenticated client.
/// Only launched explicitly by `--settings-ui-fixture` on the lane's isolated simulator.
struct SettingsUIFixture: View {
  @State private var appState: AppState?
  @State private var container: ModelContainer?
  @State private var failure: String?
  @State private var supportStore = SupportTipStore(client: SettingsTipFixtureClient())

  private let arguments = ProcessInfo.processInfo.arguments

  private var screen: String {
    let prefix = "--settings-screen="
    return arguments.first(where: { $0.hasPrefix(prefix) })
      .map { String($0.dropFirst(prefix.count)) } ?? "root"
  }

  var body: some View {
    Group {
      if let appState, let container {
        Group {
          if screen == "root" {
            SettingsView()
          } else {
            NavigationStack { destination }
          }
        }
        .environment(appState)
        .environment(\.fontManager, appState.fontManager)
        .modelContainer(container)
        .environment(\.dynamicTypeSize, arguments.contains("--settings-large-text") ? .accessibility3 : .large)
        .preferredColorScheme(arguments.contains("--settings-dark") ? .dark : .light)
      } else if let failure {
        ContentUnavailableView("Settings fixture failed", systemImage: "exclamationmark.triangle", description: Text(failure))
      } else {
        ProgressView("Preparing Settings")
      }
    }
    .task { await prepare() }
  }

  @ViewBuilder
  private var destination: some View {
    switch screen {
    case "appearance": AppearanceSettingsView()
    case "accessibility": AccessibilitySettingsView()
    case "content": ContentMediaSettingsView()
    case "about": AboutSettingsView(supportStore: supportStore)
    default: SettingsView()
    }
  }

  @MainActor
  private func prepare() async {
    guard appState == nil else { return }
    do {
      let accountDID = "did:plc:settingsuifixture"
      let container = try ModelContainer(
        for: AppSettingsModel.self, Preferences.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
      )
      // Inserting first prevents migration from any unrelated preference row.
      let settings = AppSettingsModel(accountDID: accountDID)
      if arguments.contains("--settings-large-text") {
        settings.maxDynamicTypeSize = "accessibility5"
      }
      container.mainContext.insert(settings)
      try container.mainContext.save()
      let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
      let state = AppState(userDID: accountDID, client: client)
      if arguments.contains("--settings-server-unavailable") {
        state.appSettings.initialize(with: container.mainContext, accountDID: accountDID)
      } else {
        state.initializePreferencesManager(with: container.mainContext)
      }
      // Do not initialize AppState networking or attach a PreferencesManager client.
      // Account/server controls intentionally exercise their unavailable state.
      self.container = container
      self.appState = state
      #if os(iOS)
      logger.info("[SettingsFixture] preferredContentSizeCategory=\(UIApplication.shared.preferredContentSizeCategory.rawValue, privacy: .public)")
      #endif
    } catch {
      failure = error.localizedDescription
    }
  }
}

/// Predictable presentation data derived from the existing local catalog, never a store purchase.
@MainActor
private final class SettingsTipFixtureClient: SupportTipClient {
  private var loadCount = 0

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

  func purchase(productID: String) async throws -> SupportTipPurchaseResult { .cancelled }
  func transactionUpdates() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
  func unfinishedTransactions() -> AsyncStream<SupportTipVerification> { AsyncStream { $0.finish() } }
  func storefrontUpdates() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
#endif
