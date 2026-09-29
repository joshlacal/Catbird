import Foundation

enum CatbirdGatewayConfigurationError: Error, Equatable {
  case e2eModeRequired
  case invalidOverride
}

/// The single routing decision for foreground Catbird traffic that terminates at Nest.
///
/// Production is immutable. The staging deployment can be selected only by the exact launch
/// argument emitted by the E2E harness while `--e2e-mode` is also present. DEBUG builds given an
/// explicit runtime fixture config (`CATBIRD_RUNTIME_FIXTURE_CONFIG` or
/// `--catbird-runtime-fixture-config`) route to that local gateway only; an invalid config refuses
/// to launch rather than falling back to a real deployment.
struct CatbirdGatewayConfiguration: Sendable, Equatable {
  private enum Deployment: Sendable, Equatable {
    case production
    case stagingE2E
    #if DEBUG
    case runtimeFixture(URL)
    #endif
  }

  private static let overrideArgument = "--catbird-gateway-origin"
  private static let overridePrefix = "\(overrideArgument)="
  private static let e2eModeArgument = "--e2e-mode"

  private static let productionOrigin = URL(string: "https://api.catbird.blue")!
  private static let stagingOrigin = URL(string: "https://dev-api.catbird.blue")!

  private let deployment: Deployment

  static let current: Self = {
    #if DEBUG && canImport(Network) && canImport(Security)
    // Activation installs the fixture tunnel before any Petrel client reads this origin.
    let fixtureOrigin: URL?
    do {
      fixtureOrigin = try DebugGatewayTransport.shared.activate()
        ? DebugGatewayTransport.shared.activeManifest?.origin : nil
    } catch {
      preconditionFailure("Invalid Catbird runtime fixture configuration: \(error)")
    }
    if let fixtureOrigin {
      guard !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix(overrideArgument) }) else {
        preconditionFailure("Runtime fixture and staging gateway override are mutually exclusive")
      }
      return Self(deployment: .runtimeFixture(fixtureOrigin))
    }
    #endif
    do {
      return try resolve(arguments: ProcessInfo.processInfo.arguments)
    } catch {
      preconditionFailure("Invalid Catbird E2E gateway configuration")
    }
  }()

  var isRuntimeFixture: Bool {
    #if DEBUG
    if case .runtimeFixture = deployment { return true }
    #endif
    return false
  }

  var origin: URL {
    switch deployment {
    case .production:
      Self.productionOrigin
    case .stagingE2E:
      Self.stagingOrigin
    #if DEBUG
    case .runtimeFixture(let origin):
      origin
    #endif
    }
  }

  /// Nest's service DID, used for gateway-owned foreground XRPC endpoints.
  var serviceDID: String {
    switch deployment {
    case .production:
      "did:web:api.catbird.blue"
    case .stagingE2E:
      "did:web:dev-api.catbird.blue"
    #if DEBUG
    case .runtimeFixture(let origin):
      "did:web:\(origin.host ?? "")"
    #endif
    }
  }

  static func resolve(arguments: [String]) throws -> Self {
    let overrideArguments = arguments.filter { $0.hasPrefix(overrideArgument) }
    guard overrideArguments.count <= 1 else {
      throw CatbirdGatewayConfigurationError.invalidOverride
    }

    guard let overrideArgument = overrideArguments.first else {
      return Self(deployment: .production)
    }
    guard overrideArgument.hasPrefix(overridePrefix) else {
      throw CatbirdGatewayConfigurationError.invalidOverride
    }
    guard arguments.contains(e2eModeArgument) else {
      throw CatbirdGatewayConfigurationError.e2eModeRequired
    }

    let rawOrigin = String(overrideArgument.dropFirst(overridePrefix.count))
    guard rawOrigin == stagingOrigin.absoluteString else {
      throw CatbirdGatewayConfigurationError.invalidOverride
    }
    return Self(deployment: .stagingE2E)
  }
}
