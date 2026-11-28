import CatbirdMLSCore
import Foundation

/// Why approving a waiting device didn't work, in two parts: one plain sentence for the
/// person, and the engine's own words for support.
struct DeviceApprovalFailure: Equatable, Sendable {
  /// One plain sentence saying what went wrong and what to do.
  let message: String
  /// The underlying error text, shown only under Details.
  let detail: String?

  init(message: String, detail: String? = nil) {
    self.message = message
    let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    self.detail = (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  /// Encrypted chat couldn't open on this device, so nothing was tried.
  static let notReady = DeviceApprovalFailure(
    message: String(
      localized: "Encrypted chat isn’t ready on this device yet. Try again in a moment.",
      comment: "Device approval: the encrypted chat engine is not open yet"
    )
  )

  /// Sorts a failed approval into a sentence that says what happened.
  ///
  /// The engine reports these cases as `MlsError` messages, so the message text is what
  /// tells them apart. Anything unrecognised gets a general sentence, with the text kept
  /// under Details.
  init(error: Error, deviceName: String) {
    if error is URLError {
      self.init(
        message: String(
          localized: "Couldn’t reach the server. Check your connection and try again.",
          comment: "Device approval: network failure"
        ),
        detail: error.localizedDescription
      )
      return
    }
    let detail = Self.detail(for: error)
    let lowered = detail.lowercased()
    if lowered.contains("missing verified pds blue.catbird.chat.device record") {
      // The device registered with the chat server but never published its key to the
      // account's own server, so there is nothing to check its key against.
      self.init(
        message: String(
          localized: "\(deviceName) didn’t finish setting up, so it can’t be approved yet. Open \(deviceName) again to finish, or remove it in Devices.",
          comment: "Device approval: the waiting device never published its key record to the account's server. The placeholder is the device's name."
        ),
        detail: detail
      )
    } else if lowered.contains("signaturepublickey mismatch") {
      self.init(
        message: String(
          localized: "\(deviceName)’s key on your account doesn’t match the one it registered, so approving it isn’t safe. Remove it in Devices and set it up again.",
          comment: "Device approval: the key published on the account's server differs from the chat server's. The placeholder is the device's name."
        ),
        detail: detail
      )
    } else if lowered.contains("not found in getowndevices") {
      self.init(
        message: String(
          localized: "\(deviceName) isn’t waiting for approval anymore.",
          comment: "Device approval: the device left the waiting list before it was approved. The placeholder is the device's name."
        ),
        detail: detail
      )
    } else {
      self.init(
        message: String(
          localized: "Couldn’t approve \(deviceName). Try again, or remove it in Devices if it keeps failing.",
          comment: "Device approval: any other failure. The placeholder is the device's name."
        ),
        detail: detail
      )
    }
  }

  /// The engine's own text for `error`, without the Swift type wrapper.
  private static func detail(for error: Error) -> String {
    if let mlsError = error as? MlsError {
      switch mlsError {
      case .Cryptography(let message), .InvalidState(let message), .Internal(let message):
        return message
      default:
        return String(describing: mlsError)
      }
    }
    return error.localizedDescription
  }
}
