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
}
