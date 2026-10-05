import Foundation
import SwiftUI
import SwiftData
import Petrel
import Testing
@testable import Catbird

@Suite("Recovered settings runtime wiring", .serialized)
struct SettingsRuntimeWiringTests {
  @Test("Appearance reset preserves accessibility, content, privacy, and inactive preference keys")
  @MainActor
  func appearanceResetScope() {
    let settings = AppSettingsModel(accountDID: "did:plc:settings-reset-fixture")
    settings.theme = "dark"
    settings.darkThemeMode = "black"
    settings.accentColor = "lavender"
    settings.fontStyle = "serif"
    settings.fontSize = "extraLarge"
    settings.lineSpacing = "relaxed"
    settings.letterSpacing = "loose"
    settings.dynamicTypeEnabled = false
    settings.maxDynamicTypeSize = "accessibility5"
    settings.requireAltText = true
    settings.largerAltTextBadges = true
    settings.disableHaptics = true
    settings.reduceMotion = true
    settings.prefersCrossfade = true
    settings.increaseContrast = true
    settings.boldText = true
    settings.displayScale = 1.2
    settings.showReadingTimeEstimates = true
    settings.highlightLinks = false
    settings.linkStyle = "both"
    settings.confirmBeforeActions = true
    settings.longPressDuration = 1.7
    settings.shakeToUndo = false
    settings.enableViaAttribution = false
    settings.sensitiveContentScanningEnabled = false
    settings.autoplayVideos = false
    settings.useInAppBrowser = false
    settings.showTrendingTopics = false
    settings.showTrendingVideos = false
    settings.threadSortOrder = "oldest"
    settings.prioritizeFollowedUsers = false
    settings.threadedReplies = true
    settings.showHiddenPosts = true
    settings.showSavedFeedSamples = true
    settings.setConsent(.hide, for: .youtube)
    settings.setConsent(.allow, for: .spotify)
    settings.useWebViewEmbeds = false
    settings.appLanguage = "fr"
    settings.primaryLanguage = "fr"
    settings.contentLanguages = ["fr", "es"]
    settings.hideNonPreferredLanguages = true
    settings.showLanguageIndicators = false
    settings.loggedOutVisibility = false
    let preserved = nonAppearanceValues(settings)

    settings.resetAppearanceToDefaults()

    #expect(settings.theme == "system")
    #expect(settings.darkThemeMode == "dim")
    #expect(settings.accentColor == "default")
    #expect(settings.fontStyle == "system")
    #expect(settings.fontSize == "default")
    #expect(settings.lineSpacing == "normal")
    #expect(settings.letterSpacing == "normal")
    #expect(nonAppearanceValues(settings) == preserved)
  }

  @Test("Appearance reset persists only to its account's SwiftData row")
  @MainActor
  func appearanceResetAccountPersistence() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: AppSettingsModel.self, configurations: configuration)
    let context = ModelContext(container)
    let first = AppSettingsModel(accountDID: "did:plc:first-reset-fixture")
    let second = AppSettingsModel(accountDID: "did:plc:second-reset-fixture")
    first.theme = "dark"
    first.requireAltText = true
    first.setConsent(.hide, for: .youtube)
    second.theme = "light"
    second.fontSize = "extraLarge"
    context.insert(first)
    context.insert(second)
    try context.save()

    first.resetAppearanceToDefaults()
    try context.save()

    let reloadedContext = ModelContext(container)
    let rows = try reloadedContext.fetch(FetchDescriptor<AppSettingsModel>())
    let reloadedFirst = try #require(rows.first { $0.id == first.id })
    let reloadedSecond = try #require(rows.first { $0.id == second.id })
    #expect(rows.count == 2)
    #expect(reloadedFirst.theme == "system")
    #expect(reloadedFirst.requireAltText)
    #expect(reloadedFirst.consent(for: .youtube) == .hide)
    #expect(reloadedSecond.theme == "light")
    #expect(reloadedSecond.fontSize == "extraLarge")
  }

  @MainActor
  private func nonAppearanceValues(_ settings: AppSettingsModel) -> [String] {
    [
      settings.id, String(settings.dynamicTypeEnabled), settings.maxDynamicTypeSize,
      String(settings.requireAltText), String(settings.largerAltTextBadges),
      String(settings.disableHaptics), String(settings.reduceMotion), String(settings.prefersCrossfade),
      String(settings.increaseContrast), String(settings.boldText), String(settings.displayScale),
      String(settings.showReadingTimeEstimates), String(settings.highlightLinks), settings.linkStyle,
      String(settings.confirmBeforeActions), String(settings.longPressDuration), String(settings.shakeToUndo),
      String(settings.enableViaAttribution), String(settings.sensitiveContentScanningEnabled),
      String(settings.autoplayVideos), String(settings.useInAppBrowser), String(settings.showTrendingTopics),
      String(settings.showTrendingVideos), settings.threadSortOrder, String(settings.prioritizeFollowedUsers),
      String(settings.threadedReplies), String(settings.showHiddenPosts), String(settings.showSavedFeedSamples),
      String(settings.useWebViewEmbeds), settings.appLanguage, settings.primaryLanguage,
      settings.contentLanguages.joined(separator: ","), String(settings.hideNonPreferredLanguages),
      String(settings.showLanguageIndicators), String(settings.loggedOutVisibility),
    ] + ExternalMediaProvider.allCases.map { settings.consent(for: $0).rawValue }
  }

  @Test("Clearing minimum reply likes differs from omitting the preference")
  func explicitReplyThresholdClear() {
    let existing = FeedViewPreference(
      hideReplies: false, hideRepliesByUnfollowed: true,
      hideRepliesByLikeCount: 12, hideReposts: true, hideQuotePosts: false
    )
    let omitted = PreferencesManager.applyingFeedViewChanges(to: existing, hideReposts: false)
    #expect(omitted.hideRepliesByLikeCount == 12)
    #expect(omitted.hideReposts == false)

    let cleared = PreferencesManager.applyingFeedViewChanges(to: existing, clearReplyLikeThreshold: true)
    #expect(cleared.hideRepliesByLikeCount == nil)
    #expect(cleared.hideReplies == existing.hideReplies)
    #expect(cleared.hideRepliesByUnfollowed == existing.hideRepliesByUnfollowed)
    #expect(cleared.hideReposts == existing.hideReposts)
    #expect(cleared.hideQuotePosts == existing.hideQuotePosts)

    let reenabled = PreferencesManager.applyingFeedViewChanges(to: cleared, hideRepliesByLikeCount: 2)
    #expect(reenabled.hideRepliesByLikeCount == 2)
    let zero = PreferencesManager.applyingFeedViewChanges(to: existing, hideRepliesByLikeCount: 0)
    #expect(zero.hideRepliesByLikeCount == 0)
    #expect(PreferencesManager.applyingFeedViewChanges(to: nil).hideRepliesByLikeCount == nil)
  }

  @Test("Settings refresh rejects a missing client instead of accepting cached defaults")
  @MainActor
  func settingsRefreshRequiresClient() async {
    let manager = PreferencesManager()
    do {
      _ = try await manager.refreshSettingsPreferences()
      Issue.record("A settings refresh must require a client")
    } catch PreferencesManagerError.clientNotInitialized {
      // No storage or network is consulted when the account client is unavailable.
    } catch {
      Issue.record("Unexpected refresh failure: \(error)")
    }
  }

  @Test("Clearing interests sends an empty list and preserves unrelated server preferences", arguments: [false, true])
  @MainActor
  func removeLastInterest(replaceAll: Bool) async throws {
    let transport = SettingsInterestsTransportFixture(tags: ["Art"])
    let (manager, context, local) = try makeInterestsManager(transport: transport, localTags: ["Art"])
    if replaceAll {
      try await manager.updateInterests([])
    } else {
      try await manager.removeInterest("Art")
    }

    #expect(transport.writes.count == 1)
    #expect(transport.tags.isEmpty)
    #expect(transport.serverPreferences.count == 3)
    if case .adultContentPref(let pref) = transport.serverPreferences[0] {
      #expect(pref.enabled)
    } else { Issue.record("Unrelated adult-content preference was replaced") }
    if case .threadViewPref(let pref) = transport.serverPreferences[2] {
      #expect(pref.sort == "top")
    } else { Issue.record("Unrelated thread preference was replaced") }
    #expect(local.interests.isEmpty)
    let fetched = try context.fetch(FetchDescriptor<Preferences>())
    #expect(fetched.first?.interests.isEmpty == true)
  }

  @Test("Failed interest replacement keeps the previously saved local and server selections")
  @MainActor
  func failedInterestsSavePreservesSelection() async throws {
    let transport = SettingsInterestsTransportFixture(tags: ["Art"])
    transport.writeStatus = 500
    let (manager, context, local) = try makeInterestsManager(transport: transport, localTags: ["Art"])
    do {
      try await manager.updateInterests([])
      Issue.record("A failed write must surface an error")
    } catch {
      #expect((error as NSError).code == 500)
    }
    #expect(transport.writes.count == 1)
    #expect(transport.tags == ["Art"])
    #expect(local.interests == ["Art"])
    #expect(try context.fetch(FetchDescriptor<Preferences>()).first?.interests == ["Art"])
  }

  @Test("Adding an interest preserves newer server selections missing from the local cache")
  @MainActor
  func addInterestUsesServerSnapshot() async throws {
    let transport = SettingsInterestsTransportFixture(tags: ["Art", "Travel"])
    let (manager, _, local) = try makeInterestsManager(transport: transport, localTags: ["Art"])
    try await manager.addInterest("Music")
    #expect(transport.tags == ["Art", "Travel", "Music"])
    #expect(local.interests == transport.tags)
    try await manager.addInterest("Music")
    #expect(transport.writes.count == 1)
  }

  @MainActor
  private func makeInterestsManager(
    transport: SettingsInterestsTransportFixture, localTags: [String]
  ) throws -> (PreferencesManager, ModelContext, Preferences) {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: Preferences.self, configurations: configuration)
    let context = ModelContext(container)
    let did = "did:plc:settings-interests-fixture"
    let local = Preferences(accountDID: did)
    local.interests = localTags
    context.insert(local)
    try context.save()
    let manager = PreferencesManager(modelContext: context, specificPreferencesTransport: transport.transport)
    manager.configure(accountDID: did)
    return (manager, context, local)
  }

  @Test("Required alt text exposes an actionable composer reason")
  func missingAltTextReason() {
    let state = PostComposerSubmitValidationState(canSubmit: false, reason: .missingAltText)
    #expect(state.message == "Add alt text to every media attachment before posting.")
    #expect(state.shouldShowInlineMessage)
  }

  @Test("Required alt text checks every attached image and video")
  func missingAltTextMediaPredicate() {
    #expect(
      !PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: ["A cat", "A dog"],
        videoAltText: "A short video"
      )
    )
    #expect(
      PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: ["A cat", "   "],
        videoAltText: nil
      )
    )
    #expect(
      PostComposerAltTextRequirement.hasMissingAltText(
        imageAltTexts: [],
        videoAltText: "\n"
      )
    )
  }

  @Test("Thread sort values map to supported API values")
  func threadSortMapping() {
    #expect(ThreadSortAPIMapper.apiValue(for: "hot") == "top")
    #expect(ThreadSortAPIMapper.apiValue(for: "top") == "top")
    #expect(ThreadSortAPIMapper.apiValue(for: "newest") == "newest")
    #expect(ThreadSortAPIMapper.apiValue(for: "oldest") == "oldest")
    #expect(ThreadSortAPIMapper.apiValue(for: "invalid") == "top")
  }

  @Test("Reading-time estimates start at one hundred words")
  func readingTimeThreshold() {
    #expect(PostReadingTime.minutes(forWordCount: 99) == nil)
    #expect(PostReadingTime.minutes(forWordCount: 100) == 1)
    #expect(PostReadingTime.minutes(forWordCount: 201) == 2)
  }

  @Test("Post links support every stored style and reject invalid styles safely")
  func linkPresentation() {
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: false, linkStyle: "both") == .disabled)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "color") == .color)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "underline") == .underline)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "both") == .both)
    #expect(PostLinkPresentationStyle.resolve(highlightLinks: true, linkStyle: "invalid") == .color)
  }

  @Test("Post link styles replace Petrel attributes for links, mentions, and tags")
  func actualLinkAttributes() throws {
    let destinations = [
      URL(string: "https://example.com")!,
      URL(string: "mention://did.example")!,
      URL(string: "tag://swift")!,
    ]

    for destination in destinations {
      var source = AttributedString("facet")
      let range = source.startIndex..<source.endIndex
      source[range].link = destination
      source[range].foregroundColor = .red
      source[range].underlineStyle = .double

      let disabled = source.applyingPostBodyLinkAccent(highlightLinks: false, linkStyle: "both")
      #expect(disabled[range].foregroundColor == nil)
      #expect(disabled[range].underlineStyle == nil)

      let color = source.applyingPostBodyLinkAccent(highlightLinks: true, linkStyle: "color")
      #expect(color[range].foregroundColor == Color("AccentTextColor"))
      #expect(color[range].underlineStyle == nil)

      let underline = source.applyingPostBodyLinkAccent(highlightLinks: true, linkStyle: "underline")
      #expect(underline[range].foregroundColor == nil)
      #expect(underline[range].underlineStyle == .single)

      let both = source.applyingPostBodyLinkAccent(highlightLinks: true, linkStyle: "both")
      #expect(both[range].foregroundColor == Color("AccentTextColor"))
      #expect(both[range].underlineStyle == .single)
    }
  }

  @Test("Initial visibility seed and failed rollback never issue programmatic writes")
  func loggedOutVisibilityProgrammaticChangesDoNotWrite() throws {
    var gate = LoggedOutVisibilityChangeGate()
    var requestCount = 0
    var rollbackCount = 0
    var alertCount = 0

    let didSeed = gate.prepareProgrammaticChange(current: true, target: false)
    #expect(didSeed)
    if gate.shouldWriteChange(to: false) { requestCount += 1 }

    if gate.shouldWriteChange(to: true) { requestCount += 1 }
    let didRollback = gate.prepareProgrammaticChange(current: true, target: false)
    #expect(didRollback)
    rollbackCount += 1
    alertCount += 1
    if gate.shouldWriteChange(to: false) { requestCount += 1 }

    #expect(requestCount == 1)
    #expect(rollbackCount == 1)
    #expect(alertCount == 1)

    let source = try settingsSource(named: "PrivacySecuritySettingsView.swift")
    let taskBody = try sourceSlice(
      source,
      from: ".task {",
      through: ".alert(\"Biometric Authentication\""
    )
    #expect(
      taskBody.contains(
        "setLoggedOutVisibilityProgrammatically(appState.appSettings.loggedOutVisibility)"
      )
    )
    #expect(!taskBody.contains("loggedOutVisibility = appState.appSettings.loggedOutVisibility"))
  }

  @Test("Display-only settings expose deterministic predicates")
  func displayPredicates() {
    #expect(PostLanguageIndicators.shouldShow(isEnabled: true, languageCount: 1))
    #expect(!PostLanguageIndicators.shouldShow(isEnabled: false, languageCount: 1))
    #expect(!PostLanguageIndicators.shouldShow(isEnabled: true, languageCount: 0))
    #expect(AltTextBadgeMetrics.side(isLarge: false) == 24)
    #expect(AltTextBadgeMetrics.side(isLarge: true) == 32)
    #expect(DestructiveActionConfirmation.shouldConfirm(isEnabled: true))
    #expect(!DestructiveActionConfirmation.shouldConfirm(isEnabled: false))
  }

  @Test("Haptic preference has one enabled-state mapping")
  func hapticPolicy() {
    #expect(HapticsPolicy.isEnabled(disableHaptics: false))
    #expect(!HapticsPolicy.isEnabled(disableHaptics: true))
  }

  @Test("Logged-out visibility preserves unrelated self-labels")
  func loggedOutVisibilityLabels() {
    let source = ["porn", "!no-unauthenticated", "graphic-media"]
    #expect(
      LoggedOutVisibilitySelfLabels.reconciled(source, isVisible: true)
        == ["porn", "graphic-media"]
    )
    #expect(
      LoggedOutVisibilitySelfLabels.reconciled(source, isVisible: false)
        == ["porn", "graphic-media", "!no-unauthenticated"]
    )
  }

  @Test("Change handle wires to progressive JIT identity:handle and supports service and custom domains")
  func changeHandleWiring() throws {
    let helpersSource = try settingsSource(named: "AccountSettingsHelpers.swift")
    let accountSettingsSource = try settingsSource(named: "AccountSettingsView.swift")
    
    // Verify HandleUpdateSheet has serviceDomain and customDomain modes
    #expect(helpersSource.contains("case serviceDomain"))
    #expect(helpersSource.contains("case customDomain"))
    
    // Verify describeServer is queried for available user domains
    #expect(helpersSource.contains("describeServer()"))
    #expect(helpersSource.contains("availableUserDomains"))
    
    // Verify custom domain verification instructions (DNS TXT and HTTPS Well-Known)
    #expect(helpersSource.contains("_atproto."))
    #expect(helpersSource.contains(".well-known/atproto-did"))
    
    // Verify resolution checks against user DID and resolveHandle
    #expect(helpersSource.contains("resolveHandle"))
    #expect(helpersSource.contains("ensurePermission(.identityHandle)"))
    #expect(helpersSource.contains("updateHandle(input:"))
    
    // Verify AccountSettingsView has active Change Handle presentation
    #expect(accountSettingsSource.contains("isShowingHandleSheet = true"))
    #expect(accountSettingsSource.contains("recordCurrentHandleChange"))
  }

  @Test("Account deactivation wires to progressive JIT account:status?action=manage and requires DEACTIVATE confirmation")
  func accountDeactivationWiring() throws {
    let source = try settingsSource(named: "AccountSettingsView.swift")
    
    #expect(source.contains("caseInsensitiveCompare(\"DEACTIVATE\")"))
    #expect(source.contains("ensurePermission(.accountStatusManage)"))
    #expect(source.contains("client.com.atproto.server.deactivateAccount("))
    #expect(source.contains("input: .init(deleteAfter: nil)"))
    #expect(source.contains("(200...299).contains(responseCode)"))
    #expect(source.contains("handleLogout()"))
    // OAuth sessions can't delete accounts: "Delete Account" hands off to the provider's account page
    #expect(!source.contains("deleteAccount("))
    #expect(source.contains("Button(\"Delete Account\", role: .destructive)"))
    #expect(source.contains("rawValue: \"account.delete\""))
  }

  @Test("Two-Factor Authentication wires to emailAuthFactor and JIT account:email?action=manage")
  func email2FAWiring() throws {
    let source = try settingsSource(named: "PrivacySecuritySettingsView.swift")
    
    #expect(source.contains("emailAuthFactor"))
    #expect(source.contains("ensurePermission(.accountEmailManage)"))
    #expect(source.contains("updateEmail(input:"))
    #expect(source.contains("requestEmailUpdate()"))
    #expect(source.contains("disable2FACode"))
  }

  @Test("Your Interests settings wires to PreferencesManager.updateInterests and SmartFeedDiscoveryView picker")
  func interestsSettingsWiring() throws {
    let contentMediaSource = try settingsSource(named: "ContentMediaSettingsView.swift")
    let interestsSource = try settingsSource(named: "InterestsSettingsView.swift")
    
    #expect(contentMediaSource.contains("InterestsSettingsView()"))
    #expect(contentMediaSource.contains("userInterestsCount"))
    
    #expect(interestsSource.contains("preferencesManager.getPreferences()"))
    #expect(interestsSource.contains("preferencesManager.updateInterests("))
    #expect(interestsSource.contains("InterestPickerSheet("))
  }

  @Test("External media consent state supports tri-state per provider and Bandcamp detection")
  func externalMediaConsentState() {
    // Verify all 12 providers (including Klipy)
    #expect(ExternalMediaProvider.allCases.count == 12)
    #expect(ExternalMediaProvider.allCases.contains(.bandcamp))
    #expect(ExternalMediaProvider.allCases.contains(.youtube))
    #expect(ExternalMediaProvider.allCases.contains(.spotify))
    #expect(ExternalMediaProvider.allCases.contains(.klipy))
    #expect(ExternalMediaProvider.klipy.displayName == "Klipy")
    #expect(ExternalMediaProvider.klipy.hostDescription == "static.klipy.com")
    
    // Verify model defaults to undecided
    let model = AppSettingsModel()
    for provider in ExternalMediaProvider.allCases {
      #expect(model.consent(for: provider) == .undecided)
    }
    
    // Verify per-provider allow/hide
    model.setConsent(.allow, for: .youtube)
    model.setConsent(.hide, for: .spotify)
    model.setConsent(.allow, for: .klipy)
    #expect(model.consent(for: .youtube) == .allow)
    #expect(model.consent(for: .spotify) == .hide)
    #expect(model.consent(for: .bandcamp) == .undecided)
    #expect(model.consent(for: .klipy) == .allow)
    
    // Verify Block All includes Klipy and all other providers
    for provider in ExternalMediaProvider.allCases {
      model.setConsent(.hide, for: provider)
    }
    for provider in ExternalMediaProvider.allCases {
      #expect(model.consent(for: provider) == .hide)
    }

    // Verify Allow All includes Klipy
    for provider in ExternalMediaProvider.allCases {
      model.setConsent(.allow, for: provider)
    }
    for provider in ExternalMediaProvider.allCases {
      #expect(model.consent(for: provider) == .allow)
    }
    
    // Verify Bandcamp URL detection
    if let trackURL = URL(string: "https://artist.bandcamp.com/track/my-track") {
      let detected = ExternalMediaType.detect(from: trackURL)
      #expect(detected == .bandcamp(url: "https://artist.bandcamp.com/track/my-track"))
      #expect(detected?.provider == .bandcamp)
    }
  }

  @Test("Bot label preserves unrelated self-labels")
  func botLabelPreservesUnrelatedSelfLabels() {
    let source = ["porn", "!no-unauthenticated", "graphic-media"]
    #expect(
      AutomationBotSelfLabels.reconciled(source, isBot: true)
        == ["porn", "!no-unauthenticated", "graphic-media", "bot"]
    )
    
    let botSource = ["porn", "!no-unauthenticated", "bot", "graphic-media"]
    #expect(
      AutomationBotSelfLabels.reconciled(botSource, isBot: false)
        == ["porn", "!no-unauthenticated", "graphic-media"]
    )
  }

  @Test("Algorithmic visibility opt-out wires to app.bsky.actor.contentVisibilityDeclaration")
  func algorithmicVisibilityWiring() throws {
    let source = try settingsSource(named: "PrivacySecuritySettingsView.swift")
    
    #expect(source.contains("app.bsky.actor.contentVisibilityDeclaration"))
    #expect(source.contains("hideFromAlgorithmicRecommendations"))
    #expect(source.contains("AppBskyActorContentVisibilityDeclaration"))
  }

  @Test("Activity privacy wires to app.bsky.notification.declaration")
  func activityPrivacyWiring() throws {
    let privacySource = try settingsSource(named: "PrivacySecuritySettingsView.swift")
    let activitySource = try settingsSource(named: "ActivityPrivacySettingsView.swift")
    
    #expect(privacySource.contains("ActivityPrivacySettingsView()"))
    #expect(activitySource.contains("app.bsky.notification.declaration"))
    #expect(activitySource.contains("AppBskyNotificationDeclaration"))
    #expect(activitySource.contains("followers"))
    #expect(activitySource.contains("mutuals"))
    #expect(activitySource.contains("none"))
  }

  @Test("CAR repository export wires to com.atproto.sync.getRepo and fileExporter")
  func carExportWiring() throws {
    let source = try settingsSource(named: "AccountSettingsView.swift")
    
    #expect(source.contains("client.com.atproto.sync.getRepo"))
    #expect(source.contains("isShowingFileExporter"))
    #expect(source.contains("CARFileDocument"))
    #expect(source.contains("-repository.car"))
  }

  @Test("App icon settings wires to alternateIconName CatbirdClassic")
  func appIconWiring() throws {
    let appearanceSource = try settingsSource(named: "AppearanceSettingsView.swift")
    let iconSource = try settingsSource(named: "AppIconSettingsView.swift")
    
    #expect(appearanceSource.contains("SettingsLink(screen: .appIcon"))
    #expect(appearanceSource.contains("supportsAlternateIcons"))
    #expect(iconSource.contains("CatbirdClassic"))
    #expect(iconSource.contains("setAlternateIconName"))
  }
}

private func settingsSource(named filename: String) throws -> String {
  try repositorySource(
    components: ["Catbird", "Features", "Settings", "Views", filename]
  )
}

private func coreStateSource(named filename: String) throws -> String {
  try repositorySource(components: ["Catbird", "Core", "State", filename])
}

private func repositorySource(components: [String]) throws -> String {
  let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  let repositoryRoot = testsDirectory.deletingLastPathComponent()
  let sourceURL = components.reduce(repositoryRoot) { partial, component in
    partial.appendingPathComponent(component)
  }
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

private func sourceSlice(_ source: String, from start: String, through end: String) throws -> Substring {
  guard let startRange = source.range(of: start),
        let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex)
  else {
    throw SettingsRuntimeSourceError.missingBoundary
  }
  return source[startRange.lowerBound..<endRange.lowerBound]
}

@MainActor
private final class SettingsInterestsTransportFixture {
  var serverPreferences: [AppBskyActorDefs.PreferencesForUnionArray]
  var writes: [[AppBskyActorDefs.PreferencesForUnionArray]] = []
  var writeStatus = 200

  init(tags: [String]) {
    self.serverPreferences = [
      .adultContentPref(.init(enabled: true)),
      .interestsPref(.init(tags: tags)),
      .threadViewPref(.init(sort: "top")),
    ]
  }

  var tags: [String] {
    for item in self.serverPreferences {
      if case .interestsPref(let value) = item { return value.tags }
    }
    return []
  }

  var transport: PreferencesManager.SpecificPreferencesTransport {
    .init(
      getPreferences: { self.serverPreferences },
      putPreferences: { items in
        self.writes.append(items)
        if self.writeStatus == 200 { self.serverPreferences = items }
        return self.writeStatus
      }
    )
  }
}

private enum SettingsRuntimeSourceError: Error {
  case missingBoundary
}

