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
        let title = first.name.map { "\($0) is waiting for approval" }
          ?? "A new device is waiting for approval"
        let added = first.name == nil
          ? first.addedAt.map { "It was added \(day($0, locale: locale, timeZone: timeZone)). " } ?? ""
          : ""
        let message = onlyApprover
          ? "\(added)Approve it if it’s yours. This is your only approved device, so approve it before you sign out here."
          : "\(added)Approve it if it’s yours, or remove it in Devices if you don’t recognize it."
        return DeviceApprovalCopy(
          title: title,
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

    case .askApprover(let approvers, let selfApprovesAt),
      .approversQuiet(let approvers, let selfApprovesAt):
      let approver = approvers.first?.name
      if restoreQueued {
        if selfApprovesAt <= now { return finishing }
        let sooner = approver.map { "\($0) can approve this device sooner in Settings > Devices." }
          ?? "Another device you’re signed in on can approve it sooner in Settings > Devices."
        return DeviceApprovalCopy(
          title: "Encrypted chat unlocks \(when(selfApprovesAt))",
          message: "Your backup is restored. \(sooner)",
          tone: .blocking,
          primary: .checkAgain,
          secondary: nil
        )
      }
      let orApprove = approver.map { "You can also approve this device from \($0) in Settings > Devices." }
        ?? "You can also approve it from another device you’re signed in on, in Settings > Devices."
      return DeviceApprovalCopy(
        title: "Restore your backup to use encrypted chat",
        message: "Use your passkey or recovery code. \(orApprove)",
        tone: .blocking,
        primary: .restoreBackup,
        secondary: .checkAgain
      )

    case .noApprover(let holdEndsAt):
      if restoreQueued {
        if holdEndsAt <= now { return finishing }
        return DeviceApprovalCopy(
          title: "Encrypted chat unlocks \(when(holdEndsAt))",
          message: "Your backup is restored, and this device finishes approving itself then.",
          tone: .blocking,
          primary: .checkAgain,
          secondary: nil
        )
      }
      return DeviceApprovalCopy(
        title: "Restore your backup to use encrypted chat",
        message: "Use your passkey or recovery code. No other device on your account can approve this one, so your backup is how it gets in.",
        tone: .blocking,
        primary: .restoreBackup,
        secondary: .checkAgain
      )

    case .revoked:
      return DeviceApprovalCopy(
        title: "This device was removed from encrypted chat",
        message: "Sign out and sign back in to add it again, then restore your backup or approve it from another device.",
        tone: .blocking,
        primary: .reviewDevices,
        secondary: nil
      )
    }
  }

  private static let finishing = DeviceApprovalCopy(
    title: "Finishing approval",
    message: "Your backup is restored, so this device is approving itself now.",
    tone: .blocking,
    primary: .checkAgain,
    secondary: nil
  )

  /// "Nov 20".
  static func day(_ date: Date, locale: Locale, timeZone: TimeZone) -> String {
    var style = Date.FormatStyle().month(.abbreviated).day()
    style.locale = locale
    style.timeZone = timeZone
    return date.formatted(style)
  }

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
