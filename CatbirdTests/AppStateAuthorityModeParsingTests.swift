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

  private func sourceFileURL(relativePath: String) -> URL {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let projectRoot = testsDirectory.deletingLastPathComponent()
    return projectRoot.appendingPathComponent(relativePath)
  }
}
