@main
struct VerifyChatEmbedPrefetchAdmission {
  @MainActor
  static func main() {
    let admission = ChatEmbedPrefetchAdmission()
    var observedUpdates = 0
    var requests = 0
    var warmups = 0
    var cancellations = 0

    func emitObservation() {
      observedUpdates += 1
      admission.performIfAllowed { requests += 1 }
    }
    func emitUIKitPrefetch() {
      admission.performIfAllowed { requests += 1 }
    }
    func cancel() {
      cancellations += 1
      precondition(!admission.isAllowed, "Admission must close before cancelling")
      let before = requests
      // Even reentrant observation/prefetch cannot reopen work during teardown.
      emitObservation()
      emitUIKitPrefetch()
      precondition(requests == before)
    }
    func warm() {
      precondition(admission.isAllowed)
      warmups += 1
      admission.performIfAllowed { requests += 1 }
    }
    func update(visible: Bool? = nil, active: Bool? = nil) {
      admission.update(isVisible: visible, isSceneActive: active, cancel: cancel, warm: warm)
    }
    func expectBlockedUpdates() {
      let before = requests
      let previousObservations = observedUpdates
      for _ in 0..<3 { emitObservation(); emitUIKitPrefetch() }
      precondition(requests == before, "Hidden/inactive update started metadata work")
      precondition(observedUpdates == previousObservations + 3, "Observation must remain live")
    }

    expectBlockedUpdates() // View loaded, appearance/scene activity not established.
    update(active: true)
    expectBlockedUpdates() // Foreground alone cannot admit a hidden transcript.
    update(visible: true)
    precondition(warmups == 1 && requests == 1)
    emitObservation()
    precondition(requests == 2)

    update(visible: false) // Cover/push begins: close before cancellation.
    expectBlockedUpdates()
    update(active: true) // Scene updates under the cover must not reopen admission.
    expectBlockedUpdates()
    update(visible: true) // Cover dismissed / interrupted push returns.
    precondition(warmups == 2 && requests == 3)
    update(visible: true, active: true)
    precondition(warmups == 2, "Repeated lifecycle updates must not duplicate warm-up")

    update(active: false) // Inactive/background while still visible.
    expectBlockedUpdates()
    update(visible: false)
    update(visible: true) // Appear while inactive: wait for scene activation.
    expectBlockedUpdates()
    update(active: true)
    precondition(warmups == 3 && requests == 4)

    update(visible: false, active: false)
    update(active: true) // Foreground while still covered.
    expectBlockedUpdates()
    update(visible: true)
    precondition(warmups == 4 && requests == 5)
    precondition(cancellations > 0)
    print("PASS: hidden/covered and inactive updates admit no metadata; observation continues; close precedes cancellation; either lifecycle order resumes warm-up only when visible and active")
  }
}
