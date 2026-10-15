#if os(iOS)
import Foundation
import Testing

/// SwiftUI builds its accessibility tree only while app accessibility is on, which it is not in a
/// test host. Tests that read hosted SwiftUI accessibility (labels, traits, frames) switch it on
/// the way snapshot-testing libraries do (libAccessibility's
/// _AXSApplicationAccessibilitySetEnabled) and restore it.
@MainActor
enum AppAccessibility {
  /// Tests that overlap on the main actor share one switch: the first enable records the prior
  /// state, and only the last restore puts it back.
  private static var holders = 0
  private static var priorState = false

  static func enable() -> @MainActor () -> Void {
    guard let library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
          let getter = dlsym(library, "_AXSApplicationAccessibilityEnabled"),
          let setter = dlsym(library, "_AXSApplicationAccessibilitySetEnabled") else {
      Issue.record("libAccessibility is unavailable")
      return {}
    }
    let isEnabled = unsafeBitCast(getter, to: (@convention(c) () -> Bool).self)
    let setEnabled = unsafeBitCast(setter, to: (@convention(c) (Bool) -> Void).self)
    if holders == 0 {
      priorState = isEnabled()
      setEnabled(true)
    }
    holders += 1
    var released = false
    return {
      guard !released else { return }
      released = true
      holders -= 1
      if holders == 0 { setEnabled(priorState) }
    }
  }
}
#endif
