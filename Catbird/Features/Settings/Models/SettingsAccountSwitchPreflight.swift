import Foundation

/// Resolves local Settings before any account-switch admission or source suspension.
@MainActor
final class SettingsAccountSwitchPreflight {
  enum Outcome: Equatable { case allowed, busy, saveFailed, accountChanged, cancelled }
  private(set) var isRunning = false

  func resolve(
    hasPendingChanges: Bool,
    isCurrent: () -> Bool,
    accountOperationInProgress: () -> Bool,
    savePending: () async -> Bool
  ) async -> Outcome {
    guard !isRunning, !accountOperationInProgress() else { return .busy }
    guard !Task.isCancelled else { return .cancelled }
    guard isCurrent() else { return .accountChanged }
    guard hasPendingChanges else { return .allowed }
    isRunning = true
    defer { isRunning = false }
    let saved = await savePending()
    guard !Task.isCancelled else { return .cancelled }
    guard isCurrent() else { return .accountChanged }
    guard !accountOperationInProgress() else { return .busy }
    return saved ? .allowed : .saveFailed
  }
}
