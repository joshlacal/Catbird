enum MLSSuspensionCloseOutcome: Equatable {
  case rustPathUnavailable
  case preparationFailed
  case staleTransition
  case closed
  case storageCloseIncomplete
}

@MainActor
enum MLSSuspensionCloseCoordinator {
  static func run(
    rustPathAvailable: Bool,
    transitionStillCurrent: () -> Bool,
    prepareRustRuntime: () async -> Bool,
    closePreparedRuntime: () -> Void,
    closeSwiftStorage: () -> Bool,
    waitForSwiftStorageRetry: () async -> Bool
  ) async -> MLSSuspensionCloseOutcome {
    guard transitionStillCurrent() else { return .staleTransition }
    var rustOutcome = MLSSuspensionCloseOutcome.rustPathUnavailable
    if rustPathAvailable {
      let prepared = await prepareRustRuntime()
      guard transitionStillCurrent() else { return .staleTransition }
      if prepared {
        closePreparedRuntime()
        rustOutcome = .closed
      } else {
        rustOutcome = .preparationFailed
      }
    }

    // Swift owns independent pools and admission leases. A missing or failed
    // Rust path does not establish anything about those handles.
    while true {
      // Validation and the synchronous close stay in one MainActor turn. A
      // foreground transition must never interleave between them.
      guard transitionStillCurrent() else { return .staleTransition }
      if closeSwiftStorage() { return rustOutcome }

      let mayRetry = await waitForSwiftStorageRetry()
      guard transitionStillCurrent() else { return .staleTransition }
      guard mayRetry else { return .storageCloseIncomplete }
    }
  }

  /// Expiration can follow a normal Rust close or another expiration callback.
  /// Every current expiration retries Swift storage, even when Rust was claimed.
  static func runExpiration(
    transitionStillCurrent: () -> Bool,
    claimRustRuntimeClose: () -> Bool,
    closeRustRuntime: () -> Void,
    closeSwiftStorage: () -> Bool
  ) -> Bool {
    guard transitionStillCurrent() else { return false }
    if claimRustRuntimeClose() { closeRustRuntime() }
    return closeSwiftStorage()
  }
}
