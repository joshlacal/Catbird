import XCTest
import CatbirdMLSCore

@testable import Catbird

final class AppStateAuthorityModeParsingTests: XCTestCase {
  func testConfiguredMLSProtocolAuthorityModeAcceptsFullRustAliasFromEnvironment() {
    let mode = AppState.configuredMLSProtocolAuthorityMode(
      environment: ["CATBIRD_MLS_AUTHORITY_MODE": "fullRust"],
      arguments: []
    )

    XCTAssertEqual(mode, .rustFull)
  }

  func testConfiguredMLSProtocolAuthorityModeAcceptsFullRustAliasFromInlineArgument() {
    let mode = AppState.configuredMLSProtocolAuthorityMode(
      environment: [:],
      arguments: ["Catbird", "--mls-authority-mode=fullRust"]
    )

    XCTAssertEqual(mode, .rustFull)
  }

  func testConfiguredMLSProtocolAuthorityModeAcceptsFullRustAliasFromSplitArgument() {
    let mode = AppState.configuredMLSProtocolAuthorityMode(
      environment: [:],
      arguments: ["Catbird", "--mls-authority-mode", "fullRust"]
    )

    XCTAssertEqual(mode, .rustFull)
  }

  func testAppStateRoutesKeyPackageReconciliationThroughConversationManager() throws {
    let source = try String(
      contentsOf: sourceFileURL(relativePath: "Catbird/Core/State/AppState.swift"),
      encoding: .utf8
    )

    XCTAssertFalse(source.contains("MLSClient.shared.getKeyPackageBundleCount"))
    XCTAssertFalse(source.contains("MLSClient.shared.reconcileKeyPackagesWithServer"))
    XCTAssertTrue(source.contains("manager.smartRefreshKeyPackages"))
  }

  func testNotificationDeviceTokenRegistrationUsesManagerDeviceInfo() throws {
    let source = try String(
      contentsOf: sourceFileURL(
        relativePath: "Catbird/Features/Notifications/Services/NotificationManager.swift"
      ),
      encoding: .utf8
    )
    let body = try XCTUnwrap(
      extractFunctionBody(signature: "private func registerMLSDeviceToken(_ token: Data) async", from: source)
    )

    XCTAssertTrue(body.contains("conversationManager.registeredDeviceInfoForPushTokenRegistration()"))
    XCTAssertTrue(body.contains("deviceInfo.deviceUUID ?? deviceInfo.deviceId"))
    XCTAssertFalse(body.contains("MLSClient.shared.ensureDeviceRegistered"))
    XCTAssertFalse(body.contains("MLSClient.shared.getDeviceInfo"))
  }

  func testE2ERegisterDeviceRoutesRustFullThroughManager() throws {
    let source = try String(
      contentsOf: sourceFileURL(relativePath: "Catbird/App/CatbirdApp.swift"),
      encoding: .utf8
    )
    let body = try XCTUnwrap(
      extractFunctionBody(signature: "private func handleRegisterDevice(", from: source)
    )
    let rustFullBranch = try XCTUnwrap(
      extractConditionalBranchBody(matching: "if conversationManager.protocolAuthorityMode == .rustFull", from: body)
    )

    XCTAssertTrue(rustFullBranch.contains("registeredDeviceInfoForPushTokenRegistration()"))
    XCTAssertTrue(rustFullBranch.contains("smartRefreshKeyPackages()"))
    XCTAssertFalse(rustFullBranch.contains("mlsClient.reregisterDevice"))
    XCTAssertLessThan(
      try XCTUnwrap(body.range(of: "conversationManager.protocolAuthorityMode == .rustFull")).lowerBound,
      try XCTUnwrap(body.range(of: "mlsClient.reregisterDevice")).lowerBound
    )
  }

  func testE2EKeyPackageCommandsAvoidSwiftDeviceLookupAndDrainInRustFull() throws {
    let source = try String(
      contentsOf: sourceFileURL(relativePath: "Catbird/App/CatbirdApp.swift"),
      encoding: .utf8
    )

    let refreshBody = try XCTUnwrap(
      extractFunctionBody(signature: "private func handleRefreshKeyPackages(", from: source)
    )
    let refreshRustFullBranch = try XCTUnwrap(
      extractConditionalBranchBody(matching: "if conversationManager.protocolAuthorityMode == .rustFull", from: refreshBody)
    )
    XCTAssertTrue(refreshRustFullBranch.contains("registeredDeviceInfoForPushTokenRegistration()"))
    XCTAssertFalse(refreshRustFullBranch.contains("mlsClient.getDeviceInfo"))

    let drainBody = try XCTUnwrap(
      extractFunctionBody(signature: "private func handleDrainKeyPackages(", from: source)
    )
    let drainRustFullBranch = try XCTUnwrap(
      extractConditionalBranchBody(matching: "if conversationManager.protocolAuthorityMode == .rustFull", from: drainBody)
    )
    XCTAssertTrue(drainRustFullBranch.contains("drain-key-packages is unsupported in rustFull authority"))
    XCTAssertFalse(drainRustFullBranch.contains("mlsClient.deleteKeyPackageBundles"))
    XCTAssertLessThan(
      try XCTUnwrap(drainBody.range(of: "conversationManager.protocolAuthorityMode == .rustFull")).lowerBound,
      try XCTUnwrap(drainBody.range(of: "mlsClient.deleteKeyPackageBundles")).lowerBound
    )

    let stateBody = try XCTUnwrap(
      extractFunctionBody(signature: "private func handleKeyPackageState(", from: source)
    )
    let stateRustFullBranch = try XCTUnwrap(
      extractConditionalBranchBody(matching: "if conversationManager.protocolAuthorityMode == .rustFull", from: stateBody)
    )
    XCTAssertTrue(stateRustFullBranch.contains("registeredDeviceInfoForPushTokenRegistration()"))
    XCTAssertFalse(stateRustFullBranch.contains("mlsClient.getDeviceInfo"))
  }

  private func sourceFileURL(relativePath: String) -> URL {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let projectRoot = testsDirectory.deletingLastPathComponent()
    return projectRoot.appendingPathComponent(relativePath)
  }

  private func extractFunctionBody(signature: String, from source: String) -> String? {
    guard let signatureRange = source.range(of: signature),
          let bodyStart = source[signatureRange.upperBound...].firstIndex(of: "{")
    else {
      return nil
    }

    var depth = 0
    var currentIndex = bodyStart
    while currentIndex < source.endIndex {
      let character = source[currentIndex]
      if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[bodyStart...currentIndex])
        }
      }
      currentIndex = source.index(after: currentIndex)
    }

    return nil
  }

  private func extractConditionalBranchBody(
    matching prefix: String,
    from functionBody: String
  ) -> String? {
    guard let conditionalRange = functionBody.range(of: prefix),
          let bodyStart = functionBody[conditionalRange.upperBound...].firstIndex(of: "{")
    else {
      return nil
    }

    return extractBraceBody(startingAt: bodyStart, in: functionBody)
  }

  private func extractBraceBody(
    startingAt bodyStart: String.Index,
    in source: String
  ) -> String? {
    var depth = 0
    var currentIndex = bodyStart
    while currentIndex < source.endIndex {
      let character = source[currentIndex]
      if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 {
          return String(source[bodyStart...currentIndex])
        }
      }
      currentIndex = source.index(after: currentIndex)
    }

    return nil
  }
}
