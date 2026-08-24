import CatbirdMLSCore
import Foundation
import OSLog
import PetrelCatbird
/// The app-facing identity boundary for MLS conversations.
///
/// A conversation ID is a public routing key and is deliberately different
/// from the MLS group ID used by the crypto layer.  The only legacy mapping
/// accepted here is an exact, lower-case group-hex alias which has one and
/// only one v4 canonical conversation row in the same group.
enum MLSConversationIdentityBoundary {
  private static let logger = Logger(subsystem: "blue.catbird", category: "MLSConversationIdentityBoundary")

  /// A validated stable route.  Raw strings remain at the persistence/API
  /// edges, but callers can carry this value after the identity gate without
  /// accidentally treating a group ID as a public conversation route.
  struct StableID: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: String

    init?(rawValue: String) {
      guard MLSConversationIdentityBoundary.isCanonicalStableID(rawValue) else {
        return nil
      }
      self.rawValue = rawValue
    }
  }

  struct Record: Equatable, Hashable, Sendable {
    let conversationID: String
    let groupID: String

    init(conversationID: String, groupID: String) {
      self.conversationID = conversationID
      self.groupID = groupID
    }
  }

  enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
    case invalidStableID(String)
    case ambiguous(String)
    case rawOnly(String)
    case unresolved(String)

    var errorDescription: String? {
      switch self {
      case .invalidStableID(let id):
        return "Invalid MLS conversation identity: \(id)"
      case .ambiguous(let id):
        return "Ambiguous MLS conversation identity: \(id)"
      case .rawOnly(let id):
        return "MLS conversation has no canonical identity: \(id)"
      case .unresolved(let id):
        return "MLS conversation identity was not found: \(id)"
      }
    }
  }

  /// Exact lower-case RFC 4122 UUID text, restricted to version 4 and the
  /// RFC variant.  `UUID(uuidString:)` alone accepts uppercase and other
  /// versions, so all textual constraints are checked before it is used.
  static func isCanonicalStableID(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard scalars.count == 36,
          value == value.lowercased(),
          scalars[8] == "-",
          scalars[13] == "-",
          scalars[18] == "-",
          scalars[23] == "-",
          scalars[14] == "4",
          ["8", "9", "a", "b"].contains(scalars[19]),
          UUID(uuidString: value)?.uuidString.lowercased() == value
    else {
      return false
    }

    let hexPositions = [
      0, 1, 2, 3, 4, 5, 6, 7,
      9, 10, 11, 12,
      15, 16, 17,
      19, 20, 21, 22,
      24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35
    ]
    return hexPositions.allSatisfy { isLowerHex(scalars[$0]) }
  }

  static func stableID(_ value: String) -> StableID? {
    StableID(rawValue: value)
  }

  /// Resolve a requested route against a snapshot of rows.  The returned
  /// value is always a canonical stable ID; a raw group ID never escapes this
  /// boundary.
  static func resolve(_ requestedID: String, in records: [Record]) throws -> String {
    try resolveID(requestedID, in: records).rawValue
  }

  static func resolveID(_ requestedID: String, in records: [Record]) throws -> StableID {
    let canonicalRecords = try canonicalize(records)

    if isCanonicalStableID(requestedID) {
      guard let match = canonicalRecords.first(where: { $0.conversationID == requestedID }) else {
        throw Error.unresolved(requestedID)
      }
      // canonicalize() validated this row, so the failable initializer cannot
      // fail here unless this function and the gate disagree.
      return StableID(rawValue: match.conversationID)!
    }

    guard isNormalizedHex(requestedID) else {
      throw Error.invalidStableID(requestedID)
    }

    guard let match = canonicalRecords.first(where: { $0.groupID == requestedID }) else {
      // `canonicalize` already rejects a raw-only group.  This is the
      // unknown-raw case, which must also fail closed.
      throw Error.unresolved(requestedID)
    }
    return StableID(rawValue: match.conversationID)!
  }

  /// Normalize a snapshot of conversation records into canonical stable routes.
  /// A raw group alias is collapsed into its single canonical row.  Any raw-only
  /// group or malformed non-canonical row is excluded from the result with a
  /// diagnostic log, so healthy conversations are not withheld.
  /// Ambiguous mappings (one stable ID mapping multiple groups, or one group
  /// mapping multiple canonical rows) represent cryptographic and routing integrity
  /// violations and fail the operation globally.
  static func canonicalize(_ records: [Record]) throws -> [Record] {
    guard !records.isEmpty else { return [] }

    var normalized: [Record] = []
    normalized.reserveCapacity(records.count)
    for record in records {
      let groupID = record.groupID.lowercased()
      guard isNormalizedHex(groupID) else {
        logger.warning("Excluding MLS record with invalid group ID hex: conversationID=\(record.conversationID, privacy: .public), groupID=\(record.groupID, privacy: .public)")
        continue
      }
      normalized.append(Record(conversationID: record.conversationID, groupID: groupID))
    }

    guard !normalized.isEmpty else { return [] }

    // A stable ID must never identify two different groups, even if each
    // group independently has one canonical row.
    var stableIDGroups: [String: Set<String>] = [:]
    for record in normalized where isCanonicalStableID(record.conversationID) {
      stableIDGroups[record.conversationID, default: []].insert(record.groupID)
    }
    for (stableID, groupIDs) in stableIDGroups where groupIDs.count > 1 {
      logger.error("Ambiguous stable ID mapping multiple groups: stableID=\(stableID, privacy: .public), groupIDs=\(groupIDs, privacy: .public)")
      throw Error.ambiguous(stableID)
    }

    var groups: [String: [Record]] = [:]
    for record in normalized {
      groups[record.groupID, default: []].append(record)
    }

    var result: [Record] = []
    var emittedStableIDs = Set<String>()
    for (groupID, rows) in groups {
      let canonical = rows.filter { isCanonicalStableID($0.conversationID) }
      guard canonical.count <= 1 else {
        logger.error("Ambiguous group with multiple canonical stable IDs: groupID=\(groupID, privacy: .public), count=\(canonical.count)")
        throw Error.ambiguous(groupID)
      }

      // Every noncanonical value is allowed only if it is exactly the
      // normalized raw group hex.  Uppercase, compact UUIDs, UUIDv1, and
      // arbitrary strings are excluded per-row rather than failing the whole list.
      for row in rows where !isCanonicalStableID(row.conversationID) {
        if row.conversationID != groupID {
          logger.warning("Excluding row with non-canonical conversation ID not matching group hex: conversationID=\(row.conversationID, privacy: .public), groupID=\(groupID, privacy: .public)")
        }
      }

      guard let canonicalRow = canonical.first else {
        // Raw-only group (e.g. phantom row left by failed create). Exclude it.
        logger.warning("Excluding raw-only MLS group with no canonical stable ID: groupID=\(groupID, privacy: .public)")
        continue
      }

      if emittedStableIDs.insert(canonicalRow.conversationID).inserted {
        result.append(canonicalRow)
      }
    }

    // Preserve caller ordering for deterministic list diffs.  The dictionary
    // iteration above only determines which rows survive; this pass restores
    // the original order without reintroducing an alias.
    let surviving = Set(result)
    return normalized.filter { surviving.contains($0) && isCanonicalStableID($0.conversationID) }
      .reduce(into: []) { output, record in
        guard !output.contains(where: { $0.conversationID == record.conversationID }) else { return }
        output.append(record)
      }
  }

  static func record(for state: BlueCatbirdChatDefs.ConversationState) -> Record {
    Record(
      conversationID: state.coordinates.conversationId,
      groupID: state.coordinates.groupId.data.hexEncodedString()
    )
  }

  static func canonicalize(
    _ states: [BlueCatbirdChatDefs.ConversationState]
  ) throws -> [BlueCatbirdChatDefs.ConversationState] {
    let records = states.map(record(for:))
    let canonicalRecords = try canonicalize(records)
    let canonicalIDs = Set(canonicalRecords.map(\.conversationID))
    var emitted = Set<String>()
    return states.filter { state in
      let id = state.coordinates.conversationId
      return canonicalIDs.contains(id) && emitted.insert(id).inserted
    }
  }

  private static func isNormalizedHex(_ value: String) -> Bool {
    let scalars = Array(value.unicodeScalars)
    guard !scalars.isEmpty, scalars.count.isMultiple(of: 2), value == value.lowercased() else {
      return false
    }
    return scalars.allSatisfy(isLowerHex)
  }

  private static func isLowerHex(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 48 ... 57, 97 ... 102:
      return true
    default:
      return false
    }
  }
}

typealias MLSConversationIdentityError = MLSConversationIdentityBoundary.Error
