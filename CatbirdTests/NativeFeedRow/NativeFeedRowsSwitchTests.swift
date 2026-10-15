#if os(iOS)
import Foundation
import Testing
@testable import Catbird

@Suite("Native feed rows switch", .serialized)
struct NativeFeedRowsSwitchTests {
  @Test("The user default turns native rows off")
  func userDefaultDisables() {
    let defaults = UserDefaults.standard
    defaults.set(true, forKey: "nativeFeedRowsDisabled")
    defer { defaults.removeObject(forKey: "nativeFeedRowsDisabled") }
    #expect(NativeFeedRows.isEnabled == false)
  }
}
#endif
