import Foundation
import Testing

@testable import Catbird

@Suite("Catbird gateway configuration")
struct CatbirdGatewayConfigurationTests {
  @Test("production is the immutable default")
  func productionDefault() throws {
    let configuration = try CatbirdGatewayConfiguration.resolve(arguments: [])

    #expect(configuration.origin == URL(string: "https://api.catbird.blue")!)
    #expect(configuration.serviceDID == "did:web:api.catbird.blue")
    #expect(configuration.mlsServiceDID == nil)

    let e2eWithoutOverride = try CatbirdGatewayConfiguration.resolve(arguments: [
      "Catbird", "--e2e-mode",
    ])
    #expect(e2eWithoutOverride == configuration)
  }

  @Test("the exact dev-api origin is available only in E2E mode")
  func exactStagingOverride() throws {
    let configuration = try CatbirdGatewayConfiguration.resolve(arguments: [
      "Catbird",
      "--e2e-mode",
      "--catbird-gateway-origin=https://dev-api.catbird.blue",
    ])

    #expect(configuration.origin == URL(string: "https://dev-api.catbird.blue")!)
    #expect(configuration.serviceDID == "did:web:dev-api.catbird.blue")
    #expect(configuration.mlsServiceDID == "did:web:dev-api.catbird.blue:mls")
  }

  @Test("a staging override without E2E mode fails closed")
  func stagingRequiresE2EMode() {
    #expect(throws: CatbirdGatewayConfigurationError.e2eModeRequired) {
      try CatbirdGatewayConfiguration.resolve(arguments: [
        "Catbird",
        "--catbird-gateway-origin=https://dev-api.catbird.blue",
      ])
    }
  }

  @Test(
    "unapproved and non-canonical gateway origins fail closed",
    arguments: [
      "https://evil.example",
      "http://dev-api.catbird.blue",
      "https://user@dev-api.catbird.blue",
      "https://user:password@dev-api.catbird.blue",
      "https://dev-api.catbird.blue#fragment",
      "https://dev-api.catbird.blue:443",
      "https://dev-api.catbird.blue:444",
      "https://dev-api.catbird.blue.evil.example",
      "https://dev-api.catbird.blue/",
      "https://dev-api.catbird.blue?query=value",
      "https://DEV-API.catbird.blue",
      "https://dev-api.catbird.blue%2eevil.example",
    ]
  )
  func rejectsOriginTricks(origin: String) {
    #expect(throws: CatbirdGatewayConfigurationError.invalidOverride) {
      try CatbirdGatewayConfiguration.resolve(arguments: [
        "Catbird",
        "--e2e-mode",
        "--catbird-gateway-origin=\(origin)",
      ])
    }
  }

  @Test("duplicate selectors fail closed")
  func duplicateSelectors() {
    #expect(throws: CatbirdGatewayConfigurationError.invalidOverride) {
      try CatbirdGatewayConfiguration.resolve(arguments: [
        "Catbird",
        "--e2e-mode",
        "--catbird-gateway-origin=https://dev-api.catbird.blue",
        "--catbird-gateway-origin=https://dev-api.catbird.blue",
      ])
    }
  }

  @Test("malformed selector syntax fails closed")
  func malformedSelectorSyntax() {
    for argument in [
      "--catbird-gateway-origin",
      "--catbird-gateway-origin:https://dev-api.catbird.blue",
      "--catbird-gateway-origin-extra=https://dev-api.catbird.blue",
    ] {
      #expect(throws: CatbirdGatewayConfigurationError.invalidOverride) {
        try CatbirdGatewayConfiguration.resolve(arguments: [
          "Catbird", "--e2e-mode", argument,
        ])
      }
    }
  }

  @Test("foreground gateway and MLS call sites use the centralized decision")
  func foregroundWiring() throws {
    let repositoryURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let expectedFragments = [
      "Catbird/Core/State/AuthManager.swift":
        "static let gatewayURL = CatbirdGatewayConfiguration.current.origin",
      "Catbird/Features/Chat/Services/ChatManager.swift":
        "CatbirdGatewayConfiguration.current.serviceDID",
      "Catbird/Features/Chat/Services/ChatHeartbeatManager.swift":
        "CatbirdGatewayConfiguration.current.serviceDID",
      "Catbird/Features/Notifications/Services/NotificationManager.swift":
        "gatewayURL: CatbirdGatewayConfiguration.current.origin",
      "Catbird/AppIntents/Support/IntentClientProvider.swift":
        "gatewayURL: CatbirdGatewayConfiguration.current.origin",
      "Catbird/Core/State/AppState.swift":
        "CatbirdGatewayConfiguration.current.mlsServiceDID",
    ]

    for (path, fragment) in expectedFragments {
      let source = try String(
        contentsOf: repositoryURL.appendingPathComponent(path),
        encoding: .utf8
      )
      #expect(source.contains(fragment), "Missing centralized routing in \(path)")
    }

    let appState = try String(
      contentsOf: repositoryURL.appendingPathComponent("Catbird/Core/State/AppState.swift"),
      encoding: .utf8
    )
    #expect(appState.contains(".custom(serviceDID: mlsServiceDID)"))
    #expect(appState.contains("environment: environment"))
    #expect(appState.contains("return await MLSAPIClient("))

    let notificationManager = try String(
      contentsOf: repositoryURL.appendingPathComponent(
        "Catbird/Features/Notifications/Services/NotificationManager.swift"
      ),
      encoding: .utf8
    )
    let inactiveAccountStart = try #require(
      notificationManager.range(of: "private func getOrCreateAPIClient(for userDid: String)")
    )
    let inactiveAccountEnd = try #require(
      notificationManager.range(
        of: "private func checkGroupExists",
        range: inactiveAccountStart.upperBound..<notificationManager.endIndex
      )
    )
    let inactiveAccountSource = notificationManager[
      inactiveAccountStart.lowerBound..<inactiveAccountEnd.lowerBound
    ]
    #expect(inactiveAccountSource.contains("CatbirdGatewayConfiguration.current.mlsServiceDID"))
    #expect(inactiveAccountSource.contains(".custom(serviceDID: mlsServiceDID)"))
    #expect(!inactiveAccountSource.contains("environment: .production"))
  }
}
