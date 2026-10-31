#if os(iOS)
import Foundation
import Testing
import UIKit

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

  /// One element VoiceOver reaches.
  struct Element {
    let identifier: String?
    let label: String?
    let traits: UIAccessibilityTraits
    /// In the coordinates of the view the walk started from.
    let frame: CGRect
    let object: NSObject
  }

  /// The accessibility elements VoiceOver reaches under `view` (needs `enable()` first), with
  /// frames in `view`'s coordinates. Explicit `accessibilityElements` override a container's
  /// subviews, as they do for VoiceOver.
  static func elements(in view: UIView) -> [Element] {
    guard let screen = view.window?.windowScene?.screen else { return [] }
    var found: [Element] = []
    var visited = Set<ObjectIdentifier>()
    func visit(_ object: NSObject, depth: Int) {
      guard depth < 60, visited.insert(ObjectIdentifier(object)).inserted else { return }
      if object.isAccessibilityElement {
        found.append(Element(
          // SwiftUI's elements answer accessibilityIdentifier without declaring
          // UIAccessibilityIdentification, so read it through the selector.
          identifier: object.responds(to: NSSelectorFromString("accessibilityIdentifier"))
            ? object.value(forKey: "accessibilityIdentifier") as? String : nil,
          label: object.accessibilityLabel, traits: object.accessibilityTraits,
          frame: view.convert(object.accessibilityFrame, from: screen.coordinateSpace), object: object))
        return
      }
      if let elements = object.accessibilityElements {
        elements.compactMap { $0 as? NSObject }.forEach { visit($0, depth: depth + 1) }
      } else {
        let count = object.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
          (0..<count).compactMap { object.accessibilityElement(at: $0) as? NSObject }.forEach { visit($0, depth: depth + 1) }
        }
        (object as? UIView)?.subviews.forEach { visit($0, depth: depth + 1) }
      }
    }
    visit(view, depth: 0)
    return found
  }
}
#endif
