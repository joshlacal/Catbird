import Testing
@testable import Catbird

/// F50: `CatbirdApp.handleScenePhaseChange` asks this policy whether leaving `.active` may close
/// the process-wide database and MLS connections. On macOS a focus loss is not a suspension.
@Suite("Scene deactivation MLS policy (F50)")
struct MacOSSceneDeactivationTests {
  @Test("macOS focus loss keeps MLS open even when no other scene is active")
  func macOSFocusLossPreservesMLS() {
    #expect(CatbirdApp.sceneDeactivationPreservesMLS(isMacOS: true, otherScenesActive: false))
  }

  @Test("iOS is unchanged: suspend with no other active scene, preserve while one remains")
  func iOSSuspensionUnchanged() {
    #expect(!CatbirdApp.sceneDeactivationPreservesMLS(isMacOS: false, otherScenesActive: false))
    #expect(CatbirdApp.sceneDeactivationPreservesMLS(isMacOS: false, otherScenesActive: true))
  }
}
