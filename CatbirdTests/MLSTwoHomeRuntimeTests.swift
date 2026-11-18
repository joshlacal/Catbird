#if DEBUG && os(iOS) && targetEnvironment(simulator)
import CatbirdMLS
import CatbirdMLSCore
import Foundation
@_spi(Fixtures) import Petrel
import SwiftUI
import UIKit
import XCTest
@testable import Catbird

/// Drives the installed app's signed-in chat stack against the two local delivery services.
/// The runner places synthetic credentials and a fresh command in this simulator's Documents
/// directory. Every method uses the real transport, Keychain and per-account encrypted store.
final class MLSTwoHomeRuntimeTests: XCTestCase {
  private struct LocalAgeRequirement: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }

  private struct LocalSession: Decodable {
    let label: String
    let did: String
    let session: String
    let pdsEndpoint: URL
    let deliveryService: String
  }
  private struct Sessions: Decodable { let accounts: [LocalSession] }
  private struct Command: Decodable {
    let nonce: UUID
    let phase: String
    let conversation: String
    let message: String
    let text: String
    let enabled: Bool
    let excludedMessage: String?
  }

  @MainActor
  func testSignedInPhase() async throws {
    let directory = URL.documentsDirectory.appending(path: "MLSTwoHome", directoryHint: .isDirectory)
    let input = directory.appending(path: "command.json")
    try XCTSkipUnless(FileManager.default.fileExists(atPath: input.path), "Requires the isolated two-home simulator fixture")
    let command = try JSONDecoder().decode(Command.self, from: Data(contentsOf: input))
    let fixture = try await DebugFixtureTransport.install(
      manifest: Data(contentsOf: directory.appending(path: "manifest.json")),
      certificateDER: Data(contentsOf: directory.appending(path: "ca.der")),
      hostPolicy: .init(fixtureDomain: "request-fixture.catbird.blue", additionalHosts: [], serviceLabels: ["ds1", "ds2"])
    )
    let sessions = try JSONDecoder().decode(Sessions.self, from: Data(contentsOf: directory.appending(path: "sessions.json")))
    let account = try XCTUnwrap(sessions.accounts.first { $0.label == "alice" })
    let peer = try XCTUnwrap(fixture.accounts.first { $0.label == "bob" })
    let identity = try XCTUnwrap(fixture.accounts.first { $0.label == "alice" })
    guard identity.did == account.did, fixture.permits(account.pdsEndpoint),
          account.did == "did:web:" + (account.pdsEndpoint.host ?? ""),
          CatbirdGatewayConfiguration.current.mlsServiceDID(for: account.did) == account.deliveryService + "#atproto_mls"
    else { throw URLError(.unsupportedURL) }

    let sessionClient = try await ATProtoClient(
      baseURL: fixture.origin,
      oauthConfig: OAuthConfig(
        clientId: fixture.origin.appending(path: "client-metadata.json").absoluteString,
        redirectUri: fixture.origin.appending(path: "callback").absoluteString, scope: "atproto"
      ),
      namespace: "blue.catbird.fixture." + identity.deviceId,
      authMode: .gateway(try CatbirdGatewayConfiguration.petrelGateway(origin: fixture.origin))
    )
    try await sessionClient.adoptFixtureGatewaySession(account.session)
    let current = await sessionClient.getCurrentAccount()
    let pds = try await sessionClient.resolveDIDToPDSURL(did: account.did)
    guard current?.did == account.did, current?.pdsURL == fixture.origin, pds == account.pdsEndpoint else {
      throw URLError(.userAuthenticationRequired)
    }
    let state = AppState(userDID: account.did, client: sessionClient, regulatoryChecker: LocalAgeRequirement())
    defer { state.cleanup() }
    ExperimentalSettings.shared.enableMLSChat(for: account.did)
    let opened = await state.getOrOpenMLSCoordinator()
    let coordinator = try XCTUnwrap(opened)
    var result = ["nonce": command.nonce.uuidString.lowercased(), "phase": command.phase, "account": account.did]

    do {
      switch command.phase {
      case "enroll":
        let enrollment = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
        XCTAssertEqual(enrollment.accountDid, account.did)
        result["device"] = enrollment.deviceId
      case "create":
        let row = try await coordinator.createGroup(
          conversationId: command.conversation, sequencerDid: account.deliveryService, memberDids: [peer.did],
          title: "Two-home qualification", description: nil
        )
        result["conversation"] = row.conversationId
      case "send":
        let row = try await coordinator.sendMessage(conversationId: command.conversation, messageId: command.message, text: command.text)
        result["message"] = row.messageId
      case "receive":
        let source = MLSConversationDataSource(conversationId: command.conversation, currentUserDID: account.did, appState: state)
        for _ in 0..<15 {
          _ = try await coordinator.sync()
          await source.loadMessages()
          if source.messages.contains(where: { $0.id == command.message && $0.text == command.text }) { break }
          try await Task.sleep(for: .seconds(1))
        }
        let message = try XCTUnwrap(source.messages.first { $0.id == command.message && $0.text == command.text })
        XCTAssertEqual(message.senderID, peer.did)
        result["message"] = message.id
        try await captureConversation(command: command, state: state, in: directory)
      case "set-policy":
        try await coordinator.setHistoryBackupEnabled(conversationId: command.conversation, enabled: command.enabled)
        let enabled = try await coordinator.historyBackupEnabled(conversationId: command.conversation)
        XCTAssertEqual(enabled, command.enabled)
        result["backupEnabled"] = String(enabled)
      case "read-policy":
        _ = try await coordinator.sync()
        let enabled = try await coordinator.historyBackupEnabled(conversationId: command.conversation)
        XCTAssertEqual(enabled, command.enabled)
        result["backupEnabled"] = String(enabled)
      case "prepare-recovery":
        _ = try await coordinator.flushLabyrinthQueue()
        let material = try await coordinator.setupRecoveryCodeWithReceipt()
        let receipt = try state.retainGeneratedMLSRecoveryCode(material, requiresDeviceSafetyConfirmation: false)
        let latest = try await coordinator.labyrinthStatus()
        XCTAssertTrue(receipt.isCurrent(for: latest))
        XCTAssertTrue(latest.recoveryNeedsAttention)
        // A local runner transfers this protected file directly to the second, empty simulator.
        // The code must never enter XCTest diagnostics, screenshots or the phase result.
        try Data(material.code.utf8).write(to: directory.appending(path: "recovery.private"), options: [.atomic, .completeFileProtection])
        result["recoveryGeneration"] = String(material.recoveryGeneration)
      case "switch-accounts":
        let receipt = try XCTUnwrap(state.pendingMLSRecoveryCodeReceipt)
        let bob = try XCTUnwrap(sessions.accounts.first { $0.label == "bob" && $0.did == peer.did })
        guard fixture.permits(bob.pdsEndpoint) else { throw URLError(.unsupportedURL) }
        try await state.suspendForAccountSwitch()
        try await sessionClient.adoptFixtureGatewaySession(bob.session)
        let signedInPeer = await sessionClient.getCurrentAccount()
        XCTAssertEqual(signedInPeer?.did, peer.did)
        let otherState = AppState(userDID: peer.did, client: sessionClient, regulatoryChecker: LocalAgeRequirement())
        defer { otherState.cleanup() }
        XCTAssertTrue(otherState.pendingMLSRecoveryCodeReceipt == nil)
        XCTAssertTrue(otherState.pendingMLSDeviceRevocationReceipt == nil)
        try await otherState.suspendForAccountSwitch()
        try await sessionClient.switchToAccount(did: account.did)
        let current = await sessionClient.getCurrentAccount()
        XCTAssertEqual(current?.did, account.did)
        let returningState = AppState(userDID: account.did, client: sessionClient, regulatoryChecker: LocalAgeRequirement())
        defer { returningState.cleanup() }
        XCTAssertTrue(returningState.pendingMLSRecoveryCodeReceipt == receipt)
        let generation = try XCTUnwrap(receipt.recoveryGeneration)
        let returningCoordinator = await returningState.getOrOpenMLSCoordinator()
        let accountCoordinator = try XCTUnwrap(returningCoordinator)
        let acknowledged = await returningState.acknowledgePendingMLSRecoveryCodeReceipt(expected: receipt) {
          _ = try await accountCoordinator.acknowledgeRecoveryGeneration(expectedGeneration: generation)
        }
        await accountCoordinator.close()
        XCTAssertTrue(acknowledged)
        result["restoredAccount"] = account.did
      case "recover":
        let before = try await coordinator.listConversations()
        XCTAssertTrue(before.isEmpty, "Recovery must begin in an empty installation")
        let enrollment = try await coordinator.enrollDevice(grantedScopes: MLSAppGroupStorage.requiredSpacesScopes)
        let pending = try await coordinator.isDevicePendingApproval()
        XCTAssertTrue(pending, "The existing account must recognize this as a new device")
        let code = try String(contentsOf: directory.appending(path: "recovery.private"), encoding: .utf8)
        let restored = try await coordinator.restoreWithRecoveryCode(code)
        XCTAssertTrue(restored.backupEnabled)
        let imported = try await coordinator.restoreConversationFromOwnerMailbox(conversationId: command.conversation)
        let rows = try await coordinator.listMessages(conversationId: command.conversation)
        XCTAssertTrue(rows.contains { $0.messageId == command.message })
        if let excluded = command.excludedMessage {
          XCTAssertFalse(rows.contains { $0.messageId == excluded }, "A no-backup message cannot be recovered from the archive")
        }
        result["restoredMessage"] = command.message
        result["imported"] = String(imported)
        result["device"] = enrollment.deviceId
      case "erase":
        try await AccountDeletionCoordinator.eraseServerSideLabyrinthDataIfAuthenticated(
          forDID: account.did, appStateOverride: state, clientOverride: sessionClient
        )
      default:
        throw URLError(.unsupportedURL)
      }
      await coordinator.close()
    } catch {
      await coordinator.close()
      throw error
    }

    try JSONEncoder().encode(result).write(to: directory.appending(path: "result-" + command.nonce.uuidString.lowercased() + ".json"), options: .atomic)
  }

  @MainActor
  private func captureConversation(command: Command, state: AppState, in directory: URL) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let window = UIWindow(windowScene: scene)
    let controller = UIHostingController(rootView: NavigationStack {
      MLSOrdinaryConversationDetailView(conversationId: command.conversation)
    }.environment(state).environment(SceneNavigationContext(appState: state, sceneID: UUID())))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    defer { window.isHidden = true }
    try await Task.sleep(for: .seconds(2))
    controller.view.layoutIfNeeded()
    let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let data = try XCTUnwrap(screenshot.pngData())
    try data.write(to: directory.appending(path: "conversation-" + command.nonce.uuidString.lowercased() + ".png"), options: .atomic)
  }
}
#endif
