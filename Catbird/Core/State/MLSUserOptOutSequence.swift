import Foundation

/// The steps that run when the user turns encrypted chat off for an account, in the order
/// they must run:
///
/// 1. Disable the push gateway binding. The request is signed with the device's MLS key, so
///    it runs while the account is still active and the MLS client is open.
/// 2. Store the user's choice in the App Group, where the Notification Service Extension
///    reads it.
/// 3. Close the MLS client and clear in-memory MLS state.
@MainActor
struct MLSUserOptOutSequence {
  let unregisterPushGateway: @MainActor () async -> Void
  let persistUserDisabled: @MainActor () -> Void
  let resetLocalMLSState: @MainActor () async -> Void

  func run() async {
    await unregisterPushGateway()
    persistUserDisabled()
    await resetLocalMLSState()
  }
}
