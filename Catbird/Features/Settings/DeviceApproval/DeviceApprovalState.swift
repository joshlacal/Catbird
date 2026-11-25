import Foundation

// MARK: - Device Approval State

/// Where this installation stands in encrypted-chat device approval, worked out from the
/// account's own device list (`blue.catbird.chat.getOwnDevices`).
///
/// The chat server enrolls every device after the first as `pending_approval`. A pending
/// device becomes active in one of two ways:
/// - an approved sibling approves it in Settings > Devices, or
/// - after a backup restore (passkey or recovery code), the pending device approves itself
///   once its pending notice is `selfApprovalHold` old and no approved sibling has been used
///   for `selfApprovalHold`. Servers that skip the hold when no approved sibling is left
///   approve it as soon as the restore publishes.
///
/// The evaluation is pure so that every screen (chat list, sign-out, Devices, backup restore)
/// tells the same story from the same rows.
enum DeviceApprovalState: Equatable, Sendable {
  /// This device is approved. `waiting` lists the account's other devices awaiting approval.
  /// `otherApprovedCount` counts approved siblings, so zero means this device is the only
  /// one that can approve the waiting devices.
  case approved(waiting: [DeviceApprovalPeer], otherApprovedCount: Int)
  /// This device waits for approval and an approved sibling was used recently enough to
  /// approve it. After a backup restore, servers that keep the hold approve this device at
  /// `selfApprovesAt`, which moves later if that sibling is used again.
  case askApprover(approvers: [DeviceApprovalPeer], selfApprovesAt: Date)
  /// This device waits for approval. Approved siblings exist, but none was used recently.
  /// After a backup restore this device approves itself at `selfApprovesAt`.
  case approversQuiet(approvers: [DeviceApprovalPeer], selfApprovesAt: Date)
  /// This device waits for approval and no approved device is left. A backup restore
  /// approves it. `holdEndsAt` is the latest moment that can take, on servers that keep the
  /// hold even when no approved device is left.
  case noApprover(holdEndsAt: Date)
  /// This device was removed from the account.
  case revoked

  /// The server's self-approval hold. `CHAT_PENDING_DEVICE_HOLD_HOURS` can lengthen the
  /// notice hold on a server but never shorten it below this.
  static let selfApprovalHold: TimeInterval = 72 * 3600

  /// True while this device cannot read or send encrypted chat yet.
  var isPending: Bool {
    switch self {
    case .askApprover, .approversQuiet, .noApprover: true
    case .approved, .revoked: false
    }
  }

  /// When this device approves itself after a backup restore, if the server keeps the hold.
  var selfApprovalDate: Date? {
    switch self {
    case .askApprover(_, let date), .approversQuiet(_, let date): date
    case .noApprover(let date): date
    case .approved, .revoked: nil
    }
  }

  /// True when this device is the only approved one and others wait on it, so signing out
  /// here would leave them with no approver.
  var signOutStrandsWaitingDevices: Bool {
    if case .approved(let waiting, let otherApproved) = self {
      return otherApproved == 0 && !waiting.isEmpty
    }
    return false
  }

  /// Works out the state for `currentDeviceId` from the account's own device rows.
  static func evaluate(
    currentDeviceId: String,
    rows: [OwnDeviceApprovalRow],
    now: Date = Date()
  ) -> DeviceApprovalState? {
    let currentKey = currentDeviceId.lowercased()
    guard let current = rows.first(where: { $0.deviceId.lowercased() == currentKey }) else {
      return nil
    }
    let siblings = rows.filter {
      $0.deviceId.lowercased() != currentKey && !$0.isFederatedGroupDevice
    }
    let approved = siblings.filter(\.isApproved)
    let waiting = siblings.filter(\.isPendingApproval)

    switch current.status {
    case .revoked:
      return .revoked
    case .active, .dormant:
      return .approved(
        waiting: waiting.map(DeviceApprovalPeer.init),
        otherApprovedCount: approved.count
      )
    case .pendingApproval:
      break
    }

    let hold = selfApprovalHold
    let noticeHoldEnds = (current.createdAt ?? now).addingTimeInterval(hold)
    guard !approved.isEmpty else {
      return .noApprover(holdEndsAt: noticeHoldEnds)
    }

    let approvers = approved
      .sorted { ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast) }
      .map(DeviceApprovalPeer.init)
    let latestApproverActivity = approved.compactMap(\.lastActiveAt).max()
    let activityHoldEnds = latestApproverActivity.map { $0.addingTimeInterval(hold) }
    let selfApprovesAt = max(noticeHoldEnds, activityHoldEnds ?? noticeHoldEnds)
    // The server vetoes self-approval while any approved sibling was active after now − hold.
    let anyApproverAwake = activityHoldEnds.map { $0 > now } ?? false
    if anyApproverAwake {
      return .askApprover(approvers: approvers, selfApprovesAt: selfApprovesAt)
    }
    return .approversQuiet(approvers: approvers, selfApprovesAt: selfApprovesAt)
  }
}

// MARK: - Peer

/// Another of the account's devices, as approval copy names it.
struct DeviceApprovalPeer: Equatable, Sendable, Identifiable {
  let deviceId: String
  /// A label that always reads as a name, for buttons and lists.
  let displayName: String
  /// The name the device registered with, or nil when it registered a generic one such as
  /// "Catbird", which reads as the app rather than a device.
  let name: String?
  let addedAt: Date?
  let lastActiveAt: Date?

  var id: String { deviceId }

  init(
    deviceId: String,
    displayName: String,
    name: String? = nil,
    addedAt: Date? = nil,
    lastActiveAt: Date?
  ) {
    self.deviceId = deviceId
    self.displayName = displayName
    self.name = name
    self.addedAt = addedAt
    self.lastActiveAt = lastActiveAt
  }

  init(_ row: OwnDeviceApprovalRow) {
    self.init(
      deviceId: row.deviceId,
      displayName: row.displayName,
      name: row.specificName,
      addedAt: row.createdAt,
      lastActiveAt: row.lastActiveAt
    )
  }
}

// MARK: - Own Device Row

/// One `ownDeviceView` row, reduced to the fields approval needs.
struct OwnDeviceApprovalRow: Equatable, Sendable {
  enum Status: String, Equatable, Sendable {
    case active
    case dormant
    case pendingApproval = "pending_approval"
    case revoked
  }

  let deviceId: String
  let deviceName: String?
  let status: Status
  let createdAt: Date?
  let lastActiveAt: Date?

  init(
    deviceId: String,
    deviceName: String? = nil,
    status: Status,
    createdAt: Date? = nil,
    lastActiveAt: Date? = nil
  ) {
    self.deviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.deviceName = trimmedName.isEmpty ? nil : String(trimmedName.prefix(128))
    self.status = status
    self.createdAt = createdAt
    self.lastActiveAt = lastActiveAt
  }

  /// Decodes the JSON form of a `deviceView`, so new or unknown fields never break it.
  init?(wireDeviceJSON: Data) {
    guard let wire = try? JSONDecoder().decode(WireDevice.self, from: wireDeviceJSON),
          let deviceId = wire.deviceId,
          !deviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let rawStatus = wire.status,
          let status = Status(rawValue: rawStatus)
    else {
      return nil
    }
    self.init(
      deviceId: deviceId,
      deviceName: wire.deviceName,
      status: status,
      createdAt: DeviceRowModel.parseISO8601(wire.createdAt),
      lastActiveAt: DeviceRowModel.parseISO8601(wire.lastActiveAt)
    )
  }

  var isApproved: Bool { status == .active || status == .dormant }
  var isPendingApproval: Bool { status == .pendingApproval }

  /// The server's own per-group delivery rows, which never approve anything.
  var isFederatedGroupDevice: Bool { deviceName == "federated-group-device" }

  /// The registered name, unless it is one every install sends, like "Catbird".
  var specificName: String? {
    guard let deviceName else { return nil }
    return Self.genericDeviceNames.contains(deviceName.lowercased()) ? nil : deviceName
  }

  /// "Mac mini", or for a generic name "Device added Nov 20", or "Device 1a2b3c4d".
  var displayName: String {
    if let specificName { return specificName }
    if let createdAt {
      var style = Date.FormatStyle().month(.abbreviated).day()
      style.locale = .current
      return "Device added \(createdAt.formatted(style))"
    }
    return "Device \(deviceId.prefix(8))"
  }

  /// Names that say which app enrolled a device but not which device it is. The chat
  /// engine enrolls with "Catbird" on every platform.
  static let genericDeviceNames: Set<String> = [
    "catbird", "catbird ios", "catbird web", "catbird device", "catmos", "device",
  ]

  private struct WireDevice: Decodable {
    let deviceId: String?
    let deviceName: String?
    let status: String?
    let createdAt: String?
    let lastActiveAt: String?
  }
}
