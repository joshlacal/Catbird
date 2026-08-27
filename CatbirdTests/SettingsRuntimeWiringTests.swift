import Foundation
import SwiftUI
import Testing
@testable import Catbird

@Suite("Recovered settings runtime wiring", .serialized)
struct SettingsRuntimeWiringTests {
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
    #expect(ThreadSortAPIMapper.apiValue(for: "invalid") == "oldest")
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

  @Test("Retention cleanup scans every conversation and keeps one replaceable worker")
  func retentionCoordinatorLifecycle() async {
    let probe = RetentionCoordinatorProbe()
    let coordinator = MLSEpochRetentionCleanupCoordinator()
    let scan: MLSEpochRetentionCleanupCoordinator.Scan = {
      await probe.recordScan()
      return [
        .init(conversationID: "one", currentEpoch: 3),
        .init(conversationID: "two", currentEpoch: 7),
      ]
    }
    let cleanup: MLSEpochRetentionCleanupCoordinator.Cleanup = { conversationID, epoch in
      await probe.recordCleanup(conversationID: conversationID, epoch: epoch)
    }
    let wait: MLSEpochRetentionCleanupCoordinator.Wait = { _ in
      try await Task.sleep(for: .seconds(3_600))
    }

    await coordinator.restart(interval: .seconds(60), scan: scan, cleanup: cleanup, wait: wait)
    await probe.waitForCleanupCount(2)
    await coordinator.restart(interval: .seconds(60), scan: scan, cleanup: cleanup, wait: wait)
    await probe.waitForCleanupCount(4)

    let running = await coordinator.status()
    #expect(running.activeWorkerCount == 1)
    #expect(running.startedWorkerCount == 2)
    #expect(running.cancelledWorkerCount == 1)
    #expect(await probe.cleanups == ["one:3", "two:7", "one:3", "two:7"])

    await coordinator.stop()
    let stopped = await coordinator.status()
    #expect(stopped.activeWorkerCount == 0)
    #expect(stopped.cancelledWorkerCount == 2)
  }

  @Test("Account switch and logout use the retention-stopping MLS teardown")
  func retentionStopsForSwitchAndLogout() throws {
    let appState = try coreStateSource(named: "AppState.swift")
    let resetBody = try sourceSlice(
      appState,
      from: "func prepareMLSStorageReset() async {",
      through: "func stopMLSStreams()"
    )
    #expect(resetBody.contains("await mlsEpochRetentionCleanupCoordinator.stop()"))

    let manager = try coreStateSource(named: "AppStateManager.swift")
    let transitionBody = try sourceSlice(
      manager,
      from: "func transitionToAuthenticated(userDID: String, previousUserDID: String? = nil)",
      through: "func logout(isManual: Bool = true) async"
    )
    #expect(transitionBody.contains("await previousAppState.prepareMLSStorageReset()"))

    let switchBody = try sourceSlice(
      manager,
      from: "private func performSwitchAccount(",
      through: "func removeAccount("
    )
    #expect(
      switchBody.contains(
        "transitionToAuthenticated(userDID: userDID, previousUserDID: previousUserDID)"
      )
    )

    let logoutBody = try sourceSlice(
      manager,
      from: "func logout(isManual: Bool = true) async {",
      through: "// MARK: - Account Management"
    )
    #expect(logoutBody.contains("await currentState.prepareMLSStorageReset()"))
    let shutdownRange = try #require(
      logoutBody.range(of: "await currentState.prepareMLSStorageReset()")
    )
    let authRange = try #require(
      logoutBody.range(of: "await authManager.logout(isManual: isManual)")
    )
    #expect(shutdownRange.lowerBound < authRange.lowerBound)
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

  @Test("Circles is shipped and the feed entry has no private local rollout gate")
  func circlesEntryIsAlwaysDiscoverable() throws {
    let flags = try repositorySource(
      components: ["Catbird", "Core", "Settings", "CircleFeatureFlags.swift"]
    )
    let feeds = try repositorySource(
      components: ["Catbird", "Features", "Feed", "Views", "FeedsStartPage.swift"]
    )
    #expect(!flags.contains("feature.circles.enabled"))
    #expect(!flags.contains("localFlag"))
    #expect(!feeds.contains("if CircleFeatureFlags.localFlag"))
  }

  @Test("Circle capability check goes directly to the public standalone AppView")
  func circleCapabilityCheckBypassesGatewayAndPDSProxy() throws {
    let service = try repositorySource(
      components: [
        "Catbird", "Features", "Circles", "Services", "CircleService.swift",
      ]
    )
    let capabilityBody = try sourceSlice(
      service,
      from: "func capabilities() async throws -> CircleCapability {",
      through: "func listCircles(cursor:"
    )
    #expect(capabilityBody.contains("CircleConfiguration.appViewBaseURL"))
    #expect(!capabilityBody.contains("client.blue.catbird.circle.getCapabilities"))
  }

  @Test("Opening Circles automatically starts separate AppView authorization when required")
  func circlesFirstOpenStartsAppViewAuthorization() throws {
    let view = try repositorySource(
      components: [
        "Catbird", "Features", "Circles", "Views", "CirclesFeedView.swift",
      ]
    )
    #expect(view.contains("await authorizeCircles(model: newModel)"))
    #expect(view.contains("guard newModel.accessState == .needsAuthorization"))
  }

  @Test("AuthManager purges the Circle cache on logout, switch, and removal")
  func authManagerPurgesCircleCache() throws {
    let manager = try coreStateSource(named: "AuthManager.swift")

    let logoutBody = try sourceSlice(
      manager,
      from: "func logout(isManual: Bool = false) async {",
      through: "// Note: AppStateManager calls this method"
    )
    #expect(logoutBody.contains("CircleFeedCache.shared.purge(accountDID:"))

    let switchBody = try sourceSlice(
      manager,
      from: "func switchToAccount(did: String) async throws {",
      through: "/// Add a new account"
    )
    #expect(switchBody.contains("CircleFeedCache.shared.purge(accountDID:"))

    let removeBody = try sourceSlice(
      manager,
      from: "func removeAccount(did: String) async {",
      through: "/// Get list of all available accounts"
    )
    #expect(removeBody.contains("CircleFeedCache.shared.purge(accountDID:"))
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
    
    #expect(source.contains("deactivateConfirmText == \"DEACTIVATE\""))
    #expect(source.contains("ensurePermission(.accountStatusManage)"))
    #expect(source.contains("client.com.atproto.server.deactivateAccount("))
    #expect(source.contains("input: .init(deleteAfter: nil)"))
    #expect(source.contains("(200...299).contains(responseCode)"))
    #expect(source.contains("handleLogout()"))
    // Verify dormant delete account UI/methods are removed
    #expect(!source.contains("deleteAccount("))
    #expect(!source.contains("Delete Account"))
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
    
    #expect(appearanceSource.contains("AppIconSettingsView()"))
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

private enum SettingsRuntimeSourceError: Error {
  case missingBoundary
}

private actor RetentionCoordinatorProbe {
  private(set) var cleanups: [String] = []
  private var scanCount = 0

  func recordScan() { scanCount += 1 }

  func recordCleanup(conversationID: String, epoch: Int64) {
    cleanups.append("\(conversationID):\(epoch)")
  }

  func waitForCleanupCount(_ count: Int) async {
    while cleanups.count < count {
      await Task.yield()
    }
  }
}
