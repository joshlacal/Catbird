/// Bridges process launch to the first observed scene lifecycle.
@MainActor
final class MLSInitialLifecycleCoordinator {
  static let shared = MLSInitialLifecycleCoordinator()
  private var hasObservedScene = false
  private var hasEstablishedInitialSuspension = false

  func prepareForLaunch(applicationIsActive: Bool, suspendMLS: () -> Void) {
    guard !hasObservedScene, !hasEstablishedInitialSuspension, !applicationIsActive else { return }
    hasEstablishedInitialSuspension = true
    suspendMLS()
  }

  func recordSceneObservation() {
    hasObservedScene = true
  }
}
