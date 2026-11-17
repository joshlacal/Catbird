import Foundation

/// The steps that run when the user turns encrypted chat off for an account, in the order
/// they must run:
///
/// 1. Confirm the push gateway binding is disabled. The request is signed with the device's MLS
///    key, so it runs while the account and MLS client are still active. A failure stops the
///    sequence: the app must not claim an opt-out while the server keeps sending encrypted wakes.
/// 2. Store the user's choice in the App Group, where the Notification Service Extension reads it.
/// 3. Close the MLS client and clear in-memory MLS state.
@MainActor
struct MLSUserOptOutSequence {
  let unregisterPushGateway: @MainActor () async throws -> Void
  let persistUserDisabled: @MainActor () -> Void
  let resetLocalMLSState: @MainActor () async -> Void

  func run() async throws {
    try await unregisterPushGateway()
    persistUserDisabled()
    await resetLocalMLSState()
  }
}
