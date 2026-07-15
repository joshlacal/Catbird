import Foundation

enum CatbirdGatewayConfigurationError: Error, Equatable {
  case e2eModeRequired
  case invalidOverride
}

/// The single routing decision for foreground Catbird traffic that terminates at Nest or MLS.
///
/// Production is immutable. The staging deployment can be selected only by the exact launch
/// argument emitted by the E2E harness while `--e2e-mode` is also present.
struct CatbirdGatewayConfiguration: Sendable, Equatable {
  private enum Deployment: Sendable, Equatable {
    case production
    case stagingE2E
  }

  private static let overrideArgument = "--catbird-gateway-origin"
  private static let overridePrefix = "\(overrideArgument)="
  private static let e2eModeArgument = "--e2e-mode"

  private static let productionOrigin = URL(string: "https://api.catbird.blue")!
  private static let stagingOrigin = URL(string: "https://dev-api.catbird.blue")!

  private let deployment: Deployment

  static let current: Self = {
    do {
      return try resolve(arguments: ProcessInfo.processInfo.arguments)
    } catch {
      preconditionFailure("Invalid Catbird E2E gateway configuration")
    }
  }()

  var origin: URL {
    switch deployment {
    case .production:
      Self.productionOrigin
    case .stagingE2E:
      Self.stagingOrigin
    }
  }

  /// Nest's service DID, used for gateway-owned foreground XRPC endpoints.
  var serviceDID: String {
    switch deployment {
    case .production:
      "did:web:api.catbird.blue"
    case .stagingE2E:
      "did:web:dev-api.catbird.blue"
    }
  }

  /// MLS uses a distinct DID from Nest and must never inherit the Nest service DID.
  var mlsServiceDID: String? {
    switch deployment {
    case .production:
      nil
    case .stagingE2E:
      "did:web:dev-api.catbird.blue:mls#atproto_mls"
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
