import Foundation
import PetrelCatbird
import Testing
@testable import Catbird

@Suite("MLS conversation identity boundary")
struct MLSConversationIdentityBoundaryTests {
  private let canonicalID = "550e8400-e29b-41d4-a716-446655440000"
  private let groupID = "00112233445566778899aabbccddeeff"

  @Test("only lowercase RFC 4122 UUIDv4 stable IDs are accepted")
  func strictStableIDValidation() {
    #expect(MLSConversationIdentityBoundary.isCanonicalStableID(canonicalID))
    #expect(MLSConversationIdentityBoundary.stableID(canonicalID)?.rawValue == canonicalID)
    #expect(MLSConversationIdentityBoundary.stableID(canonicalID.uppercased()) == nil)
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID(canonicalID.uppercased()))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400-e29b-11d4-a716-446655440000"))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400e29b41d4a716446655440000"))
    #expect(!MLSConversationIdentityBoundary.isCanonicalStableID("550e8400-e29b-41d4-c716-446655440000"))
  }

  @Test("an exact raw alias resolves only to its canonical row")
  func exactAliasResolvesCanonical() throws {
    let records = [
      MLSConversationIdentityBoundary.Record(conversationID: groupID, groupID: groupID),
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID, groupID: groupID)
    ]

    #expect(try MLSConversationIdentityBoundary.resolve(groupID, in: records) == canonicalID)
    #expect(try MLSConversationIdentityBoundary.canonicalize(records).map(\.conversationID) == [canonicalID])
  }

  @Test("raw-only, unrelated stable, noncanonical, and ambiguous identities fail closed")
  func rejectionCases() {
    let rawOnly = [MLSConversationIdentityBoundary.Record(conversationID: groupID, groupID: groupID)]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve(groupID, in: rawOnly)
    }

    let unrelated = [
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID, groupID: "ffeeddccbbaa99887766554433221100")
    ]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.resolve(groupID, in: unrelated)
    }

    let noncanonical = [
      MLSConversationIdentityBoundary.Record(conversationID: "550E8400-e29b-41d4-a716-446655440000", groupID: groupID)
    ]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.canonicalize(noncanonical)
    }

    let ambiguous = [
      MLSConversationIdentityBoundary.Record(conversationID: canonicalID, groupID: groupID),
      MLSConversationIdentityBoundary.Record(conversationID: "6ba7b810-9dad-41d1-80b4-00c04fd430c8", groupID: groupID)
    ]
    #expect(throws: MLSConversationIdentityError.self) {
      try MLSConversationIdentityBoundary.canonicalize(ambiguous)
    }
  }
}
