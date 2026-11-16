import Foundation

@MainActor
struct MLSUserOptOutSequence {
  let unregisterPushGateway: @MainActor () async -> Void
  let persistUserDisabled: @MainActor () -> Void
  let resetLocalMLSState: @MainActor () async -> Void

  // Scaffolding with the current settings-screen behaviour.
  func run() async {
    persistUserDisabled()
    await resetLocalMLSState()
  }
}
