import Foundation
import Petrel
import Testing
@testable import Catbird

/// Records every call and answers from canned pages.
private actor FakeCircleErasureTransport: CircleAccountErasureTransport {
  var granted: Set<String>?
  var grantError: Error?
  var pages: [String: [(spaces: [SpaceRef], cursor: String?)]]
  var listError: Error?
  var failingSpaces: Set<String> = []
  private(set) var calls: [String] = []

  init(
    granted: Set<String>? = nil,
    grantError: Error? = nil,
    pages: [String: [(spaces: [SpaceRef], cursor: String?)]] = [:],
    listError: Error? = nil,
    failingSpaces: Set<String> = []
  ) {
    self.granted = granted
    self.grantError = grantError
    self.pages = pages
    self.listError = listError
    self.failingSpaces = failingSpaces
  }

  func grantedSpaceTypes() async throws -> Set<String>? {
    if let grantError { throw grantError }
    return granted
  }

  func listSpaces(spaceType: String, cursor: String?) async throws -> (spaces: [SpaceRef], cursor: String?) {
    calls.append("list \(spaceType) \(cursor ?? "-")")
    if let listError { throw listError }
    let typePages = pages[spaceType] ?? []
    let index = cursor.flatMap(Int.init) ?? 0
    return index < typePages.count ? typePages[index] : ([], nil)
  }

  func deleteSpace(_ space: SpaceRef) async throws {
    calls.append("delete \(space.uriString())")
    if failingSpaces.contains(space.uriString()) { throw CircleError.invalidResponse }
  }

  func clearRecords(space: SpaceRef, repo: String) async throws {
    calls.append("clear \(space.uriString()) \(repo)")
    if failingSpaces.contains(space.uriString()) { throw CircleError.invalidResponse }
  }
}

@Suite("Circles erasure on account deletion")
struct CircleAccountErasureTests {
  static let me = "did:plc:deletingaccountabcdefghij"
  static let owned = try! SpaceRef(uriString: "at:space/\(me)/blue.catbird.circle/3owned")
  static let ownedEncrypted = try! SpaceRef(uriString: "at:space/\(me)/blue.catbird.circle.encrypted/3ownedenc")
  static let joined = try! SpaceRef(uriString: "at:space/did:plc:friend/blue.catbird.circle/3joined")
  static let joinedEncrypted = try! SpaceRef(uriString: "at:space/did:plc:friend/blue.catbird.circle.encrypted/3joinedenc")

  @Test("Owned Circles are deleted and joined Circles cleared of the account's records")
  func ownedDeletedJoinedCleared() async {
    let transport = FakeCircleErasureTransport(pages: [
      CircleConfiguration.spaceType: [([Self.owned, Self.joined], nil)],
      CircleConfiguration.encryptedSpaceType: [([Self.ownedEncrypted, Self.joinedEncrypted], nil)],
    ])

    let report = await CircleAccountErasure.run(accountDID: Self.me, transport: transport)

    #expect(report.deletedSpaces == [Self.owned.uriString(), Self.ownedEncrypted.uriString()])
    #expect(report.clearedSpaces == [Self.joined.uriString(), Self.joinedEncrypted.uriString()])
    #expect(report.failures.isEmpty)
    let calls = await transport.calls
    #expect(calls.contains("clear \(Self.joined.uriString()) \(Self.me)"))
    #expect(!calls.contains("delete \(Self.joined.uriString())"), "never deletes someone else's Circle")
  }

  @Test("Every page of spaces is visited")
  func followsCursor() async {
    let transport = FakeCircleErasureTransport(granted: [CircleConfiguration.spaceType], pages: [
      CircleConfiguration.spaceType: [([Self.owned], "1"), ([Self.joined], nil)],
    ])

    let report = await CircleAccountErasure.run(accountDID: Self.me, transport: transport)

    #expect(report.deletedSpaces == [Self.owned.uriString()])
    #expect(report.clearedSpaces == [Self.joined.uriString()])
    #expect(report.skippedSpaceTypes == [CircleConfiguration.encryptedSpaceType])
    let calls = await transport.calls
    #expect(calls.filter { $0.hasPrefix("list") } == ["list \(CircleConfiguration.spaceType) -", "list \(CircleConfiguration.spaceType) 1"])
  }

  @Test("A space type without a granted scope is skipped, an unknown grant is tried")
  func scopeGating() async {
    let none = FakeCircleErasureTransport(granted: [])
    let skipped = await CircleAccountErasure.run(accountDID: Self.me, transport: none)
    #expect(skipped.skippedSpaceTypes == CircleAccountErasure.spaceTypes)
    let noneCalls = await none.calls
    #expect(noneCalls.isEmpty)

    let unknown = FakeCircleErasureTransport(grantError: CircleError.invalidResponse)
    let tried = await CircleAccountErasure.run(accountDID: Self.me, transport: unknown)
    #expect(tried.skippedSpaceTypes.isEmpty)
    let unknownCalls = await unknown.calls
    #expect(unknownCalls.count == 2)
  }

  @Test("A PDS without Spaces has nothing to remove")
  func unsupportedPDS() async {
    let transport = FakeCircleErasureTransport(
      listError: ATProtoXRPCError(error: "MethodNotImplemented", statusCode: 501)
    )
    let report = await CircleAccountErasure.run(accountDID: Self.me, transport: transport)
    #expect(report.unsupported)
    #expect(report.failures.isEmpty)
    let calls = await transport.calls
    #expect(calls.count == 1, "stops after the first listSpaces")
  }

  @Test("One failing space does not stop the rest")
  func failuresAreCollected() async {
    let transport = FakeCircleErasureTransport(
      pages: [CircleConfiguration.spaceType: [([Self.owned, Self.joined], nil)]],
      failingSpaces: [Self.owned.uriString()]
    )
    let report = await CircleAccountErasure.run(accountDID: Self.me, transport: transport)
    #expect(report.failures == [Self.owned.uriString()])
    #expect(report.clearedSpaces == [Self.joined.uriString()])
  }

  @Test("Granted scopes map to space types by their resource part")
  func scopeParsing() {
    let types = CircleAccountErasure.grantedSpaceTypes(fromScopes: [
      "atproto",
      GatewayPermission.circleSpaces.rawValue,
      "space:blue.catbird.circle.other?action=create",
    ])
    #expect(types == [CircleConfiguration.spaceType])
    #expect(CircleAccountErasure.grantedSpaceTypes(fromScopes: [
      GatewayPermission.circleEncryptedSpaces.rawValue,
    ]) == [CircleConfiguration.encryptedSpaceType])
  }
}

@Suite("Hosted account deletion clears Circles")
@MainActor
struct HostedAccountDeletionCirclesTests {
  @Test("Circles are cleared after authentication and before the account is deleted")
  func circlesClearedBeforeDeletion() async throws {
    var events: [String] = []
    try await HostedAccountDeletionSequence.run(
      password: "password",
      confirmationToken: "email-code",
      remoteErasureConsent: .explicitlyConfirmed,
      authenticateHostedAccount: {
        events.append("authenticate")
        return "jwt"
      },
      eraseCircles: {
        events.append("erase-circles")
      },
      eraseRemoteEncryptedData: {
        events.append("erase-remote")
      },
      deleteHostedAccount: { (_: String, _: String) in
        events.append("delete-account")
      },
      eraseRemainingLocalData: {
        events.append("erase-local")
      }
    )
    #expect(events == ["authenticate", "erase-circles", "erase-remote", "delete-account", "erase-local"])
  }

  @Test("Failed authentication never touches Circles")
  func authenticationFailureSkipsCircles() async {
    var events: [String] = []
    do {
      try await HostedAccountDeletionSequence.run(
        password: "password",
        confirmationToken: "email-code",
        remoteErasureConsent: .explicitlyConfirmed,
        authenticateHostedAccount: { () async throws -> String in
          throw PDSDirectDeletionError.missingPassword
        },
        eraseCircles: {
          events.append("erase-circles")
        },
        eraseRemoteEncryptedData: {},
        deleteHostedAccount: { (_: String, _: String) in },
        eraseRemainingLocalData: {}
      )
      Issue.record("Expected authentication to fail")
    } catch {}
    #expect(events.isEmpty)
  }

  @Test("The coordinator hands the live account's Circles to the eraser")
  func coordinatorUsesTransportOverride() async {
    let transport = FakeCircleErasureTransport(pages: [
      CircleConfiguration.spaceType: [([CircleAccountErasureTests.owned], nil)],
    ])
    let report = await AccountDeletionCoordinator.eraseCirclesIfAuthenticated(
      forDID: CircleAccountErasureTests.me,
      transportOverride: transport
    )
    #expect(report?.deletedSpaces == [CircleAccountErasureTests.owned.uriString()])
  }
}
