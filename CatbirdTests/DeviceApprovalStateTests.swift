import Foundation
import Testing
@testable import Catbird

// MARK: - Device Approval State

@Suite("Device approval state")
struct DeviceApprovalStateTests {
  private let now = Date(timeIntervalSince1970: 1_795_000_000)
  private let hold = DeviceApprovalState.selfApprovalHold
  private let me = "11111111-1111-4111-8111-111111111111"
  private let mac = "22222222-2222-4222-8222-222222222222"
  private let ipad = "33333333-3333-4333-8333-333333333333"

  private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

  @Test("An approved device with nothing waiting shows no card")
  func approvedAlone() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [OwnDeviceApprovalRow(deviceId: me, status: .active, createdAt: hoursAgo(500), lastActiveAt: hoursAgo(1))],
      now: now
    ))
    #expect(state == .approved(waiting: [], otherApprovedCount: 0))
    #expect(!state.signOutStrandsWaitingDevices)
    #expect(DeviceApprovalCopy.make(for: state, restoreQueued: false, now: now) == nil)
    #expect(AccountSecuritySettingsView.signOutMessage(for: state).contains("only approved device"))
  }

  @Test("The only approved device with a waiting sibling warns before sign-out")
  func soleApproverWithWaitingSibling() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: me, deviceName: "Mac", status: .active, createdAt: hoursAgo(500), lastActiveAt: hoursAgo(1)),
        OwnDeviceApprovalRow(deviceId: ipad, deviceName: "iPhone", status: .pendingApproval, createdAt: hoursAgo(2)),
      ],
      now: now
    ))
    #expect(state.signOutStrandsWaitingDevices)
    let copy = try #require(DeviceApprovalCopy.make(for: state, restoreQueued: false, now: now))
    #expect(copy.title == "iPhone is waiting for approval")
    #expect(copy.message.contains("only approved device"))
    guard case .approve(let peer) = copy.primary else {
      Issue.record("Expected an Approve action")
      return
    }
    #expect(peer.deviceId == ipad)
    #expect(AccountSecuritySettingsView.signOutMessage(for: state).contains("backup passkey"))
  }

  @Test("A second approved device means signing out strands nobody")
  func waitingSiblingWithAnotherApprover() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: me, status: .active, createdAt: hoursAgo(500), lastActiveAt: hoursAgo(1)),
        OwnDeviceApprovalRow(deviceId: mac, status: .dormant, createdAt: hoursAgo(600), lastActiveAt: hoursAgo(60)),
        OwnDeviceApprovalRow(deviceId: ipad, status: .pendingApproval, createdAt: hoursAgo(2)),
      ],
      now: now
    ))
    guard case .approved(let waiting, let otherApprovedCount) = state else {
      Issue.record("Expected approved, got \(state)")
      return
    }
    #expect(waiting.map(\.deviceId) == [ipad])
    #expect(waiting.first?.name == nil)
    #expect(waiting.first?.addedAt == hoursAgo(2))
    #expect(otherApprovedCount == 1)
    #expect(!state.signOutStrandsWaitingDevices)
  }

  @Test("A recently used sibling is asked to approve, and the passkey is the fallback")
  func askRecentApprover() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, deviceName: "Mac", status: .active, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(24)),
        OwnDeviceApprovalRow(deviceId: me, status: .pendingApproval, createdAt: hoursAgo(10)),
      ],
      now: now
    ))
    // The later of the notice hold (created 10h ago) and the sibling's quiet hold (24h ago).
    let expected = hoursAgo(10).addingTimeInterval(hold)
    guard case .askApprover(let approvers, let selfApprovesAt) = state else {
      Issue.record("Expected askApprover, got \(state)")
      return
    }
    #expect(approvers.map(\.deviceId) == [mac])
    #expect(selfApprovesAt == expected)
    let copy = try #require(DeviceApprovalCopy.make(for: state, restoreQueued: false, now: now))
    #expect(copy.title == "Restore your backup to use encrypted chat")
    #expect(copy.message.contains("from Mac in Settings > Devices"))
    #expect(copy.primary == .restoreBackup)
    #expect(copy.tone == .blocking)
  }

  @Test("The sibling's last use pushes the self-approval date past the notice hold")
  func siblingActivityExtendsHold() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, status: .active, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(2)),
        OwnDeviceApprovalRow(deviceId: me, status: .pendingApproval, createdAt: hoursAgo(70)),
      ],
      now: now
    ))
    #expect(state.selfApprovalDate == hoursAgo(2).addingTimeInterval(hold))
  }

  @Test("Quiet siblings mean a restore approves this device when the hold ends")
  func quietApprovers() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, deviceName: "Mac", status: .dormant, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(80)),
        OwnDeviceApprovalRow(deviceId: me, status: .pendingApproval, createdAt: hoursAgo(30)),
      ],
      now: now
    ))
    guard case .approversQuiet(_, let selfApprovesAt) = state else {
      Issue.record("Expected approversQuiet, got \(state)")
      return
    }
    #expect(selfApprovesAt == hoursAgo(30).addingTimeInterval(hold))

    let before = try #require(DeviceApprovalCopy.make(for: state, restoreQueued: false, now: now))
    #expect(before.primary == .restoreBackup)
    let after = try #require(DeviceApprovalCopy.make(for: state, restoreQueued: true, now: now))
    #expect(after.title.hasPrefix("Encrypted chat unlocks "))
    #expect(after.message.contains("Mac can approve this device sooner"))
    #expect(after.primary == .checkAgain)
    let due = try #require(DeviceApprovalCopy.make(
      for: state,
      restoreQueued: true,
      now: selfApprovesAt.addingTimeInterval(1)
    ))
    #expect(due.title == "Finishing approval")
  }

  @Test("No approved device left: restore with the backup")
  func noApproverLeft() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, status: .revoked, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(5)),
        OwnDeviceApprovalRow(deviceId: me, status: .pendingApproval, createdAt: hoursAgo(1)),
      ],
      now: now
    ))
    #expect(state == .noApprover(holdEndsAt: hoursAgo(1).addingTimeInterval(hold)))
    let copy = try #require(DeviceApprovalCopy.make(for: state, restoreQueued: false, now: now))
    #expect(copy.title == "Restore your backup to use encrypted chat")
    #expect(copy.primary == .restoreBackup)
    #expect(AccountSecuritySettingsView.signOutMessage(for: state).contains("starts it over"))
  }

  @Test("A device that enrolled as \"Catbird\" is never named as if it were the app")
  func genericNamesStayOutOfCopy() throws {
    let pending = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, deviceName: "Catbird", status: .active, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(12)),
        OwnDeviceApprovalRow(deviceId: me, deviceName: "Catbird", status: .pendingApproval, createdAt: hoursAgo(40)),
      ],
      now: now
    ))
    for restoreQueued in [false, true] {
      let copy = try #require(DeviceApprovalCopy.make(for: pending, restoreQueued: restoreQueued, now: now))
      #expect(!copy.title.contains("Catbird"))
      #expect(!copy.message.contains("Catbird"))
      #expect(!copy.message.contains("isn’t used"))
      #expect(copy.message.contains("another device you’re signed in on") || copy.message.contains("Another device you’re signed in on"))
    }

    let approved = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: mac,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, deviceName: "Catbird", status: .active, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(1)),
        OwnDeviceApprovalRow(deviceId: me, deviceName: "Catbird", status: .pendingApproval, createdAt: hoursAgo(40)),
      ],
      now: now
    ))
    let card = try #require(DeviceApprovalCopy.make(for: approved, restoreQueued: false, now: now))
    #expect(card.title == "A new device is waiting for approval")
    #expect(card.message.hasPrefix("It was added "))
    #expect(OwnDeviceApprovalRow(deviceId: me, deviceName: "Mac mini", status: .active).specificName == "Mac mini")
    #expect(OwnDeviceApprovalRow(deviceId: me, deviceName: "Catbird", status: .active).specificName == nil)
  }

  @Test("The server's own group-delivery rows never count as approvers")
  func federatedRowsIgnored() throws {
    let state = try #require(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [
        OwnDeviceApprovalRow(deviceId: mac, deviceName: "federated-group-device", status: .active, createdAt: hoursAgo(900), lastActiveAt: hoursAgo(1)),
        OwnDeviceApprovalRow(deviceId: me, status: .pendingApproval, createdAt: hoursAgo(1)),
      ],
      now: now
    ))
    guard case .noApprover = state else {
      Issue.record("Expected noApprover, got \(state)")
      return
    }
  }

  @Test("An unknown current device yields no state")
  func unknownCurrentDevice() {
    #expect(DeviceApprovalState.evaluate(
      currentDeviceId: me,
      rows: [OwnDeviceApprovalRow(deviceId: mac, status: .active)],
      now: now
    ) == nil)
  }

  @Test("Wire rows decode, and unknown statuses are skipped")
  func wireDecoding() throws {
    let json = Data("""
    {"deviceId":"\(me)","deviceName":"iPhone","status":"pending_approval",
     "createdAt":"2026-11-25T09:00:00.000Z","lastActiveAt":"2026-11-25T00:00:00.000Z",
     "keyId":"k","authGeneration":1}
    """.utf8)
    let row = try #require(OwnDeviceApprovalRow(wireDeviceJSON: json))
    #expect(row.status == .pendingApproval)
    #expect(row.deviceName == "iPhone")
    #expect(row.createdAt == DeviceRowModel.parseISO8601("2026-11-25T09:00:00.000Z"))
    #expect(OwnDeviceApprovalRow(wireDeviceJSON: Data(#"{"deviceId":"\#(me)","status":"frozen"}"#.utf8)) == nil)
  }

  @Test("Dates read as today, tomorrow, or a weekday")
  func dateWording() throws {
    let utc = try #require(TimeZone(identifier: "UTC"))
    let locale = Locale(identifier: "en_US")
    let base = Date(timeIntervalSince1970: 1_795_000_000) // a Wednesday, 11:06 UTC
    #expect(DeviceApprovalCopy.formatted(base.addingTimeInterval(3600), now: base, locale: locale, timeZone: utc).hasPrefix("today at "))
    #expect(DeviceApprovalCopy.formatted(base.addingTimeInterval(24 * 3600), now: base, locale: locale, timeZone: utc).hasPrefix("tomorrow at "))
    #expect(DeviceApprovalCopy.formatted(base.addingTimeInterval(72 * 3600), now: base, locale: locale, timeZone: utc).hasPrefix("on Saturday"))
  }

  @Test("The restore banner says whether this device is approved yet")
  func restoreOutcome() {
    #expect(LabyrinthSettingsAndRestoreView.restoreOutcome(stillPending: false, approval: nil).contains("approved for encrypted chat"))
    let waiting = DeviceApprovalState.noApprover(holdEndsAt: Date().addingTimeInterval(3600))
    #expect(LabyrinthSettingsAndRestoreView.restoreOutcome(stillPending: true, approval: waiting).contains("approves itself"))
  }
}
