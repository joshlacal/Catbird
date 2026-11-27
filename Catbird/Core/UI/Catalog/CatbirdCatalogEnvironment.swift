//
//  CatbirdCatalogEnvironment.swift
//  Catbird
//
//  Offline session factory for `-CatbirdCatalog` and Tier-1 snapshot tests.
//  Installs `OfflineFixtureURLProtocol`, creates an isolated in-memory
//  SwiftData container + `AppState`, and applies theme/font/a11y trap axes.
//

#if DEBUG
import Foundation
import Petrel
import PetrelCatbird
import SwiftData
#if os(iOS)
import UIKit
#endif

@MainActor
final class CatbirdCatalogSession {
  let appState: AppState
  let sceneContext: SceneNavigationContext
  let modelContainer: ModelContainer

  init(appState: AppState, sceneContext: SceneNavigationContext, modelContainer: ModelContainer) {
    self.appState = appState
    self.sceneContext = sceneContext
    self.modelContainer = modelContainer
  }

  /// Applies a new launch/trap configuration in-place without recreating the session.
  func apply(config: CatbirdCatalogLaunchConfig) {
    CatbirdCatalogEnvironment.apply(config: config, to: appState)
  }

  func cleanup() {
    sceneContext.invalidate()
    appState.cleanup()
  }
}

@MainActor
enum CatbirdCatalogEnvironment {

  /// Builds a fully offline, deterministic `CatbirdCatalogSession` backed by
  /// `OfflineFixtureURLProtocol` and in-memory SwiftData storage.
  static func makeSession(
    for config: CatbirdCatalogLaunchConfig,
    strictOffline: Bool = true
  ) async throws -> CatbirdCatalogSession {
    PetrelCatbirdLexicons.register()
    await OfflineFixtureURLProtocol.install(strict: strictOffline)

    #if os(iOS)
    if config.disableAnimations {
      UIView.setAnimationsEnabled(false)
    }
    #endif

    let did = PreviewContainer.fixtureUserDID
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try CatbirdSwiftDataStore.makeContainer(configuration: configuration)

    let settings = AppSettingsModel(accountDID: did)
    settings.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    container.mainContext.insert(settings)
    try container.mainContext.save()

    let client = await ATProtoClient(
      baseURL: URL(string: "https://127.0.0.1")!,
      userAgent: "Catbird/1.0-Catalog"
    )
    let appState = AppState(
      userDID: did,
      client: client,
      regulatoryChecker: PreviewOfflineAgeChecker()
    )
    if let bot = PreviewFixtures.profileBot {
      appState.currentUserProfile = AppBskyActorDefs.ProfileViewBasic(
        did: bot.did,
        handle: bot.handle,
        displayName: bot.displayName,
        pronouns: bot.pronouns,
        avatar: bot.avatar,
        associated: bot.associated,
        viewer: bot.viewer,
        labels: bot.labels,
        createdAt: bot.createdAt,
        verification: bot.verification,
        status: bot.status,
        debug: bot.debug
      )
    }

    appState.appSettings.initialize(with: container.mainContext, accountDID: did)
    appState.composerDraftManager.configureForTesting(modelContext: container.mainContext)
    apply(config: config, to: appState)

    let sceneContext = SceneNavigationContext(appState: appState, sceneID: UUID())
    return CatbirdCatalogSession(
      appState: appState,
      sceneContext: sceneContext,
      modelContainer: container
    )
  }

  /// Synchronizes `ThemeManager`, `FontManager`, and `AppSettings` to match `config`.
  static func apply(config: CatbirdCatalogLaunchConfig, to appState: AppState) {
    #if os(iOS)
    FontManager.overrideContentSizeCategory = config.uiContentSizeCategory
    appState.fontManager.refreshContentSizeCategory()
    #endif

    appState.appSettings.theme = config.theme
    appState.appSettings.darkThemeMode = config.darkThemeMode
    appState.appSettings.accentColor = config.accentColor
    appState.appSettings.fontStyle = config.fontStyle
    appState.appSettings.fontSize = config.fontSize
    appState.appSettings.lineSpacing = config.lineSpacing
    appState.appSettings.dynamicTypeEnabled = true
    appState.appSettings.maxDynamicTypeSize = AppTextSizeLimit.fullSystemRange
    appState.appSettings.reduceMotion = config.reduceMotion
    appState.appSettings.increaseContrast = config.increaseContrast
    appState.appSettings.boldText = config.boldText

    appState.fontManager.applyFontSettings(
      fontStyle: config.fontStyle,
      fontSize: config.fontSize,
      lineSpacing: config.lineSpacing,
      letterSpacing: "normal",
      dynamicTypeEnabled: true,
      maxDynamicTypeSize: AppTextSizeLimit.fullSystemRange,
      effectiveBoldText: config.boldText
    )

    appState.themeManager.applyTheme(
      theme: config.theme,
      darkThemeMode: config.darkThemeMode,
      accentColor: config.accentColor,
      forceImmediateNavigationTypography: true
    )

    UserDefaults.standard.set(config.reduceTransparency, forKey: "CatbirdCatalogReduceTransparency")
  }
}
#endif
