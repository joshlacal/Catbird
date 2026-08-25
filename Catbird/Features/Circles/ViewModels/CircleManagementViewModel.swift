import Foundation
import Observation
import Petrel
import PetrelCatbird

/// Copy constants for Circle management disclosures and confirmations.
enum CircleManagementCopy {
  static let addMemberDisclosure = "Newly added members will receive the entire Circle history."
  static let removeMemberDisclosure = "Removed members cannot access future posts, but prior downloads cannot be recalled."
}

/// Observable lifecycle state for Circle management operations.
enum CircleManagementState: Equatable, Sendable {
  case idle
  case submitting
  case pending(CircleOperation)
  case complete
  case failed(message: String, retryOperationID: UUID?)

  /// The operation UUID available for generated retryOperation, if any.
  var retryOperationID: UUID? {
    switch self {
    case .pending(let op):
      return UUID(uuidString: op.id)
    case .failed(_, let retryID):
      return retryID
    default:
      return nil
    }
  }

  /// Whether a named operation retry is available.
  var canRetry: Bool {
    retryOperationID != nil
  }
}

/// View model for creating Circles and managing members/settings of an existing Circle.
@MainActor
@Observable
final class CircleManagementViewModel {
  var circle: CircleSummary
  var state: CircleManagementState = .idle
  var name: String = ""
  var memberDIDsInput: String = ""
  var members: [DID] = []
  var validationError: String?

  let service: CircleService
  let userDID: String
  let isCreating: Bool

  init(circle: CircleSummary, service: CircleService, userDID: String = "") {
    self.circle = circle
    self.service = service
    self.userDID = userDID
    self.name = circle.name
    self.isCreating = false
    let isOwner = !userDID.isEmpty && circle.owner.didString() == userDID
    if isOwner, let circleMembers = circle.members {
      self.members = circleMembers
    } else {
      self.members = []
    }
  }

  init(service: CircleService, userDID: String = "") {
    let placeholderURI = (try? SpaceRef(uriString: "at://did:plc:placeholder/space/blue.catbird.circle/new"))
      ?? (try! SpaceRef(uriString: "at://did:plc:placeholder/space/blue.catbird.circle/new"))
    let ownerDID = (try? DID(didString: userDID.isEmpty ? "did:plc:placeholder" : userDID))
      ?? (try! DID(didString: "did:plc:placeholder"))
    self.circle = CircleSummary(
      uri: placeholderURI,
      name: "",
      owner: ownerDID,
      accessState: .value_active,
      muted: false,
      members: nil
    )
    self.service = service
    self.userDID = userDID
    self.isCreating = true
  }

  /// Only the Circle owner may manage members or delete the Circle.
  var canManageMembers: Bool {
    guard !isCreating else { return true }
    guard !userDID.isEmpty else { return false }
    return circle.owner.didString() == userDID
  }

  /// Whether a named operation retry is actionable for the current state.
  var canRetry: Bool {
    state.canRetry
  }

  /// Authoritatively loads the member roster for owners.
  func loadMembers() async {
    guard canManageMembers else { return }
    do {
      let page = try await service.listCircles(cursor: nil)
      if let current = page.circles.first(where: { $0.uri == circle.uri }) {
        self.circle = current
        if let currentMembers = current.members {
          self.members = currentMembers
        }
      }
    } catch {
      // Preserve existing in-memory members on network failure
    }
  }
  /// Whether this Circle is muted by the active member.
  var isMuted: Bool {
    circle.muted ?? false
  }

  // MARK: - Validation

  /// Validates a Circle name (1...64 trimmed characters).
  static func validateName(_ name: String) -> Result<String, CircleError> {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, (1...64).contains(trimmed.count) else {
      return .failure(.invalidParameter("Circle name must be between 1 and 64 characters"))
    }
    return .success(trimmed)
  }

  /// Validates a member DID list (at most 150 unique valid DIDs).
  static func validateMemberDIDs(_ dids: [DID]) -> Result<[DID], CircleError> {
    var uniqueDIDs: [DID] = []
    var seen = Set<String>()
    for did in dids {
      let str = did.didString()
      if !seen.contains(str) {
        seen.insert(str)
        uniqueDIDs.append(did)
      }
    }
    guard uniqueDIDs.count <= 150 else {
      return .failure(.invalidParameter("Circle cannot exceed 150 unique members"))
    }
    return .success(uniqueDIDs)
  }

  /// Parses comma/space/newline-separated DID strings and validates uniqueness and count.
  static func parseAndValidateDIDs(from input: String) -> Result<[DID], CircleError> {
    let rawTokens = input.components(separatedBy: CharacterSet(charactersIn: ", \n\t;"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var dids: [DID] = []
    for token in rawTokens {
      do {
        let did = try DID(didString: token)
        dids.append(did)
      } catch {
        return .failure(.invalidParameter("Invalid DID format: \(token)"))
      }
    }
    return validateMemberDIDs(dids)
  }

  // MARK: - Operations

  /// Creates a new named Circle.
  func createCircle(name: String? = nil, memberDIDs: [DID]? = nil) async throws -> CircleOperation? {
    let rawName = name ?? self.name
    let validName: String
    switch Self.validateName(rawName) {
    case .success(let n):
      validName = n
      self.validationError = nil
    case .failure(let error):
      self.validationError = error.localizedDescription
      self.state = .failed(message: error.localizedDescription, retryOperationID: nil)
      throw error
    }

    let finalDIDs: [DID]
    if let memberDIDs {
      switch Self.validateMemberDIDs(memberDIDs) {
      case .success(let d):
        finalDIDs = d
        self.validationError = nil
      case .failure(let error):
        self.validationError = error.localizedDescription
        self.state = .failed(message: error.localizedDescription, retryOperationID: nil)
        throw error
      }
    } else if !memberDIDsInput.isEmpty {
      switch Self.parseAndValidateDIDs(from: memberDIDsInput) {
      case .success(let d):
        finalDIDs = d
        self.validationError = nil
      case .failure(let error):
        self.validationError = error.localizedDescription
        self.state = .failed(message: error.localizedDescription, retryOperationID: nil)
        throw error
      }
    } else {
      finalDIDs = members
    }

    state = .submitting
    do {
      let operation = try await service.createCircle(name: validName, memberDIDs: finalDIDs)
      handleOperation(operation)
      return operation
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: nil)
      throw cError
    }
  }

  /// Adds a member to an existing Circle (owner only).
  func addMember(did: DID) async throws -> CircleOperation? {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription, retryOperationID: nil)
      throw error
    }

    guard members.count < 150 else {
      let error = CircleError.invalidParameter("Circle cannot exceed 150 unique members")
      state = .failed(message: error.localizedDescription, retryOperationID: nil)
      throw error
    }

    state = .submitting
    do {
      let operation = try await service.updateMember(space: circle.uri, memberDID: did, action: .add)
      handleOperation(operation)
      if operation.status == .value_complete {
        if !members.contains(where: { $0.didString() == did.didString() }) {
          members.append(did)
        }
      }
      return operation
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: nil)
      throw cError
    }
  }

  /// Removes a member from an existing Circle (owner only).
  func removeMember(did: DID) async throws -> CircleOperation? {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription, retryOperationID: nil)
      throw error
    }

    state = .submitting
    do {
      let operation = try await service.updateMember(space: circle.uri, memberDID: did, action: .remove)
      handleOperation(operation)
      if operation.status == .value_complete {
        members.removeAll(where: { $0.didString() == did.didString() })
      }
      return operation
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: nil)
      throw cError
    }
  }

  /// Deletes a Circle Space entirely (owner only).
  func deleteCircle() async throws -> CircleOperation? {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription, retryOperationID: nil)
      throw error
    }

    state = .submitting
    do {
      let operation = try await service.deleteCircle(space: circle.uri)
      handleOperation(operation)
      if operation.status == .value_complete {
        await CircleFeedCache.shared.purge(accountDID: userDID, space: circle.uri)
        await CircleMediaLoader.shared.purge(accountDID: userDID, space: circle.uri)
        await CircleNotificationCache.shared.purge(accountDID: userDID, space: circle.uri)
      }
      return operation
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: nil)
      throw cError
    }
  }

  /// Updates private member mute preferences.
  func setMuted(_ muted: Bool) async throws {
    do {
      let updatedMuted = try await service.updatePreferences(space: circle.uri, muted: muted)
      self.circle = CircleSummary(
        uri: circle.uri,
        name: circle.name,
        owner: circle.owner,
        accessState: circle.accessState,
        muted: updatedMuted,
        members: circle.members
      )
      if updatedMuted {
        await CircleFeedCache.shared.purgeMutedSpaceFromUnified(accountDID: userDID, space: circle.uri)
        await CircleNotificationCache.shared.purgeMutedSpace(accountDID: userDID, space: circle.uri)
        NotificationCenter.default.post(
          name: .circleMuteStateChanged,
          object: nil,
          userInfo: [
            "accountDID": userDID,
            "spaceURI": circle.uri.uriString()
          ]
        )
      }
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: nil)
      throw cError
    }
  }

  /// Retries the named or currently pending/failed operation without duplicating submissions.
  func retry(operationID: UUID? = nil) async throws {
    let targetID: String?
    if let operationID {
      targetID = operationID.uuidString.lowercased()
    } else {
      switch state {
      case .pending(let op):
        targetID = op.id
      case .failed(_, let retryID):
        targetID = retryID?.uuidString.lowercased()
      default:
        targetID = nil
      }
    }

    guard let opID = targetID, !opID.isEmpty else { return }

    state = .submitting
    do {
      let op = try await service.retryOperation(id: opID)
      handleOperation(op)
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: UUID(uuidString: opID))
      throw cError
    }
  }

  /// Read-only status consultation for an in-flight operation.
  func checkStatus(operationID: String) async throws {
    do {
      let op = try await service.getOperation(id: operationID)
      handleOperation(op)
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription, retryOperationID: UUID(uuidString: operationID))
      throw cError
    }
  }

  private func handleOperation(_ operation: CircleOperation) {
    switch operation.status {
    case .value_complete:
      state = .complete
    case .value_pending:
      state = .pending(operation)
    case .value_failed:
      let opUUID = UUID(uuidString: operation.id)
      state = .failed(message: operation.error ?? "Operation failed", retryOperationID: opUUID)
    }
  }
}
