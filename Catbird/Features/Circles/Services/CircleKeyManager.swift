import CatbirdMLSCore
import Foundation
import OSLog
import Petrel
import PetrelCatbird

/// Multi-device sync bridge for encrypted `blue.catbird.labyrinth.circleOwnerState`
/// records stored inside the owner's personal Labyrinth mailbox Space.
protocol CircleOwnerStateSyncing: Sendable {
  func getOwnerState(circleId: String) async throws -> CircleOwnerStateDto?
  @discardableResult
  func mergeOwnerState(_ update: CircleOwnerStateDto) async throws -> CircleOwnerStateDto?
  @discardableResult
  func clearAclTombstone(circleId: String, memberDid: String) async throws -> CircleOwnerStateDto?
}

final class CoordinatorCircleOwnerStateSync: CircleOwnerStateSyncing, @unchecked Sendable {
  @MainActor private weak var coordinator: MLSClientCoordinator?

  @MainActor
  init(coordinator: MLSClientCoordinator) {
    self.coordinator = coordinator
  }

  func getOwnerState(circleId: String) async throws -> CircleOwnerStateDto? {
    guard let coordinator = await MainActor.run(body: { () -> MLSClientCoordinator? in
      guard let c = self.coordinator, !c.isHandleClosed else { return nil }
      return c
    }) else {
      return nil
    }
    return try await coordinator.getCircleOwnerState(circleId: circleId)
  }

  func mergeOwnerState(_ update: CircleOwnerStateDto) async throws -> CircleOwnerStateDto? {
    guard let coordinator = await MainActor.run(body: { () -> MLSClientCoordinator? in
      guard let c = self.coordinator, !c.isHandleClosed else { return nil }
      return c
    }) else {
      return nil
    }
    return try await coordinator.mergeCircleOwnerState(update: update)
  }

  func clearAclTombstone(circleId: String, memberDid: String) async throws -> CircleOwnerStateDto? {
    guard let coordinator = await MainActor.run(body: { () -> MLSClientCoordinator? in
      guard let c = self.coordinator, !c.isHandleClosed else { return nil }
      return c
    }) else {
      return nil
    }
    return try await coordinator.clearCircleAclTombstone(circleId: circleId, memberDid: memberDid)
  }
}

/// Owner- and member-side lifecycle of an encrypted Circle's content keys
/// (design spec `docs/superpowers/specs/2026-11-07-e2ee-circles-design.md` §6,
/// decisions D8, D14, D15).
///
/// - Versions: `CircleKey_vN`, N from 1, one `blue.catbird.circle.key` record per
///   version at rkey `<N zero-padded to 6>` in the owner's repo inside the Space.
/// - The local `CircleKeyStore` is the source of truth for "current version":
///   a new version is stored only after its record was written and read back
///   unchanged, so a client never posts under a key nobody else has, and never
///   under the old version once a rotation's record landed (D14).
/// - Wrapping, owner self-wrap and all owner-epoch trust live in the Rust FFI
///   (`CircleCrypto`); this type never sees mailbox keys. Members the FFI could
///   not wrap come back in `excluded`; an exclusion can be transient (directory
///   or network fault), so they go to the pending re-wrap list and are retried
///   (D15), never treated as permanently removed.
/// - Every wrap roster passes through one filter (`effectiveRoster`): members
///   whose Space ACL removal is still pending (`__acl__:<did>`) are never
///   wrapped, and members whose ACL grant is still pending (`__aclAdd__:<did>`)
///   are never dropped from a rewrite of the current version.
/// - Canonical post URI form (used in post AADs by later tasks):
///   `at://<author-did>/blue.catbird.circle.post/<rkey>` — not the space form.
///
/// Operations are serialized (one queue per manager), including the roster
/// reads of the member flows, so interleaved adds/removes cannot wrap a stale
/// roster or pick the same version. Key material is never logged.
actor CircleKeyManager {
  static let aclRemovePrefix = "__acl__:"
  static let aclRemoveReason = "aclRemovePending"
  /// Reason once the removal's rotation landed: only the ACL call remains.
  static let aclRemoveRotatedReason = "aclRemovePending:rotated"
  static let aclAddPrefix = "__aclAdd__:"
  static let aclAddReason = "aclAddPending"
  /// Prefix of a pending reason meaning "older versions still need this member".
  static let historyPendingPrefix = "historyRewrapPending: "
  /// §6 rule 6 cadence: the current version is re-wrapped at least this often.
  static let weeklyRewrapInterval: TimeInterval = 7 * 24 * 3600
  /// Pending entry on a NEW Space whose D17 upgrade has not finished (its key,
  /// ACL or the old Space's `migratedTo` is still missing).
  static let migrationMarker = "__migration__"
  static let migrationIncompleteReason = "migrationIncomplete"
  /// Pending entry on the OLD (plaintext) Space whose reason is the new Space's
  /// URI, so an interrupted upgrade can be found and resumed after a relaunch.
  static let migrationTargetMarker = "__migrationTarget__"

  private let logger = Logger(subsystem: "blue.catbird", category: "CircleKeys")
  private let crypto: any CircleCrypto
  private let store: CircleKeyStore
  private let transport: any CircleTransport
  private let ownerDID: DID
  private let ownerStateSync: (any CircleOwnerStateSyncing)?
  private var tail: Task<Void, Never>?

  init(
    crypto: any CircleCrypto,
    store: CircleKeyStore,
    transport: any CircleTransport,
    ownerDID: DID,
    ownerStateSync: (any CircleOwnerStateSyncing)? = nil
  ) {
    self.crypto = crypto
    self.store = store
    self.transport = transport
    self.ownerDID = ownerDID
    self.ownerStateSync = ownerStateSync
  }

  // MARK: - Public API

  /// Writes `v1` (reason `created`) wrapped to `memberDIDs`; the FFI adds this
  /// account itself. Call before any member is added to the Space ACL.
  func createInitialKey(circle: CircleSummary, memberDIDs: [DID]) async throws -> CircleKeyWrapOutcome {
    try await serialized {
      try await self.writeNewVersion(circle: circle, memberDIDs: memberDIDs, version: 1, reason: "created")
    }
  }

  /// Writes `vN+1` wrapped to the current Space roster (read under the
  /// manager's queue), after syncing versions other owner devices wrote.
  func rotate(circle: CircleSummary, reason: String) async throws -> CircleKeyWrapOutcome {
    try await serialized {
      let remoteLatest = try await self.syncRemote(circle: circle, full: false)
      let roster = try await self.currentRoster(circle)
      return try await self.rotateUnlocked(circle: circle, memberDIDs: roster, reason: reason, remoteLatest: remoteLatest)
    }
  }

  /// D8. `historyVisible`: rewrite the existing key records (same rkeys) for the
  /// newest `maxRewrapVersions` versions no older than `maxRewrapAge`, newest
  /// first, wrapped to the current Space roster (read under the manager's
  /// queue; the newcomer must already be on the ACL). Otherwise rotate with
  /// reason `memberAdded`. Remote versions are synced first, so versions
  /// another owner device wrote are included. Prefer `addMember`, which also
  /// orders the ACL grant and records the per-member history policy.
  func rewrapForAddedMember(circle: CircleSummary, historyVisible: Bool) async throws {
    try await serialized {
      let remoteLatest = try await self.syncRemote(circle: circle, full: false)
      let roster = try await self.currentRoster(circle)
      if historyVisible {
        try await self.rewrapHistoryUnlocked(circle: circle, memberDIDs: roster)
      } else {
        _ = try await self.rotateUnlocked(
          circle: circle, memberDIDs: roster, reason: "memberAdded", remoteLatest: remoteLatest
        )
      }
    }
  }

  /// Adds `did` to an encrypted Circle. The roster is read under the manager's
  /// queue.
  /// - History visible (spec §6 rule 2): grant the ACL, then re-wrap the bounded
  ///   history set. A failed re-wrap queues the member (`historyRewrapPending`)
  ///   so the retry re-wraps the same bounded set.
  /// - History hidden (rule 3): rotate to `vN+1` wrapped to roster + `did`
  ///   FIRST, then grant the ACL. A failed grant queues `__aclAdd__:<did>`; the
  ///   retry re-attempts the grant only. `vN` is never wrapped to the newcomer.
  func addMember(circle: CircleSummary, did: DID, historyVisible: Bool) async throws {
    try await serialized {
      try await self.addMemberUnlocked(circle: circle, did: did, historyVisible: historyVisible)
    }
  }

  /// Removes `did` (D14). `__acl__:<did>` is recorded (`aclRemovePending`)
  /// BEFORE anything else, so from that moment the member is excluded from
  /// every wrap, even across a crash. Then: rotate to `vN+1` wrapped to the
  /// remaining roster (read under the manager's queue), mark the entry
  /// `aclRemovePending:rotated`, remove from the Space ACL, clear the entry.
  /// A retry (`retryPendingRewraps` or a repeated call) rotates first if the
  /// entry is not yet `:rotated`, otherwise retries only the ACL removal.
  func removeMember(circle: CircleSummary, did: DID) async throws {
    try await serialized { try await self.removeMemberUnlocked(circle: circle, did: did) }
  }

  /// Fetches every key record, stores each newly openable version, and
  /// re-adopts the remote key for a version whose record CID differs from the
  /// one this device wrote or adopted. Returns the latest version stored
  /// locally afterwards (nil if none can be opened).
  func refreshKeys(circle: CircleSummary) async throws -> UInt64? {
    try await serialized {
      _ = try await self.syncRemote(circle: circle, full: true)
      return try await self.store.latestVersion(spaceURI: circle.uri.uriString())
    }
  }

  /// D13 / spec §4.4 ("refreshes it before every post"), for sealing a post:
  /// before EVERY encrypted publish, versions newer than the held latest are
  /// fetched (`getKeys(sinceVersion: held)`, paged; usually one small request
  /// with no rows) and stored, and the server's `getKeys.latestKeyVersion` is
  /// the bar. The summary's `latestKeyVersion` is never trusted as "nothing
  /// newer". Returns the newest held version. A newer version this device
  /// cannot open, or no key at all, is `encryptionUnavailable`: a post is
  /// never sealed under an older version than the latest known.
  func keyForPosting(circle: CircleSummary) async throws -> (version: UInt64, key: Data) {
    try await serialized {
      _ = try Self.trustedOwner(circle)
      let serverLatest = try await self.syncRemote(circle: circle, full: false)
      guard let current = try await self.currentKey(circle: circle) else {
        throw CircleError.encryptionUnavailable
      }
      guard serverLatest <= 0 || UInt64(serverLatest) <= current.version else {
        throw CircleError.encryptionUnavailable
      }
      return current
    }
  }

  func currentKey(circle: CircleSummary) async throws -> (version: UInt64, key: Data)? {
    let space = circle.uri.uriString()
    guard let version = try await store.latestVersion(spaceURI: space),
          let key = try await store.key(spaceURI: space, keyVersion: version)
    else { return nil }
    return (version: version, key: key)
  }

  /// The stored key for `version`, or nil when this device does not hold it.
  /// A read: not serialized behind key writes (like `currentKey`).
  func key(circle: CircleSummary, version: UInt64) async throws -> Data? {
    try await store.key(spaceURI: circle.uri.uriString(), keyVersion: version)
  }

  /// The newest version stored on this device, or nil when none.
  func latestLocalVersion(circle: CircleSummary) async throws -> UInt64? {
    try await store.latestVersion(spaceURI: circle.uri.uriString())
  }

  /// The oldest key version this device holds for `circle` (I12: a post
  /// sealed under an older one predates this member's access).
  func earliestLocalVersion(circle: CircleSummary) async throws -> UInt64? {
    try await store.allVersions(spaceURI: circle.uri.uriString()).first
  }

  /// The persisted pending list for `circle`, raw (`__acl__:`/`__aclAdd__:`
  /// prefixes and markers included). A read: not serialized behind key writes.
  func pendingRewraps(circle: CircleSummary) async throws -> [(did: String, reason: String)] {
    try await store.pendingRewraps(spaceURI: circle.uri.uriString())
  }

  /// Records an upgrade from `old` to `new` as incomplete: the new Space gets
  /// `__migration__` (`migrationIncomplete`) and the old Space a pointer to it.
  /// Every `__`-prefixed entry is skipped by the re-wrap passes.
  func markMigrationIncomplete(from old: CircleSummary, to new: CircleSummary) async throws {
    try await store.setPendingRewrap(
      spaceURI: new.uri.uriString(), did: Self.migrationMarker, reason: Self.migrationIncompleteReason
    )
    try await store.setPendingRewrap(
      spaceURI: old.uri.uriString(), did: Self.migrationTargetMarker, reason: new.uri.uriString()
    )
  }

  /// Persists the upgrade plan of `new`: the DIDs `v1` is wrapped to and the
  /// next unfinished step. Written with the marker, before `v1` is wrapped.
  func setMigrationPlan(circle new: CircleSummary, eligible: [DID], step: Int) async throws {
    try await store.setMigrationPlan(spaceURI: new.uri.uriString(), eligible: eligible.map { $0.didString() }, step: step)
  }

  func migrationPlan(circle new: CircleSummary) async throws -> (eligible: [DID], step: Int)? {
    guard let plan = try await store.migrationPlan(spaceURI: new.uri.uriString()) else { return nil }
    return (eligible: try plan.eligible.map { try DID(didString: $0) }, step: plan.step)
  }

  /// Upgrade step 3 for one member already wrapped in `v1`: `__aclAdd__:<did>`
  /// is recorded before the grant, so a failure leaves a badge and a
  /// grant-only retry, and the member is never on the ACL without a wrap.
  func grantWrappedMember(circle: CircleSummary, did: DID) async throws {
    try await serialized {
      let space = circle.uri.uriString()
      let entry = Self.aclAddPrefix + did.didString()
      try await self.store.setPendingRewrap(spaceURI: space, did: entry, reason: Self.aclAddReason)
      try await self.transport.addMember(space: circle.uri, did: did)
      await self.clearQuietly(space: space, entry: entry)
    }
  }

  /// Clears both upgrade markers and the plan once the old Space carries `migratedTo`.
  func clearMigrationMarkers(from old: CircleSummary, to new: CircleSummary) async throws {
    try await store.clearMigrationPlan(spaceURI: new.uri.uriString())
    try await store.clearPendingRewrap(spaceURI: new.uri.uriString(), did: Self.migrationMarker)
    try await store.clearPendingRewrap(spaceURI: old.uri.uriString(), did: Self.migrationTargetMarker)
  }

  /// The URI of the new Space of an unfinished upgrade from `old`, if any.
  /// One recorded during the Spaces alpha is returned in the `at:space/` form.
  func pendingMigrationTarget(from old: CircleSummary) async throws -> String? {
    try await store.pendingRewraps(spaceURI: old.uri.uriString())
      .first { $0.did == Self.migrationTargetMarker }
      .map { LegacySpaceURI.normalized($0.reason) }
  }

  /// D14/D15 retry (roster read under the manager's queue). Completes queued
  /// removals (rotating first if their rotation never landed) and grants
  /// (grant only, never a re-wrap), drops pending members no longer in the
  /// roster, and re-wraps the rest: the bounded history set if any entry needs
  /// older versions, otherwise the current version (`memberEpochRotated`).
  func retryPendingRewraps(circle: CircleSummary) async throws {
    try await serialized { try await self.retryPendingUnlocked(circle: circle) }
  }

  /// Spec §6 rules 5–6 (owner only; call on launch). Remote versions are synced
  /// first.
  /// - Rule 5: re-wrap the current version (reason `ownerEpochRotated`) when the
  ///   fresh record's `sender.senderEpochHead` differs from the stored one.
  /// - Rule 6: the FFI does not expose member epoch heads, so a member's epoch
  ///   rotation cannot be observed directly. Instead the current version is
  ///   re-wrapped to the whole roster (reason `memberEpochRotated`) whenever the
  ///   last current-version wrap is older than `weeklyRewrapInterval` (7 days),
  ///   which bounds how long a member who rotated stays unable to open new
  ///   posts. Members a wrap excluded are additionally retried through the
  ///   pending list.
  ///
  /// The roster is read under the manager's queue, so a stale caller roster
  /// can never re-wrap a member whose removal is under way or completed.
  func reconcileEpochs(circle: CircleSummary) async throws {
    try await serialized {
      _ = try await self.syncRemote(circle: circle, full: false)
      try await self.reconcileUnlocked(circle: circle)
    }
  }

  // MARK: - Serialization

  private func serialized<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let previous = tail
    let task = Task<T, Error> {
      await previous?.value
      return try await operation()
    }
    tail = Task { _ = try? await task.value }
    return try await task.value
  }

  // MARK: - Member flows (call only through `serialized`)

  private func addMemberUnlocked(circle: CircleSummary, did: DID, historyVisible: Bool) async throws {
    let space = circle.uri.uriString()
    let pending = try await pendingSets(space)
    guard !pending.aclRemove.contains(did.didString()) else {
      throw CircleError.invalidParameter("This member's removal is still finishing. Try again later.")
    }
    let remoteLatest = try await syncRemote(circle: circle, full: false)
    let aclRoster = try await transport.listMembers(space: circle.uri).map(\.did)
    let inACL = aclRoster.contains(did)
    let addEntry = Self.aclAddPrefix + did.didString()
    if pending.aclAdd.contains(did.didString()) {
      // A hidden-history add already rotated for this member; finish the grant only.
      if !inACL { try await transport.addMember(space: circle.uri, did: did) }
      await clearQuietly(space: space, entry: addEntry)
      return
    }
    if inACL { return }
    let members = aclRoster + [did]

    if historyVisible {
      try await store.setJoinedAtVersion(spaceURI: space, did: did.didString(), version: 0)
      try await transport.addMember(space: circle.uri, did: did)
      do {
        try await rewrapHistoryUnlocked(circle: circle, memberDIDs: members)
      } catch {
        try await queue(
          space: space, entry: did.didString(), reason: Self.historyPendingPrefix + "rewrap failed", after: error
        )
        throw error
      }
    } else {
      // Per-member history policy: the newcomer may receive only the rotated
      // version and later ones. Recorded before the write, so a crash cannot
      // leave them eligible for older versions.
      let next = try await nextVersion(space: space, remoteLatest: remoteLatest)
      try await store.setJoinedAtVersion(spaceURI: space, did: did.didString(), version: next)
      _ = try await writeNewVersion(circle: circle, memberDIDs: members, version: next, reason: "memberAdded")
      // The newcomer is in vN+1. Record the grant as pending before attempting
      // it, so a failure (or a crash) leaves a retry that grants only, and every
      // rewrite of the current version keeps the newcomer.
      try await store.setPendingRewrap(spaceURI: space, did: addEntry, reason: Self.aclAddReason)
      await pushOwnerStateIfAvailable(circle: circle)
      try await transport.addMember(space: circle.uri, did: did)
      await clearQuietly(space: space, entry: addEntry)
      await pushOwnerStateIfAvailable(circle: circle)
    }
  }

  private func removeMemberUnlocked(circle: CircleSummary, did: DID) async throws {
    let space = circle.uri.uriString()
    let entry = Self.aclRemovePrefix + did.didString()
    let existing = try await store.pendingRewraps(spaceURI: space).first { $0.did == entry }?.reason
    if existing != Self.aclRemoveRotatedReason {
      // From here on `did` is excluded from every wrap (effectiveRoster).
      try await store.setPendingRewrap(spaceURI: space, did: entry, reason: Self.aclRemoveReason)
      try await store.clearPendingRewrap(spaceURI: space, did: Self.aclAddPrefix + did.didString())
      try await store.clearPendingRewrap(spaceURI: space, did: did.didString())
      await pushOwnerStateIfAvailable(circle: circle)
      let remoteLatest = try await syncRemote(circle: circle, full: false)
      let remaining = try await currentRoster(circle).filter { $0 != did }
      _ = try await rotateUnlocked(circle: circle, memberDIDs: remaining, reason: "memberRemoved", remoteLatest: remoteLatest)
      try await store.setPendingRewrap(spaceURI: space, did: entry, reason: Self.aclRemoveRotatedReason)
      await pushOwnerStateIfAvailable(circle: circle)
    }
    try await transport.removeMember(space: circle.uri, did: did)
    await clearQuietly(space: space, entry: entry)
    _ = try? await ownerStateSync?.clearAclTombstone(
      circleId: circle.circleId.description,
      memberDid: did.didString()
    )
    do {
      try await store.setJoinedAtVersion(spaceURI: space, did: did.didString(), version: 0)
    } catch {
      logger.error("Circles: could not clear a removed member's history policy: \(error.localizedDescription)")
    }
    await pushOwnerStateIfAvailable(circle: circle)
  }

  // MARK: - Key operations (call only through `serialized`)

  private func rotateUnlocked(
    circle: CircleSummary, memberDIDs: [DID], reason: String, remoteLatest: Int
  ) async throws -> CircleKeyWrapOutcome {
    let next = try await nextVersion(space: circle.uri.uriString(), remoteLatest: remoteLatest)
    return try await writeNewVersion(circle: circle, memberDIDs: memberDIDs, version: next, reason: reason)
  }

  /// Never reuse a version another device already wrote (even one this
  /// account cannot open): the server's latest wins.
  private func nextVersion(space: String, remoteLatest: Int) async throws -> UInt64 {
    let local = try await store.latestVersion(spaceURI: space) ?? 0
    return max(local, UInt64(max(remoteLatest, 0))) + 1
  }

  /// The Space ACL roster, read inside the serialized section. Every wrap
  /// still passes it through `effectiveRoster`.
  private func currentRoster(_ circle: CircleSummary) async throws -> [DID] {
    try await transport.listMembers(space: circle.uri).map(\.did)
  }

  private func writeNewVersion(
    circle: CircleSummary, memberDIDs: [DID], version: UInt64, reason: String
  ) async throws -> CircleKeyWrapOutcome {
    let space = circle.uri.uriString()
    let key = try await crypto.generateCircleKey()
    let createdAt = Date()
    let (outcome, roster) = try await wrap(
      circle: circle, requested: memberDIDs, version: version, key: key, createdAt: createdAt, reason: reason
    )
    try await put(circle: circle, version: version, outcome: outcome)
    // Collision guard: the record at this version must be the one just written.
    let cid = try await readBack(circle: circle, version: version, outcome: outcome)
    // Only now does the version become current (D14).
    try await store.store(spaceURI: space, keyVersion: version, circleKey: key, createdAt: createdAt, reason: reason)
    if let cid { try await store.setRecordCID(spaceURI: space, keyVersion: version, cid: cid) }
    try await recordOutcome(circle: circle, version: version, roster: roster, outcome: outcome, history: false)
    return outcome
  }

  private func rewrapHistoryUnlocked(circle: CircleSummary, memberDIDs: [DID]) async throws {
    let space = circle.uri.uriString()
    let oldest = Date().addingTimeInterval(-CircleConfiguration.maxRewrapAge)
    let versions = try await store.allVersions(spaceURI: space)
      .sorted(by: >)
      .prefix(CircleConfiguration.maxRewrapVersions)
    var remoteMeta: [UInt64: (createdAt: Date, reason: String)]?
    var wrapped: Set<String> = []
    var excludedAny: Set<String> = []
    for version in versions {
      guard let key = try await store.key(spaceURI: space, keyVersion: version) else { continue }
      var meta = try await store.versionMeta(spaceURI: space, keyVersion: version)
      if meta == nil {
        if remoteMeta == nil { remoteMeta = try await fetchRemoteMeta(circle: circle) }
        meta = remoteMeta?[version]
      }
      guard let meta, meta.createdAt >= oldest else { continue }
      let (outcome, roster) = try await wrap(
        circle: circle, requested: memberDIDs, version: version, key: key,
        createdAt: meta.createdAt, reason: meta.reason
      )
      try await put(circle: circle, version: version, outcome: outcome)
      try await recordOutcome(circle: circle, version: version, roster: roster, outcome: outcome, history: true)
      wrapped.formUnion(roster.map { $0.didString() })
      excludedAny.formUnion(outcome.excluded.map(\.did))
    }
    // Every bounded version succeeded: only now is a history need satisfied.
    // (A throw above leaves history-pending entries in place for the retry.)
    for entry in try await store.pendingRewraps(spaceURI: space)
    where entry.reason.hasPrefix(Self.historyPendingPrefix) && wrapped.contains(entry.did) && !excludedAny.contains(entry.did) {
      try await store.clearPendingRewrap(spaceURI: space, did: entry.did)
    }
  }

  private func retryPendingUnlocked(circle: CircleSummary, aclOps: Bool = true, rewrapMembers: Bool = true) async throws {
    let space = circle.uri.uriString()
    for entry in try await store.pendingRewraps(spaceURI: space) where aclOps {
      if entry.did.hasPrefix(Self.aclRemovePrefix) {
        let did = try? DID(didString: String(entry.did.dropFirst(Self.aclRemovePrefix.count)))
        guard let did else {
          try await store.clearPendingRewrap(spaceURI: space, did: entry.did)
          continue
        }
        do {
          // Rotates first unless the entry says the rotation already landed.
          try await removeMemberUnlocked(circle: circle, did: did)
        } catch {
          // Kept for the next launch; the member stays excluded from every wrap.
          logger.info("Circles: pending removal still failing: \(error.localizedDescription)")
        }
      } else if entry.did.hasPrefix(Self.aclAddPrefix) {
        let did = try? DID(didString: String(entry.did.dropFirst(Self.aclAddPrefix.count)))
        guard let did else {
          try await store.clearPendingRewrap(spaceURI: space, did: entry.did)
          continue
        }
        do {
          try await transport.addMember(space: circle.uri, did: did)
          await clearQuietly(space: space, entry: entry.did)
        } catch {
          logger.info("Circles: pending ACL grant still failing")
        }
      }
    }
    guard rewrapMembers else { return }
    let aclRoster = try await currentRoster(circle)
    let roster = Set(try await effectiveRoster(space: space, requested: aclRoster).map { $0.didString() })
    var history = false
    var anyPending = false
    for entry in try await store.pendingRewraps(spaceURI: space) where !entry.did.hasPrefix("__") {
      if roster.contains(entry.did) {
        anyPending = true
        if entry.reason.hasPrefix(Self.historyPendingPrefix) { history = true }
      } else {
        try await store.clearPendingRewrap(spaceURI: space, did: entry.did)
      }
    }
    guard anyPending else { return }
    if history {
      try await rewrapHistoryUnlocked(circle: circle, memberDIDs: aclRoster)
    } else {
      try await rewrapCurrent(circle: circle, memberDIDs: aclRoster, reason: "memberEpochRotated")
    }
  }

  private func reconcileUnlocked(circle: CircleSummary) async throws {
    // The Space authority, never the summary's claim, says who owns it.
    guard try Self.trustedOwner(circle) == ownerDID else { return }
    // Complete queued removals first, so their members are off the roster (or
    // excluded) before anything is wrapped below.
    try await retryPendingUnlocked(circle: circle, rewrapMembers: false)
    let space = circle.uri.uriString()
    let memberDIDs = try await currentRoster(circle)
    var rewrote = false
    if let version = try await store.latestVersion(spaceURI: space),
       let key = try await store.key(spaceURI: space, keyVersion: version),
       let meta = try await store.versionMeta(spaceURI: space, keyVersion: version) {
      if let storedHead = try await store.senderEpochHead(spaceURI: space, keyVersion: version) {
        let (fresh, roster) = try await wrap(
          circle: circle, requested: memberDIDs, version: version, key: key,
          createdAt: meta.createdAt, reason: "ownerEpochRotated"
        )
        if let freshHead = Self.senderEpochHead(fromRecordJSON: fresh.recordJSON), freshHead != storedHead {
          try await put(circle: circle, version: version, outcome: fresh)
          try await store.store(
            spaceURI: space, keyVersion: version, circleKey: key, createdAt: meta.createdAt, reason: "ownerEpochRotated"
          )
          try await recordOutcome(circle: circle, version: version, roster: roster, outcome: fresh, history: false)
          rewrote = true
        }
      } else {
        logger.warning("Circles: no stored owner epoch head for the current key version; skipping rule 5 check")
      }
      if !rewrote {
        let last = try await store.lastRewrapAt(spaceURI: space)
        if last.map({ Date().timeIntervalSince($0) >= Self.weeklyRewrapInterval }) ?? true {
          try await rewrapCurrent(circle: circle, memberDIDs: memberDIDs, reason: "memberEpochRotated")
          rewrote = true
        }
      }
    }
    // A rewrite just reached every member it could; members it excluded stay
    // pending for the next run rather than being re-wrapped twice.
    if !rewrote { try await retryPendingUnlocked(circle: circle, aclOps: false, rewrapMembers: true) }
  }

  // MARK: - Helpers

  /// Re-wraps the current version to `memberDIDs`, keeping its `createdAt`.
  private func rewrapCurrent(circle: CircleSummary, memberDIDs: [DID], reason: String) async throws {
    let space = circle.uri.uriString()
    guard let version = try await store.latestVersion(spaceURI: space),
          let key = try await store.key(spaceURI: space, keyVersion: version),
          let meta = try await store.versionMeta(spaceURI: space, keyVersion: version)
    else { return }
    let (outcome, roster) = try await wrap(
      circle: circle, requested: memberDIDs, version: version, key: key, createdAt: meta.createdAt, reason: reason
    )
    try await put(circle: circle, version: version, outcome: outcome)
    try await store.store(spaceURI: space, keyVersion: version, circleKey: key, createdAt: meta.createdAt, reason: reason)
    try await recordOutcome(circle: circle, version: version, roster: roster, outcome: outcome, history: false)
  }

  private struct PendingSets {
    var aclRemove: Set<String> = []
    var aclAdd: Set<String> = []
  }

  private func pendingSets(_ space: String) async throws -> PendingSets {
    var sets = PendingSets()
    for entry in try await store.pendingRewraps(spaceURI: space) {
      if entry.did.hasPrefix(Self.aclRemovePrefix) {
        sets.aclRemove.insert(String(entry.did.dropFirst(Self.aclRemovePrefix.count)))
      } else if entry.did.hasPrefix(Self.aclAddPrefix) {
        sets.aclAdd.insert(String(entry.did.dropFirst(Self.aclAddPrefix.count)))
      }
    }
    return sets
  }

  /// THE wrap-roster filter: `requested` plus members whose ACL grant is
  /// pending, minus members whose ACL removal is pending. Order-preserving,
  /// deduplicated.
  /// Pending grants come only from history-hidden adds, so they are added for
  /// the current (or a new) version only, never for older versions.
  ///
  /// `version` applies the per-member history policy (§7): a member is
  /// included only if `version >= joinedAtVersion(member)` (0 when unset).
  private func effectiveRoster(
    space: String, requested: [DID], includePendingAdds: Bool = true, version: UInt64? = nil
  ) async throws -> [DID] {
    let pending = try await pendingSets(space)
    let joined = version == nil ? [:] : try await store.joinedAtVersions(spaceURI: space)
    var seen: Set<String> = []
    var roster: [DID] = []
    let added = includePendingAdds ? try pending.aclAdd.sorted().map { try DID(didString: $0) } : []
    for did in requested + added where !pending.aclRemove.contains(did.didString()) {
      if let version, version < joined[did.didString(), default: 0] { continue }
      if seen.insert(did.didString()).inserted { roster.append(did) }
    }
    return roster
  }

  private func wrap(
    circle: CircleSummary, requested: [DID], version: UInt64, key: Data, createdAt: Date, reason: String
  ) async throws -> (CircleKeyWrapOutcome, [DID]) {
    let space = circle.uri.uriString()
    let latest = try await store.latestVersion(spaceURI: space) ?? 0
    let roster = try await effectiveRoster(
      space: space, requested: requested, includePendingAdds: version >= latest, version: version
    )
    let outcome = try await crypto.wrapCircleKey(
      circleID: circle.circleId.description,
      keyVersion: version,
      spaceURI: circle.uri.uriString(),
      reason: reason,
      memberDIDs: roster.map { $0.didString() },
      circleKey: key,
      createdAt: createdAt
    )
    return (outcome, roster)
  }

  private func put(circle: CircleSummary, version: UInt64, outcome: CircleKeyWrapOutcome) async throws {
    // One record per version, always at the canonical rkey (spec §4.2, D8).
    guard outcome.rkey == Self.rkey(for: version) else { throw CircleError.invalidResponse }
    _ = try await transport.putKeyRecord(space: circle.uri, rkey: outcome.rkey, recordJSON: outcome.recordJSON)
  }

  /// Reads the record at `version` back. Returns its CID when it matches what
  /// was written, nil when the AppView has not indexed it yet, and throws
  /// `keyVersionConflict` when a different record occupies the version.
  private func readBack(circle: CircleSummary, version: UInt64, outcome: CircleKeyWrapOutcome) async throws -> String? {
    let output = try await transport.getKeys(space: circle.uri, sinceVersion: Int(version) - 1)
    guard let entry = output.entries.first(where: { $0.keyVersion == Int(version) }) else { return nil }
    // Raw to raw: the served bytes against the FFI's bytes, never typed
    // re-encodings (which would hide a dropped or injected field).
    guard Self.sameJSON(entry.recordJSON, outcome.recordJSON) else {
      logger.error("Circles: key record read-back mismatch; local key not adopted")
      throw CircleError.keyVersionConflict
    }
    return entry.cid.string
  }

  /// Persists the record's owner epoch head and updates the pending list.
  /// Excluded members are queued (D15). A pending entry is cleared only by a
  /// successful wrap of the CURRENT version; during a history pass an older
  /// version's exclusion re-queues the member with `historyRewrapPending`.
  private func recordOutcome(
    circle: CircleSummary, version: UInt64, roster: [DID], outcome: CircleKeyWrapOutcome, history: Bool
  ) async throws {
    let space = circle.uri.uriString()
    if let head = Self.senderEpochHead(fromRecordJSON: outcome.recordJSON) {
      try await store.setSenderEpochHead(spaceURI: space, keyVersion: version, head: head)
    }
    let isCurrent = try await store.latestVersion(spaceURI: space) == version
    let excluded = Dictionary(outcome.excluded.map { ($0.did, $0.reason) }, uniquingKeysWith: { first, _ in first })
    let existing = Dictionary(
      try await store.pendingRewraps(spaceURI: space).map { ($0.did, $0.reason) }, uniquingKeysWith: { first, _ in first }
    )
    for member in roster.map({ $0.didString() }) {
      if let reason = excluded[member] {
        let queued = (isCurrent && !history) ? reason : Self.historyPendingPrefix + reason
        try await store.setPendingRewrap(spaceURI: space, did: member, reason: queued)
      } else if isCurrent, let current = existing[member], !current.hasPrefix(Self.historyPendingPrefix) {
        // History needs are cleared only after a complete history pass.
        try await store.clearPendingRewrap(spaceURI: space, did: member)
      }
    }
    if isCurrent { try await store.setLastRewrapAt(spaceURI: space, date: Date()) }
    await pushOwnerStateIfAvailable(circle: circle)
  }

  private func pullOwnerStateIfAvailable(circle: CircleSummary) async -> Int {
    guard let ownerStateSync,
          let owner = try? Self.trustedOwner(circle),
          owner == ownerDID
    else {
      return 0
    }
    guard let dto = try? await ownerStateSync.getOwnerState(circleId: circle.circleId.description) else {
      return 0
    }
    let space = circle.uri.uriString()
    if let data = dto.joinedAtVersionJson.data(using: .utf8),
       let remoteJoined = try? JSONDecoder().decode([String: UInt64].self, from: data)
    {
      let localJoined = (try? await store.joinedAtVersions(spaceURI: space)) ?? [:]
      for (did, remoteVersion) in remoteJoined where remoteVersion > localJoined[did, default: 0] {
        try? await store.setJoinedAtVersion(spaceURI: space, did: did, version: remoteVersion)
      }
    }
    if let data = dto.pendingOpsJson.data(using: .utf8),
       let remotePending = try? JSONDecoder().decode([String: String].self, from: data)
    {
      let localPending = Dictionary(
        ((try? await store.pendingRewraps(spaceURI: space)) ?? []).map { ($0.did, $0.reason) },
        uniquingKeysWith: { _, last in last }
      )
      for (did, reason) in remotePending {
        if localPending[did] == nil
          || (reason == Self.aclRemoveRotatedReason && localPending[did] == Self.aclRemoveReason)
        {
          try? await store.setPendingRewrap(spaceURI: space, did: did, reason: reason)
        }
      }
    }
    return Int(clamping: dto.currentKeyVersion)
  }

  private func pushOwnerStateIfAvailable(circle: CircleSummary) async {
    guard let ownerStateSync,
          let owner = try? Self.trustedOwner(circle),
          owner == ownerDID
    else {
      return
    }
    let space = circle.uri.uriString()
    let currentKeyVersion = (try? await store.latestVersion(spaceURI: space)) ?? 0
    let joined = (try? await store.joinedAtVersions(spaceURI: space)) ?? [:]
    let pendingEntries = (try? await store.pendingRewraps(spaceURI: space)) ?? []
    let pendingMap = Dictionary(
      pendingEntries.map { ($0.did, $0.reason) },
      uniquingKeysWith: { _, last in last }
    )
    guard let joinedData = try? JSONEncoder().encode(joined),
          let joinedJSON = String(data: joinedData, encoding: .utf8),
          let pendingData = try? JSONEncoder().encode(pendingMap),
          let pendingJSON = String(data: pendingData, encoding: .utf8)
    else {
      return
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let dto = CircleOwnerStateDto(
      circleId: circle.circleId.description,
      spaceUri: space,
      currentKeyVersion: currentKeyVersion,
      joinedAtVersionJson: joinedJSON,
      pendingOpsJson: pendingJSON,
      updatedAt: formatter.string(from: Date()),
      recordCid: nil
    )
    _ = try? await ownerStateSync.mergeOwnerState(dto)
  }

  /// Queues a pending entry after a failed network step. A Keychain failure
  /// here must not hide the original error: both are reported, the original first.
  private func queue(space: String, entry: String, reason: String, after original: Error) async throws {
    do {
      try await store.setPendingRewrap(spaceURI: space, did: entry, reason: reason)
    } catch {
      throw CircleError.spaceWriteRejected(
        "\(original.localizedDescription) (could not record the retry: \(error.localizedDescription))"
      )
    }
  }

  /// Clears an idempotent pending entry after its operation succeeded. A failure
  /// is logged and the entry kept; the retry repeats a no-op.
  private func clearQuietly(space: String, entry: String) async {
    do {
      try await store.clearPendingRewrap(spaceURI: space, did: entry)
    } catch {
      logger.error("Circles: could not clear a completed pending entry: \(error.localizedDescription)")
    }
  }

  /// Most `getKeys` pages one sync reads (64 rows each on the AppView).
  static let maxKeyPages = 32

  /// The Circle's owner: the authority of its Space URI. A summary whose
  /// `owner` claims anyone else is refused (`ownerMismatch`) before anything
  /// from it drives key trust.
  static func trustedOwner(_ circle: CircleSummary) throws -> DID {
    guard let authority = try? DID(didString: circle.uri.spaceDID), authority == circle.owner else {
      throw CircleError.ownerMismatch
    }
    return authority
  }

  /// Every key record newer than `sinceVersion`, paged with `sinceVersion` =
  /// the last version returned until the last one reaches the server's
  /// `latestKeyVersion` (at most `maxKeyPages` pages). `incomplete` when a
  /// page skipped rows or the cap was hit: the missing versions are retried by
  /// a later sync.
  private func fetchKeyRecords(
    circle: CircleSummary, sinceVersion: Int?
  ) async throws -> (entries: [CircleKeysResponse.Entry], latest: Int, incomplete: Bool) {
    var since = sinceVersion
    var entries: [CircleKeysResponse.Entry] = []
    var latest = 0
    var incomplete = false
    var reachedEnd = false
    for _ in 0..<Self.maxKeyPages {
      let page = try await transport.getKeys(space: circle.uri, sinceVersion: since)
      latest = max(latest, page.latestKeyVersion)
      if page.skipped > 0 { incomplete = true }
      entries.append(contentsOf: page.entries)
      let floor = since ?? 0
      guard let last = page.entries.map(\.keyVersion).max(),
            page.latestKeyVersion > last, last > floor
      else {
        reachedEnd = true
        break
      }
      since = last
    }
    if !reachedEnd { incomplete = true }
    return (entries, latest, incomplete)
  }

  /// Opens and stores remote versions. `full == false`: only versions newer
  /// than the latest local one. `full == true`: every version, re-adopting the
  /// remote key where the record CID differs from the stored one. Returns the
  /// server's latest key version.
  ///
  /// Trust: the owner is the Space authority (`trustedOwner`), and a key is
  /// stored only under the `keyVersion` (and for the `circleId`) read from the
  /// exact record bytes the FFI just accepted, never the AppView's index label.
  /// A record that fails to open or to match is skipped (and counted); it
  /// never blocks the versions after it.
  private func syncRemote(circle: CircleSummary, full: Bool) async throws -> Int {
    let owner = try Self.trustedOwner(circle)
    let remoteOwnerVersion = await pullOwnerStateIfAvailable(circle: circle)
    let space = circle.uri.uriString()
    let local = try await store.latestVersion(spaceURI: space)
    let fetched = try await fetchKeyRecords(circle: circle, sinceVersion: full ? nil : local.map { Int($0) })
    var trustFailures = 0
    for entry in fetched.entries where entry.keyVersion > 0 {
      let version = UInt64(entry.keyVersion)
      let held = try await store.key(spaceURI: space, keyVersion: version)
      if held != nil {
        guard full else { continue }
        if try await store.recordCID(spaceURI: space, keyVersion: version) == entry.cid.string { continue }
      }
      // The server's exact bytes: Swift never re-encodes a record for the FFI.
      let json = entry.recordJSON
      let opened: OpenedCircleKey
      do {
        guard let result = try await crypto.openCircleKey(
          recordJSON: json, spaceURI: space, ownerDID: owner.didString()
        ) else { continue }
        opened = result
      } catch {
        // I3: one bad record is skipped; a transient failure aborts the sync
        // (retried later, nothing memoized); an owner/Space mismatch the Rust
        // layer found is the Circle's problem, not the record's.
        switch CircleOpenFailure(error) {
        case .ownerMismatch:
          throw CircleError.ownerMismatch
        case .transient:
          logger.notice("Circles: key sync stopped by a transient failure (\(String(describing: type(of: error)), privacy: .public))")
          throw error
        case .untrusted:
          trustFailures += 1
          logger.warning("Circles: a key record's sender could not be verified; skipped, retried on a later sync")
          continue
        case .rejected:
          trustFailures += 1
          logger.notice("Circles: a key record failed to open (\(String(describing: type(of: error)), privacy: .public))")
          continue
        }
      }
      // C3: the version and Circle are the ones the wrap's AAD authenticated
      // (returned by the FFI), never the AppView's label or a re-parse.
      guard opened.keyVersion == version, opened.circleID == circle.circleId.description else {
        trustFailures += 1
        logger.error("Circles: a key record's authenticated version or Circle differs from its label; skipped")
        continue
      }
      let key = opened.circleKey
      if key != held {
        try await store.store(
          spaceURI: space, keyVersion: version, circleKey: key,
          createdAt: entry.record.createdAt.date, reason: entry.record.reason
        )
      }
      try await store.setRecordCID(spaceURI: space, keyVersion: version, cid: entry.cid.string)
      if let head = Self.senderEpochHead(fromRecordJSON: json) {
        try await store.setSenderEpochHead(spaceURI: space, keyVersion: version, head: head)
      }
    }
    if trustFailures > 0 {
      logger.notice("Circles: key sync skipped \(trustFailures, privacy: .public) record(s)")
    }
    if fetched.incomplete {
      logger.notice("Circles: key sync incomplete (skipped rows or page cap); retried on the next sync")
    }
    return max(fetched.latest, remoteOwnerVersion)
  }

  private func fetchRemoteMeta(circle: CircleSummary) async throws -> [UInt64: (createdAt: Date, reason: String)] {
    let fetched = try await fetchKeyRecords(circle: circle, sinceVersion: nil)
    var meta: [UInt64: (createdAt: Date, reason: String)] = [:]
    for entry in fetched.entries where entry.keyVersion > 0 {
      meta[UInt64(entry.keyVersion)] = (createdAt: entry.record.createdAt.date, reason: entry.record.reason)
    }
    return meta
  }

  /// `keyVersion` and `circleId` from a key record's exact JSON (the bytes the
  /// FFI authenticated; both are in the wrap AAD).
  static func recordHeader(fromRecordJSON json: String) -> (keyVersion: Int, circleId: String)? {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let version = object["keyVersion"] as? NSNumber,
      CFGetTypeID(version) == CFNumberGetTypeID(),
      let circleId = object["circleId"] as? String
    else { return nil }
    return (version.intValue, circleId)
  }

  static func rkey(for version: UInt64) -> String {
    let digits = String(version)
    return digits.count >= 6 ? digits : String(repeating: "0", count: 6 - digits.count) + digits
  }

  /// Whether two raw JSON texts hold the same value, compared as canonical
  /// bytes (members sorted at every level, insignificant whitespace dropped).
  /// Member order may differ (the AppView stores records as `jsonb`, which
  /// reorders members); every member, nested ones included, must match, and
  /// values keep their JSON type: `true` is not `1` (a decoded `NSNumber`
  /// comparison would call them equal).
  static func sameJSON(_ lhs: String, _ rhs: String) -> Bool {
    guard let left = canonicalJSON(lhs), let right = canonicalJSON(rhs) else { return false }
    return left == right
  }

  /// `json` re-serialized with sorted members; nil unless it is an object.
  /// Booleans serialize as `true`/`false` and numbers as numbers, so the
  /// canonical bytes differ whenever the JSON types differ.
  static func canonicalJSON(_ json: String) -> Data? {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)), object is NSDictionary else {
      return nil
    }
    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
  }

  /// `sender.senderEpochHead` (`{"$bytes": base64}`) from a key record's JSON.
  static func senderEpochHead(fromRecordJSON json: String) -> Data? {
    guard
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let sender = object["sender"] as? [String: Any],
      let head = sender["senderEpochHead"] as? [String: Any],
      let encoded = head["$bytes"] as? String
    else { return nil }
    return decodeBase64(encoded)
  }

  /// Accepts padded or unpadded base64 (Rust emits unpadded, Petrel padded).
  private static func decodeBase64(_ string: String) -> Data? {
    var padded = string.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    let remainder = padded.count % 4
    if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: padded)
  }
}
