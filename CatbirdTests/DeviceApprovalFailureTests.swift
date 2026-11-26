import CatbirdMLSCore
import Foundation
import Testing
@testable import Catbird

@Suite("Device approval failure wording")
struct DeviceApprovalFailureTests {

  @Test("A device with no key record on the account says it didn't finish setting up")
  func missingPdsRecord() {
    let raw =
      "Cryptography error: target device 927189be-c70d-4457-90f5-aca28466e17b missing verified PDS blue.catbird.chat.device record"
    let failure = DeviceApprovalFailure(
      error: MlsError.Cryptography(message: raw),
      deviceName: "Catmos Web"
    )
    #expect(failure.message.contains("Catmos Web didn’t finish setting up"))
    #expect(!failure.message.contains("Cryptography"))
    #expect(!failure.message.contains("927189be"))
    #expect(failure.detail == raw)
  }

  @Test("A key mismatch says approving isn't safe")
  func keyMismatch() {
    let failure = DeviceApprovalFailure(
      error: MlsError.Cryptography(
        message: "target device 927189be-c70d-4457-90f5-aca28466e17b signaturePublicKey mismatch between mls-ds and PDS"
      ),
      deviceName: "Catmos Web"
    )
    #expect(failure.message.contains("isn’t safe"))
    #expect(failure.detail != nil)
  }

  @Test("A device that left the waiting list says so")
  func noLongerWaiting() {
    let failure = DeviceApprovalFailure(
      error: MlsError.InvalidState(
        message: "target device 927189be-c70d-4457-90f5-aca28466e17b not found in getOwnDevices"
      ),
      deviceName: "Catmos Web"
    )
    #expect(failure.message == "Catmos Web isn’t waiting for approval anymore.")
  }

  @Test("Offline gets the connection sentence")
  func offline() {
    let failure = DeviceApprovalFailure(error: URLError(.notConnectedToInternet), deviceName: "Mac")
    #expect(failure.message.contains("Check your connection"))
  }

  @Test("Anything else gets a general sentence and keeps the engine's words under Details")
  func unknown() {
    let failure = DeviceApprovalFailure(
      error: MlsError.Internal(message: "getOwnDevices missing items array"),
      deviceName: "Mac"
    )
    #expect(failure.message.hasPrefix("Couldn’t approve Mac."))
    #expect(failure.detail == "getOwnDevices missing items array")
  }
}
