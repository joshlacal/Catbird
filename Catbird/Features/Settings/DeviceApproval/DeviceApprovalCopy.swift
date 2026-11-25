import Foundation

// MARK: - Device Approval Copy

/// What the device-approval card says and offers, for one `DeviceApprovalState`.
///
/// Kept apart from the view so the wording for every state is tested.
struct DeviceApprovalCopy: Equatable, Sendable {
  enum Action: Equatable, Sendable {
    /// Open Labyrinth Backup & Recovery to restore with a passkey or recovery code.
    case restoreBackup
    /// Approve the one waiting device from this device.
    case approve(DeviceApprovalPeer)
    /// Open Settings > Devices.
    case reviewDevices
    /// Read the device list again.
    case checkAgain
  }

  enum Tone: Equatable, Sendable {
    /// This device can't use encrypted chat yet.
    case blocking
    /// Something on the account needs a look, but this device works.
    case attention
  }

  let title: String
  let message: String
  let tone: Tone
  let primary: Action
  let secondary: Action?

  /// The card for `state`, or nil when nothing needs the person.
  ///
  /// - Parameter restoreQueued: a backup restore on this device is waiting to publish,
  ///   which is what approves a pending device without a sibling.
  static func make(
    for state: DeviceApprovalState,
    restoreQueued: Bool,
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
  ) -> DeviceApprovalCopy? {
    func when(_ date: Date) -> String {
      formatted(date, now: now, locale: locale, timeZone: timeZone)
    }

    switch state {
    case .approved(let waiting, let otherApprovedCount):
      guard let first = waiting.first else { return nil }
      let onlyApprover = otherApprovedCount == 0
      if waiting.count == 1 {
        let message = onlyApprover
          ? "Approve it if it’s yours. This is your only approved device, so approve it before you sign out here."
          : "Approve it if it’s yours, or remove it in Devices if you don’t recognize it."
        return DeviceApprovalCopy(
          title: "\(first.displayName) is waiting for approval",
          message: message,
          tone: .attention,
          primary: .approve(first),
          secondary: .reviewDevices
        )
      }
      let message = onlyApprover
        ? "Approve the ones that are yours. This is your only approved device, so approve them before you sign out here."
        : "Approve the ones that are yours, and remove any you don’t recognize."
      return DeviceApprovalCopy(
        title: "\(waiting.count) devices are waiting for approval",
        message: message,
        tone: .attention,
        primary: .reviewDevices,
        secondary: nil
      )

    case .askApprover(let approvers, let selfApprovesAt):
      let approver = approvers.first?.displayName ?? "your other device"
      let fallback = restoreQueued
        ? "Your backup is restored, so if \(approver) isn’t used before \(when(selfApprovesAt)), this device approves itself then."
        : "If you no longer have \(approver), restore your backup with your passkey and this device approves itself \(when(selfApprovesAt)), as long as \(approver) isn’t used."
      return DeviceApprovalCopy(
        title: "Approve this device from \(approver)",
        message: "Open Catbird on \(approver) and approve this device in Settings > Devices. \(fallback)",
        tone: .blocking,
        primary: restoreQueued ? Action.checkAgain : Action.restoreBackup,
        secondary: restoreQueued ? nil : Action.checkAgain
      )

    case .approversQuiet(let approvers, let selfApprovesAt):
      let approver = approvers.first?.displayName ?? "your other device"
      if restoreQueued {
        if selfApprovesAt <= now {
          return finishing
        }
        return DeviceApprovalCopy(
          title: "This device approves itself \(when(selfApprovesAt))",
          message: "Your backup is restored. Keep Catbird installed here, and \(approver) can still approve this device sooner from Settings > Devices.",
          tone: .blocking,
          primary: .checkAgain,
          secondary: nil
        )
      }
      return DeviceApprovalCopy(
        title: "Restore your backup to approve this device",
        message: "\(approver) hasn’t been used lately, so it can’t approve this device right now. Restore your backup with your passkey, and this device approves itself \(when(selfApprovesAt)). \(approver) can still approve it sooner.",
        tone: .blocking,
        primary: .restoreBackup,
        secondary: .checkAgain
      )

    case .noApprover(let holdEndsAt):
      if restoreQueued {
        if holdEndsAt <= now {
          return finishing
        }
        return DeviceApprovalCopy(
          title: "This device approves itself \(when(holdEndsAt))",
          message: "Your backup is restored. No approved device is left on your account, so this device finishes approving itself then.",
          tone: .blocking,
          primary: .checkAgain,
          secondary: nil
        )
      }
      return DeviceApprovalCopy(
        title: "Restore your backup to unlock encrypted chat",
        message: "No approved device is left on your account. Restore your backup with your passkey or recovery code to approve this device.",
        tone: .blocking,
        primary: .restoreBackup,
        secondary: .checkAgain
      )

    case .revoked:
      return DeviceApprovalCopy(
        title: "This device was removed from encrypted chat",
        message: "Sign out and sign back in to add it again. Another approved device, or your backup, then approves it.",
        tone: .blocking,
        primary: .reviewDevices,
        secondary: nil
      )
    }
  }

  private static let finishing = DeviceApprovalCopy(
    title: "Finishing approval",
    message: "Your backup is restored and the wait is over, so this device is approving itself now.",
    tone: .blocking,
    primary: .checkAgain,
    secondary: nil
  )

  /// "today at 7:15 PM", "tomorrow at 9:00 AM", or "on Thursday, Nov 27 at 7:15 PM".
  static func formatted(
    _ date: Date,
    now: Date,
    locale: Locale,
    timeZone: TimeZone
  ) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = locale
    calendar.timeZone = timeZone
    var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    timeStyle.locale = locale
    timeStyle.timeZone = timeZone
    let time = date.formatted(timeStyle)
    if calendar.isDate(date, inSameDayAs: now) {
      return "today at \(time)"
    }
    if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
       calendar.isDate(date, inSameDayAs: tomorrow)
    {
      return "tomorrow at \(time)"
    }
    var dayStyle = Date.FormatStyle().weekday(.wide).month(.abbreviated).day()
    dayStyle.locale = locale
    dayStyle.timeZone = timeZone
    return "on \(date.formatted(dayStyle)) at \(time)"
  }
}
