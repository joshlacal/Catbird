import Foundation
import SwiftUI
import Testing
@testable import Catbird

@Suite("Recovered settings runtime wiring")
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
    let switchBody = try sourceSlice(
      manager,
      from: "private func performSwitchAccount(",
      through: "func removeAccount("
    )
    #expect(switchBody.contains("await oldState.prepareMLSStorageReset()"))

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
