import Foundation
import Testing

@testable import Catbird

@Suite("Legacy MLS data purge")
struct LegacyMLSDataPurgeTests {
  @Test(
    "MLS defaults keys are matched",
    arguments: [
      "mls_lastSync",
      "mls.deviceId",
      "blue.catbird.mls.deviceUUID",
      "blue.catbird.mls.database-owner.abc123.clean-v2-openmls-v09-r2",
      "MLSPlaintextHeaderMigrationV1",
      "MLSRustFFIMigrationV1",
      "mlsChatNotificationsEnabled_did:plc:abc",
    ]
  )
  func matchesMLSDefaultsKeys(key: String) {
    #expect(LegacyMLSDataPurge.isLegacyMLSDefaultsKey(key))
  }

  @Test(
    "Non-MLS defaults keys are preserved",
    arguments: [
      "blue.catbird.accessToken",
      "blue.catbird.refreshToken",
      "blue.catbird.lite.mlsPurge.v1",
      "chatNotificationsEnabled",
      "masterPushEnabled",
      "chatMode",
      "MLS_uppercase_prefix",
      "Mls.deviceId",
      "appLanguage",
      "CatbirdSchemaVersion",
    ]
  )
  func preservesOtherDefaultsKeys(key: String) {
    #expect(!LegacyMLSDataPurge.isLegacyMLSDefaultsKey(key))
  }

  @Test("Keychain services match exact MLS services and hybrid per-DID services only")
  func keychainServicePredicate() {
    #expect(LegacyMLSDataPurge.isLegacyMLSKeychainService("blue.catbird.mls"))
    #expect(LegacyMLSDataPurge.isLegacyMLSKeychainService("blue.catbird.mls.content"))
    #expect(LegacyMLSDataPurge.isLegacyMLSKeychainService(
      "blue.catbird.mls.hybrid.did:plc:abc.clean-v2-openmls-v09-r2"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSKeychainService("blue.catbird.mlsx"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSKeychainService("blue.catbird.accessToken"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSKeychainService("blue.catbird"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSKeychainService(""))
  }

  @Test("Signature key tags require the MLS signature prefix")
  func signatureTagPredicate() {
    #expect(LegacyMLSDataPurge.isLegacyMLSSignatureKeyTag("blue.catbird.mls.sig.did:plc:abc"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSSignatureKeyTag("blue.catbird.mls.group.abcd"))
    #expect(!LegacyMLSDataPurge.isLegacyMLSSignatureKeyTag("blue.catbird.dpop"))
  }

  @Test("Directory inventory never names SwiftData or temporary storage")
  func directoryInventoryIsExact() {
    let names = LegacyMLSDataPurge.appGroupDirectoryNames + LegacyMLSDataPurge.cachesDirectoryNames
    #expect(names.count == 8)
    for name in names {
      #expect(!name.isEmpty)
      #expect(!name.contains("/"))
      #expect(!name.lowercased().contains("swiftdata"))
      #expect(!name.contains("default.store"))
      #expect(!name.lowercased().contains("tmp"))
    }
  }
}
