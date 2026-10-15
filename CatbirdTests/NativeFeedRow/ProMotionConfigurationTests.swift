#if os(iOS)
import Foundation
import Testing
@testable import Catbird

@Suite("ProMotion configuration")
struct ProMotionConfigurationTests {
  @Test("The app opts in to frame rates above 60 Hz on iPhone")
  func infoPlistAllowsHighFrameRates() {
    let value = Bundle.main.object(forInfoDictionaryKey: "CADisableMinimumFrameDurationOnPhone") as? Bool
    #expect(value == true)
  }
}
#endif
