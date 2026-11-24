import Foundation
import Observation
import OSLog
import Petrel
import PetrelCatbird

/// Copy constants for Circle management disclosures and confirmations.
enum CircleManagementCopy {
  static var metadataReadFailed: String {
    String(localized: "Couldn't read this Circle's settings. Try again.", comment: "Error when reading a Circle's metadata settings fails.")
  }
  static var addMemberDisclosure: String {
    String(localized: "Newly added members will receive the entire Circle history.", comment: "Disclosure explaining that newly added Circle members can view earlier posts.")
  }
  static var removeMemberDisclosure: String {
    String(localized: "Removed members cannot access future posts, but prior downloads cannot be recalled.", comment: "Disclosure shown before removing a member from a Circle.")
  }

  // Encrypted Circles (spec §6, §7, §9)
  static var historyToggleLabel: String {
    String(localized: "New members can see earlier posts", comment: "Toggle label controlling whether newly added encrypted Circle members receive past keys.")
  }
  static var historyOffAddConfirmation: String {
    String(localized: "They will only see new posts.", comment: "Confirmation detail when adding members to an encrypted Circle with history sharing turned off.")
  }
  static var rotateKeyNow: String {
    String(localized: "Rotate key now", comment: "Button and alert title to manually rotate an encrypted Circle's content key.")
  }
  static var rotateKeyConfirmation: String {
    String(localized: "Members will need to refresh. Posts you make from now on use a new key.", comment: "Confirmation message explaining manual Circle key rotation.")
  }
  static var retryNow: String {
    String(localized: "Retry now", comment: "Button to retry pending Circle key re-wraps or membership changes.")
  }
  static var upgradeToEncrypted: String {
    String(localized: "Upgrade to encrypted", comment: "Button and sheet title to upgrade a plaintext Circle to end-to-end encryption.")
  }
  static var upgradeIncomplete: String {
    String(localized: "Upgrade incomplete — tap to retry", comment: "Button and status message when upgrading a Circle to encrypted stopped partway through.")
  }
  static var removalPending: String {
    String(localized: "Removal pending", comment: "Badge on a Circle member row whose removal is waiting to complete.")
  }
  static var accessPending: String {
    String(localized: "Access pending", comment: "Badge on a Circle member row whose access grant is waiting to complete.")
  }
  static var keyRefreshPending: String {
    String(localized: "Key refresh pending", comment: "Badge on a Circle member row whose history key re-wrap is pending.")
  }
  static var waitingToRefreshAccess: String {
    String(localized: "Waiting to refresh access", comment: "Badge on a Circle member row waiting for encryption key access refresh.")
  }
  static var encryptionUnavailableHint: String {
    String(localized: "Encrypted Circles need encrypted features turned on.", comment: "Hint explaining why encrypted Circles cannot be created or upgraded yet.")
  }
  static var encryptionCheckFailed: String {
    String(localized: "Couldn't check whether this Circle can be encrypted. Try again.", comment: "Error when checking encrypted Circle capability fails.")
  }
  static var eligibilityCheckFailed: String {
    String(localized: "Couldn't check who can be carried over. Try again.", comment: "Error when checking which Circle members support encryption fails.")
  }
  static var noMembersCanBeCarriedOver: String {
    String(localized: "No members can be carried over yet", comment: "Warning when none of a Circle's current members have enabled encrypted features.")
  }

  static func ineligibleMember(handle: String) -> String {
    String(
      localized: "Can't add: \(handle) hasn't enabled encrypted features.",
      comment: "Message when a person cannot be added to an encrypted Circle — %1$@ is their handle or DID."
    )
  }

  /// Badge copy for a pending entry's reason (`CircleKeyManager` reasons; any
  /// other reason is an FFI exclusion, which may be transient: always retryable).
  static func pendingBadge(reason: String) -> String {
    if reason.hasPrefix(CircleKeyManager.aclRemoveReason) { return removalPending }
    if reason == CircleKeyManager.aclAddReason { return accessPending }
    let lowered = reason.lowercased()
    if lowered.contains("history") || lowered.contains("rewrap") { return keyRefreshPending }
    return waitingToRefreshAccess
  }
}

/// Result of a dry-run wrap over a set of members. A failed check is not
/// "everyone ineligible": nothing may be created or migrated on it.
enum CircleUpgradeEligibility: Sendable {
  case checked(eligible: [DID], ineligible: [(did: DID, reason: String)])
  case checkFailed(message: String)
}

/// Observable lifecycle state for Circle management operations.
enum CircleManagementState: Equatable, Sendable {
  case idle
  case submitting
  case complete
  case failed(message: String)
  case activationFailed(message: String)
  /// A D17 upgrade stopped after its new Space was created; retrying resumes it.
  case upgradeIncomplete(message: String)

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
  var members: [DID] = []
  private(set) var memberPermissions: [CircleMember] = []
  var validationError: String?

  // Encrypted Circles
  /// §7, stored in the Space's metadata record (owner-written). Off: adds rotate
  /// and the newcomer gets only the new version (§6 rule 3).
  var historyForNewMembers: Bool = true
  /// Pending re-wraps by member DID (ACL prefixes stripped, markers dropped),
  /// with the stored reason.
  private(set) var pendingRewraps: [(did: String, reason: String)] = []
  /// Handles for DIDs the view knows (picker selections, hydrated roster), used
  /// in ineligible-member copy; the DID is shown otherwise.
  var knownHandles: [String: String] = [:]
  /// The dry run shown before an upgrade is confirmed.
  private(set) var upgradeEligibility: CircleUpgradeEligibility?
  /// Spec §9 gate (create default and upgrade row); nil until checked.
  private(set) var encryptionAvailability: CircleEncryptionAvailability?
  /// Create flow: whether the Circle will be encrypted, and the picked members
  /// a dry run excluded (they are left out of an encrypted create).
  private(set) var createEncrypted = false
  private(set) var createIneligible: [(did: DID, reason: String)] = []
  /// True while a history-toggle write is in flight (writes are serialized).
  private(set) var isWritingHistorySetting = false
  /// New Space of an unfinished upgrade (resumed by `upgradeToEncrypted`).
  private(set) var upgradeTarget: CircleSummary?
  private var didReconcile = false

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

  static let placeholderURIString = "at://did:plc:placeholder/space/blue.catbird.circle/new"

  init(service: CircleService, userDID: String = "") {
    let placeholderURI = (try? SpaceRef(uriString: Self.placeholderURIString))
      ?? (try! SpaceRef(uriString: Self.placeholderURIString))
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

  /// Whether a real Circle Space has been created on the owner's PDS (preventing recreation).
  var hasCreatedSpace: Bool {
    circle.uri.uriString() != Self.placeholderURIString
  }

  /// Authoritatively loads the member roster for owners directly from the owner's PDS.
  func loadMembers() async {
    guard canManageMembers else { return }
    do {
      let memberList = try await service.listMembers(space: circle.uri)
      self.memberPermissions = memberList
      self.members = memberList.map(\.did)
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
      return .failure(.invalidParameter(String(
        localized: "Circle name must be between 1 and 64 characters",
        comment: "Validation error when a Circle name is empty or exceeds 64 characters."
      )))
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
      return .failure(.invalidParameter(String(
        localized: "Circle cannot exceed 150 unique members",
        comment: "Validation error when more than 150 members are added to a Circle."
      )))
    }
    return .success(uniqueDIDs)
  }

  // MARK: - Operations

  /// Creates a new named Circle following the 5-step sequence:
  /// 1. Mint TID skey and circleId
  /// 2. createSpace on PDS with a memberspace policy whose allowedApps is the AppView
  /// 3. putRecord metadata with circleId
  /// 4. addMember per initial member on PDS
  /// 5. activateCircle against AppView (failure preserves the Space for activation retry)
  @discardableResult
  func createCircle(name: String? = nil, memberDIDs: [DID]? = nil) async throws -> CircleSummary {
    guard state != .submitting else {
      return circle
    }

    if hasCreatedSpace || canRetryActivation {
      try await retryActivation()
      return circle
    }

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
    } else {
      finalDIDs = members
    }

    // Marked before the first await so a concurrent second submit is refused.
    state = .submitting
    // Spec §9: encrypted by default when this device can, plaintext otherwise.
    let availability = await service.encryptionAvailability()
    encryptionAvailability = availability
    createEncrypted = availability.isAvailable
    // I9: enrolled but the capability check failed: never create plaintext.
    if availability == .checkFailed {
      state = .failed(message: CircleManagementCopy.encryptionCheckFailed)
      throw CircleError.invalidParameter(CircleManagementCopy.encryptionCheckFailed)
    }
    var createMembers = finalDIDs
    if availability.isAvailable && !finalDIDs.isEmpty {
      switch await eligibleMembers(finalDIDs) {
      case .checkFailed:
        let error = CircleError.invalidParameter(CircleManagementCopy.eligibilityCheckFailed)
        state = .failed(message: CircleManagementCopy.eligibilityCheckFailed)
        throw error
      case .checked(let eligible, let ineligible):
        createMembers = eligible
        createIneligible = ineligible
      }
    }

    let skey = await TIDGenerator.shared.nextStr()
    let circleId = await TIDGenerator.shared.nextStr()

    let createdSummary: CircleSummary
    do {
      createdSummary = try await service.createSpace(
        skey: skey,
        circleId: circleId,
        name: validName,
        memberDIDs: createMembers,
        encrypted: availability.isAvailable
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
      switch cError {
      case .authRequired, .notAuthorized, .accessExpired:
        CircleAppViewAuthCoordinator.shared.invalidate(for: userDID)
      default:
        break
      }
      self.state = .activationFailed(message: cError.localizedDescription)
      return createdSummary
    }
  }

  /// Retries AppView activation for an already created Circle Space.
  func retryActivation() async throws {
    guard canRetryActivation || hasCreatedSpace else { return }
    guard state != .submitting else { return }
    state = .submitting
    do {
      let activated = try await service.activateCircle(space: circle.uri)
      self.circle = activated
      self.state = .complete
    } catch {
      let cError = circleError(from: error)
      switch cError {
      case .authRequired, .notAuthorized, .accessExpired:
        CircleAppViewAuthCoordinator.shared.invalidate(for: userDID)
      default:
        break
      }
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
      let error = CircleError.invalidParameter(String(
        localized: "Circle cannot exceed 150 unique members",
        comment: "Validation error when more than 150 members are added to a Circle."
      ))
      state = .failed(message: error.localizedDescription)
      throw error
    }

    if circle.isEncrypted {
      switch await eligibleMembers([did]) {
      case .checkFailed(let message):
        state = .failed(message: message)
        throw CircleError.invalidParameter(message)
      case .checked(_, let ineligible) where !ineligible.isEmpty:
        let message = ineligibleMessage(for: did)
        state = .failed(message: message)
        throw CircleError.ineligibleMember(reason: message)
      case .checked:
        break
      }
    }

    // I4: the history policy is read from the Space at add time and fails
    // closed. A failed or missing read blocks the add; it never falls back to
    // history ON (which would hand the new member every earlier post).
    var historyVisible = false
    if circle.isEncrypted {
      guard let metadata = try? await service.metadata(space: circle.uri) else {
        let message = CircleManagementCopy.metadataReadFailed
        state = .failed(message: message)
        throw CircleError.invalidParameter(message)
      }
      historyVisible = metadata.historyForNewMembers ?? true
      historyForNewMembers = historyVisible
    }

    state = .submitting
    do {
      try await service.addMember(circle: circle, did: did, historyVisible: historyVisible)
      if !members.contains(where: { $0.didString() == did.didString() }) {
        members.append(did)
      }
      state = .complete
      if circle.isEncrypted { await refreshPendingRewraps() }
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      if circle.isEncrypted { await refreshPendingRewraps() }
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
      try await service.removeMember(circle: circle, did: did)
      members.removeAll(where: { $0.didString() == did.didString() })
      memberPermissions.removeAll(where: { $0.did == did })
      state = .complete
      if circle.isEncrypted { await refreshPendingRewraps() }
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      // A removal whose rotation landed stays pending (badge + Retry now).
      if circle.isEncrypted { await refreshPendingRewraps() }
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
  // MARK: - Encrypted Circles

  /// Whether the active owner can rotate now: never while a removal is
  /// unresolved (its own rotation, then the ACL call, must finish first).
  var canRotateKeyNow: Bool {
    canManageMembers && !isCreating && circle.isEncrypted && !hasPendingRemoval && state != .submitting
  }

  var hasPendingRemoval: Bool {
    pendingRewraps.contains { $0.reason.hasPrefix(CircleKeyManager.aclRemoveReason) }
  }

  /// Whether an upgrade stopped midway and can be resumed.
  var hasIncompleteUpgrade: Bool { upgradeTarget != nil }

  var encryptionAvailable: Bool { encryptionAvailability?.isAvailable == true }

  /// Members the last upgrade dry run excluded.
  var upgradeIneligible: [(did: DID, reason: String)] {
    if case .checked(_, let ineligible) = upgradeEligibility { return ineligible }
    return []
  }

  /// Why the upgrade cannot be confirmed now, or nil when it can.
  var upgradeBlockedReason: String? {
    switch upgradeEligibility {
    case nil:
      return nil
    case .checkFailed:
      return CircleManagementCopy.eligibilityCheckFailed
    case .checked(let eligible, _):
      return eligible.isEmpty && !members.isEmpty ? CircleManagementCopy.noMembersCanBeCarriedOver : nil
    }
  }

  var canConfirmUpgrade: Bool {
    encryptionAvailable && upgradeEligibility != nil && upgradeBlockedReason == nil
  }

  /// Badge copy for a member row, or nil when the member has nothing pending.
  func pendingBadge(for did: DID) -> String? {
    pendingRewraps.first { $0.did == did.didString() }.map { CircleManagementCopy.pendingBadge(reason: $0.reason) }
  }

  func ineligibleMessage(for did: DID) -> String {
    CircleManagementCopy.ineligibleMember(handle: knownHandles[did.didString()] ?? did.didString())
  }

  /// Owner only: the history toggle from the metadata record, the pending
  /// re-wrap list (encrypted), or an unfinished upgrade (plaintext).
  func loadEncryptionState() async {
    guard canManageMembers, !isCreating else { return }
    if let metadata = try? await service.metadata(space: circle.uri) {
      historyForNewMembers = metadata.historyForNewMembers ?? true
    }
    if circle.isEncrypted {
      await refreshPendingRewraps()
      return
    }
    encryptionAvailability = await service.encryptionAvailability()
    if upgradeTarget == nil, encryptionAvailable, let target = try? await service.pendingUpgradeTarget(from: circle) {
      upgradeTarget = target
      state = .upgradeIncomplete(message: CircleManagementCopy.upgradeIncomplete)
    }
  }

  /// §7: writes the toggle to the metadata record. Off affects only future adds.
  func setHistoryForNewMembers(_ value: Bool) async {
    guard canManageMembers, !isCreating, !isWritingHistorySetting else { return }
    isWritingHistorySetting = true
    defer { isWritingHistorySetting = false }
    let previous = historyForNewMembers
    historyForNewMembers = value
    do {
      try await service.setHistoryForNewMembers(circle: circle, value)
    } catch {
      historyForNewMembers = previous
      state = .failed(message: circleError(from: error).localizedDescription)
    }
  }

  /// §6 rule 7: `rotate(reason: "manualRotation")`. A no-op while a removal is
  /// pending (rechecked against the store first).
  func rotateKeyNow() async {
    await refreshPendingRewraps()
    guard canRotateKeyNow else { return }
    state = .submitting
    do {
      try await service.rotateKey(circle: circle, reason: "manualRotation")
      state = .complete
    } catch {
      state = .failed(message: circleError(from: error).localizedDescription)
    }
    await refreshPendingRewraps()
  }

  /// D15 "Retry now": completes pending removals/grants and re-wraps excluded members.
  func retryPendingNow() async {
    guard canManageMembers, circle.isEncrypted, state != .submitting else { return }
    state = .submitting
    do {
      try await service.retryPendingRewraps(circle: circle)
      state = .complete
    } catch {
      state = .failed(message: circleError(from: error).localizedDescription)
    }
    await refreshPendingRewraps()
    await loadMembers()
  }

  /// Rules 5–6 on management appear (owner, encrypted): once per view model,
  /// fire-and-forget; failures are logged by type name only.
  func reconcileOnAppear() {
    guard !didReconcile, canManageMembers, !isCreating, circle.isEncrypted else { return }
    didReconcile = true
    let service = service
    let circle = circle
    Task { [weak self] in
      // No encryption context yet (MLS client not up): skip silently.
      guard await service.encryptionContextAvailable() else { return }
      do {
        try await service.reconcileEpochs(circle: circle)
      } catch {
        Logger(subsystem: "blue.catbird", category: "CircleKeys")
          .info("Circles: reconcile on appear failed: \(String(describing: type(of: error)), privacy: .public)")
      }
      await self?.refreshPendingRewraps()
    }
  }

  /// Dry-run wrap (nothing written). A failed check is `.checkFailed`, never
  /// "everyone ineligible".
  func eligibleMembers(_ dids: [DID]) async -> CircleUpgradeEligibility {
    do {
      let result = try await service.eligibility(circle: circle, dids: dids)
      return .checked(eligible: result.eligible, ineligible: result.ineligible.map { (did: $0.0, reason: $0.reason) })
    } catch {
      return .checkFailed(message: circleError(from: error).localizedDescription)
    }
  }

  /// Computes the members an upgrade can carry over; the view shows
  /// `upgradeIneligible` / `upgradeBlockedReason` and asks the owner to confirm.
  func prepareUpgrade() async {
    if encryptionAvailability == nil { encryptionAvailability = await service.encryptionAvailability() }
    upgradeEligibility = await eligibleMembers(members)
  }

  /// Create flow: whether the new Circle will be encrypted, and which picked
  /// members an encrypted create would leave out (shown before creating).
  func prepareCreate(memberDIDs: [DID]) async {
    let availability = await service.encryptionAvailability()
    encryptionAvailability = availability
    createEncrypted = availability.isAvailable
    guard availability.isAvailable, !memberDIDs.isEmpty,
          case .checked(_, let ineligible) = await eligibleMembers(memberDIDs)
    else {
      createIneligible = []
      return
    }
    createIneligible = ineligible
  }

  /// D17 upgrade (owner, plaintext Circle), resuming an unfinished one if any:
  /// `CircleService.upgradeToEncrypted` runs steps 1–4, then the new Space is
  /// activated (step 5; a failure there is the usual activation retry).
  func upgradeToEncrypted() async throws {
    guard canManageMembers, !isCreating else {
      let error = CircleError.notAuthorized
      state = .failed(message: error.localizedDescription)
      throw error
    }
    guard state != .submitting else { return }
    if encryptionAvailability == nil { encryptionAvailability = await service.encryptionAvailability() }
    guard encryptionAvailable else {
      state = .failed(message: CircleManagementCopy.encryptionUnavailableHint)
      throw CircleError.invalidParameter(CircleManagementCopy.encryptionUnavailableHint)
    }
    // A resume grants the persisted v1 recipients; only a fresh upgrade needs
    // a (successful, non-empty) dry run.
    var eligible: [DID] = []
    if upgradeTarget == nil {
      if upgradeEligibility == nil { await prepareUpgrade() }
      if let blocked = upgradeBlockedReason {
        state = .failed(message: blocked)
        throw CircleError.invalidParameter(blocked)
      }
      if case .checked(let checked, _) = upgradeEligibility { eligible = checked }
    }

    state = .submitting
    let upgraded: CircleSummary
    do {
      upgraded = try await service.upgradeToEncrypted(from: circle, eligible: eligible, resuming: upgradeTarget)
    } catch let incomplete as CircleUpgradeIncompleteError {
      upgradeTarget = incomplete.target
      state = .upgradeIncomplete(message: CircleManagementCopy.upgradeIncomplete)
      throw incomplete.underlying
    } catch {
      let cError = circleError(from: error)
      state = .failed(message: cError.localizedDescription)
      throw cError
    }
    upgradeTarget = nil
    upgradeEligibility = nil
    circle = upgraded
    members = []
    memberPermissions = []

    do {
      circle = try await service.activateCircle(space: upgraded.uri)
      state = .complete
    } catch {
      let cError = circleError(from: error)
      switch cError {
      case .authRequired, .notAuthorized, .accessExpired:
        CircleAppViewAuthCoordinator.shared.invalidate(for: userDID)
      default:
        break
      }
      state = .activationFailed(message: cError.localizedDescription)
    }
    await loadMembers()
    await loadEncryptionState()
  }

  private func refreshPendingRewraps() async {
    guard circle.isEncrypted, canManageMembers, !isCreating,
          let raw = try? await service.pendingRewraps(circle: circle)
    else { return }
    pendingRewraps = raw.compactMap { entry in
      if entry.did.hasPrefix(CircleKeyManager.aclRemovePrefix) {
        return (did: String(entry.did.dropFirst(CircleKeyManager.aclRemovePrefix.count)), reason: entry.reason)
      }
      if entry.did.hasPrefix(CircleKeyManager.aclAddPrefix) {
        return (did: String(entry.did.dropFirst(CircleKeyManager.aclAddPrefix.count)), reason: entry.reason)
      }
      return entry.did.hasPrefix("__") ? nil : entry
    }
  }
}
