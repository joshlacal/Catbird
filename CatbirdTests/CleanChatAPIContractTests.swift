import Foundation
import XCTest

final class CleanChatAPIContractTests: XCTestCase {
  func testBlobReadersUseCanonicalChatNamespace() throws {
    let source = try sourceFile("Catbird/Features/MLSChat/Views/Components/MLSImageView.swift")
      + sourceFile("Catbird/Features/MLSChat/Views/Components/VoiceMessagePlayerView.swift")

    XCTAssertTrue(source.contains("blue.catbird.chat.getBlob"))
    XCTAssertFalse(source.contains("blue.catbird.mlsChat.getBlob"))
  }

  func testDeviceInventoryUsesCanonicalChatNamespace() throws {
    let source = try sourceFile("Catbird/Features/Settings/DeviceManagementView.swift")
      + sourceFile("Catbird/App/CatbirdApp.swift")

    XCTAssertTrue(source.contains("blue.catbird.chat.getOwnDevices"))
    XCTAssertFalse(source.contains("blue.catbird.mlsChat.listDevices"))
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = testsDirectory.deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
  }
}
