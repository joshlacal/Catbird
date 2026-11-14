import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("Circle configuration")
struct CircleConfigurationTests {
  @Test func encryptedSummaryIsDetected() throws {
    let encryptedURI = try SpaceRef(
      uriString: "at://did:plc:alice/space/\(CircleConfiguration.encryptedSpaceType)/3enc")
    let encrypted = BlueCatbirdCircleDefs.CircleSummary(
      uri: encryptedURI,
      circleId: CircleTestFixtures.familyCircleId,
      name: "Sealed",
      owner: CircleTestFixtures.alice
    )
    #expect(encrypted.isEncrypted)
    #expect(!CircleTestFixtures.family.isEncrypted)
    #expect(CircleConfiguration.encryptedSpaceType == "blue.catbird.circle.encrypted")
    #expect(CircleConfiguration.keyCollection == "blue.catbird.circle.key")
    #expect(CircleConfiguration.postCollection == "blue.catbird.circle.post")
    #expect(CircleConfiguration.maxRewrapVersions == 24)
    #expect(CircleConfiguration.maxRewrapAge == 365 * 24 * 3600)
    #expect(CircleConfiguration.staleKeyGrace == 600)
    let capability = CircleCapability(
      enabled: true, protocolRevision: CircleConfiguration.protocolRevision,
      supportsImages: true, supportsEncryptedPosts: true)
    #expect(capability.supportsEncryptedPosts)
  }

  @Test func scopeListContainsEncryptedType() {
    let scopes = GatewayPermission.allCases.map(\.scopeString)
    #expect(scopes.contains { $0.hasPrefix("space:\(CircleConfiguration.spaceType)?") })
    #expect(scopes.contains { $0.hasPrefix("space:\(CircleConfiguration.encryptedSpaceType)?") })
    #expect(GatewayPermission.circleEncryptedSpaces.scopeString
      == GatewayPermission.circleSpaces.scopeString
        .replacingOccurrences(of: "space:blue.catbird.circle?", with: "space:blue.catbird.circle.encrypted?"))
  }
}
