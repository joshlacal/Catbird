import CatbirdMLSCore
import Foundation
import Observation

/// Row presentation state for encrypted chat capability in the contact picker.
enum ContactMLSAvailabilityRowState: Equatable, Sendable {
  case checking
  case resolved(MLSChatCapabilityStatus)
}

/// Coordinates per-contact encrypted chat capability checks without cross-batch clobbering,
/// head-of-line batch blocking, or caller search-cancellation stranding.
@MainActor
@Observable
final class ContactMLSAvailabilityCoordinator {
  private struct PendingItem {
    let did: String
    var forceRefresh: Bool
  }

  private struct ActiveLookup {
    let token: UUID
    let task: Task<Void, Never>
  }

  private(set) var availability: [String: MLSChatCapabilityStatus] = [:]
  private var checkingDIDs: Set<String> = []

  @ObservationIgnored private let maxConcurrentLookups: Int
  @ObservationIgnored private let checkCapability: (String, Bool) async -> MLSChatCapability
  @ObservationIgnored var onStatusChange: (@MainActor (String, MLSChatCapabilityStatus) -> Void)?

  @ObservationIgnored private var currentAccountDID: String?
  @ObservationIgnored private var epoch: UInt64 = 0
  @ObservationIgnored private var pendingQueue: [PendingItem] = []
  @ObservationIgnored private var activeLookups: [String: ActiveLookup] = [:]

  init(
    maxConcurrentLookups: Int = 6,
    checkCapability: @escaping (String, Bool) async -> MLSChatCapability = { did, forceRefresh in
      await MLSChatCapabilityResolver.shared.capability(for: did, forceRefresh: forceRefresh)
    },
    onStatusChange: (@MainActor (String, MLSChatCapabilityStatus) -> Void)? = nil
  ) {
    self.maxConcurrentLookups = max(1, maxConcurrentLookups)
    self.checkCapability = checkCapability
    self.onStatusChange = onStatusChange
  }

  func rowState(for did: String) -> ContactMLSAvailabilityRowState {
    if checkingDIDs.contains(did) {
      return .checking
    }
    if let status = availability[did] {
      return .resolved(status)
    }
    return .resolved(.unknown)
  }

  func requestCheck(for dids: [String], accountDID: String, prioritize: Bool = false) {
    syncAccount(accountDID)
    var seen = Set<String>()
    let uniqueDIDs = dids.filter { !$0.isEmpty && seen.insert($0).inserted }
    guard !uniqueDIDs.isEmpty else { return }

    var frontItems: [PendingItem] = []
    for did in uniqueDIDs {
      if let known = availability[did], known != .unknown {
        continue
      }
      if activeLookups[did] != nil {
        continue
      }
      if let existingIndex = pendingQueue.firstIndex(where: { $0.did == did }) {
        if prioritize {
          let existing = pendingQueue.remove(at: existingIndex)
          frontItems.append(existing)
        }
        continue
      }
      checkingDIDs.insert(did)
      let item = PendingItem(did: did, forceRefresh: false)
      if prioritize {
        frontItems.append(item)
      } else {
        pendingQueue.append(item)
      }
    }

    if !frontItems.isEmpty {
      pendingQueue.insert(contentsOf: frontItems, at: 0)
    }
    pumpQueue()
  }

  func retry(did: String, accountDID: String) {
    syncAccount(accountDID)
    guard !did.isEmpty else { return }
    activeLookups.removeValue(forKey: did)?.task.cancel()
    pendingQueue.removeAll { $0.did == did }
    checkingDIDs.insert(did)
    pendingQueue.insert(PendingItem(did: did, forceRefresh: true), at: 0)
    pumpQueue()
  }

  func cancelAll() {
    epoch &+= 1
    for lookup in activeLookups.values {
      lookup.task.cancel()
    }
    activeLookups.removeAll()
    pendingQueue.removeAll()
    checkingDIDs.removeAll()
  }

  func reset(accountDID: String) {
    cancelAll()
    currentAccountDID = accountDID
    availability.removeAll()
  }

  private func syncAccount(_ accountDID: String) {
    if let currentAccountDID, currentAccountDID != accountDID {
      reset(accountDID: accountDID)
    } else if currentAccountDID == nil {
      currentAccountDID = accountDID
    }
  }

  private func pumpQueue() {
    while activeLookups.count < maxConcurrentLookups, !pendingQueue.isEmpty {
      let item = pendingQueue.removeFirst()
      let did = item.did
      let forceRefresh = item.forceRefresh
      let token = UUID()
      let capturedEpoch = epoch
      let check = checkCapability

      let task = Task { @MainActor [weak self] in
        let capability = await check(did, forceRefresh)
        guard let self else { return }
        self.finishLookup(
          did: did,
          token: token,
          capturedEpoch: capturedEpoch,
          capability: capability
        )
      }
      activeLookups[did] = ActiveLookup(token: token, task: task)
    }
  }

  private func finishLookup(
    did: String,
    token: UUID,
    capturedEpoch: UInt64,
    capability: MLSChatCapability
  ) {
    guard capturedEpoch == epoch else { return }
    guard activeLookups[did]?.token == token else { return }

    activeLookups.removeValue(forKey: did)
    checkingDIDs.remove(did)

    let status: MLSChatCapabilityStatus
    switch capability {
    case .capable: status = .capable
    case .incapable: status = .incapable
    case .unknown: status = .unknown
    }
    availability[did] = status
    onStatusChange?(did, status)
    pumpQueue()
  }
}
