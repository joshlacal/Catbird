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
  case complete
  case failed(message: String)
  case activationFailed(message: String)

  /// Whether AppView activation can be retried.
  var canRetryActivation: Bool {
    if case .activationFailed = self {
      return true
    }
    return false
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
    self.members = []
  }

  init(service: CircleService, userDID: String = "") {
    let placeholderURI = (try? SpaceRef(uriString: "at://did:plc:placeholder/space/blue.catbird.circle/new"))
      ?? (try! SpaceRef(uriString: "at://did:plc:placeholder/space/blue.catbird.circle/new"))
    let ownerDID = (try? DID(didString: userDID.isEmpty ? "did:plc:placeholder" : userDID))
      ?? (try! DID(didString: "did:plc:placeholder"))
    let placeholderTID = (try? TID(tidString: "3zzzzzzzzzzzz"))
      ?? (try! TID(tidString: "3zzzzzzzzzzzz"))
    self.circle = CircleSummary(
      uri: placeholderURI,
      circleId: placeholderTID,
      name: "",
      owner: ownerDID,
      memberCount: nil,
      muted: false
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

  /// Whether AppView activation can be retried.
  var canRetryActivation: Bool {
    state.canRetryActivation
  }

  /// Authoritatively loads the member roster for owners directly from the owner's PDS.
  func loadMembers() async {
    guard canManageMembers else { return }
    do {
      let memberList = try await service.listMembers(space: circle.uri)
      self.members = memberList
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

  /// Creates a new named Circle following the 5-step sequence:
  /// 1. Mint TID skey and circleId
  /// 2. createSpace on PDS with memberListPolicy and #allowList
  /// 3. putRecord metadata with circleId
  /// 4. addMember per initial member on PDS
  /// 5. activateCircle against AppView (activation failure is a retryable sync state)
  @discardableResult
  func createCircle(name: String? = nil, memberDIDs: [DID]? = nil) async throws -> CircleSummary {
    let rawName = name ?? self.name
    let validName: String
    switch Self.validateName(rawName) {
    case .success(let n):
      validName = n
      self.validationError = nil
    case .failure(let error):
      self.validationError = error.localizedDescription
      self.state = .failed(message: error.localizedDescription)
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
        self.state = .failed(message: error.localizedDescription)
        throw error
      }
    } else if !memberDIDsInput.isEmpty {
      switch Self.parseAndValidateDIDs(from: memberDIDsInput) {
      case .success(let d):
        finalDIDs = d
        self.validationError = nil
      case .failure(let error):
        self.validationError = error.localizedDescription
        self.state = .failed(message: error.localizedDescription)
        throw error
      }
    } else {
      finalDIDs = members
    }

    state = .submitting
    let skey = await TIDGenerator.shared.nextStr()
    let circleId = await TIDGenerator.shared.nextStr()

    let createdSummary: CircleSummary
    do {
      createdSummary = try await service.createSpace(
        skey: skey,
        circleId: circleId,
        name: validName,
        memberDIDs: finalDIDs
      )
      self.circle = createdSummary
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      throw cError
    }

    // Step 5: activate with AppView
    do {
      let activated = try await service.activateCircle(space: createdSummary.uri)
      self.circle = activated
      self.state = .complete
      return activated
    } catch {
      let cError = circleError(from: error)
      self.state = .activationFailed(message: cError.localizedDescription)
      return createdSummary
    }
  }

  /// Retries AppView activation for an already created Circle Space.
  func retryActivation() async throws {
    guard canRetryActivation else { return }
    state = .submitting
    do {
      let activated = try await service.activateCircle(space: circle.uri)
      self.circle = activated
      self.state = .complete
    } catch {
      let cError = circleError(from: error)
      self.state = .activationFailed(message: cError.localizedDescription)
      throw cError
    }
  }

  /// Adds a member to an existing Circle directly via PDS (owner only).
  func addMember(did: DID) async throws {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription)
      throw error
    }

    guard members.count < 150 else {
      let error = CircleError.invalidParameter("Circle cannot exceed 150 unique members")
      state = .failed(message: error.localizedDescription)
      throw error
    }

    state = .submitting
    do {
      try await service.addMember(space: circle.uri, did: did)
      if !members.contains(where: { $0.didString() == did.didString() }) {
        members.append(did)
      }
      state = .complete
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      throw cError
    }
  }

  /// Removes a member from an existing Circle directly via PDS (owner only).
  func removeMember(did: DID) async throws {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription)
      throw error
    }

    state = .submitting
    do {
      try await service.removeMember(space: circle.uri, did: did)
      members.removeAll(where: { $0.didString() == did.didString() })
      state = .complete
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      throw cError
    }
  }

  /// Deletes a Circle Space entirely on the owner's PDS (owner only).
  func deleteCircle() async throws {
    guard canManageMembers else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription)
      throw error
    }
    state = .submitting
    do {
      try await service.deleteSpace(space: circle.uri)
      state = .complete
      await CircleFeedCache.shared.purge(accountDID: userDID, space: circle.uri)
      await CircleMediaLoader.shared.purge(accountDID: userDID, space: circle.uri)
      await CircleNotificationCache.shared.purge(accountDID: userDID, space: circle.uri)
      NotificationCenter.default.post(
        name: .circleDeleted,
        object: nil,
        userInfo: [
          "accountDID": userDID,
          "spaceURI": circle.uri.uriString()
        ]
      )
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      throw cError
    }
  }

  /// Updates private member mute preferences.
  func setMuted(_ muted: Bool) async throws {
    do {
      let updatedMuted = try await service.updatePreferences(space: circle.uri, muted: muted)
      self.circle = CircleSummary(
        uri: circle.uri,
        circleId: circle.circleId,
        name: circle.name,
        owner: circle.owner,
        memberCount: circle.memberCount,
        muted: updatedMuted
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
      state = .failed(message: cError.localizedDescription)
      throw cError
    }
  }
}
