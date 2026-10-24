import CatbirdMLSCore
import Testing

@Suite("Application native MLS artifact pairing")
struct NativeMLSArtifactTests {
  @Test("The application's selected generated bindings initialize its native library")
  func selectedBindingsInitializeNativeLibrary() throws {
    // A generated call validates the complete UniFFI contract/checksum table.
    // This runs inside the signed app host, through the same linked binary.
    #expect(securityStorageCapabilitiesVersion() > 0)
    #expect(try mlsGeneratePsk().count == 32)
  }
}
