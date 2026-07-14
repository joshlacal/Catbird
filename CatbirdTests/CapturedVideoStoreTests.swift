import Foundation
import Testing
@testable import Catbird

@Suite("Captured Video Store Tests")
struct CapturedVideoStoreTests {
  @Test("Import moves capture into managed durable storage")
  func importUsesManagedStorage() async throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = sandbox.appendingPathComponent("picker.mov")
    let managed = sandbox.appendingPathComponent("SharedDrafts", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try Data([0, 1, 2, 3]).write(to: source)
    let store = CapturedVideoStore(managedDirectory: managed)

    let imported = try await store.importVideo(from: source)

    #expect(store.owns(imported))
    #expect(FileManager.default.fileExists(atPath: imported.path))
    #expect(try Data(contentsOf: imported) == Data([0, 1, 2, 3]))
  }

  @Test("Managed capture cleanup removes owned file")
  func cleanupRemovesOwnedFile() async throws {
    let sandbox = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let source = sandbox.appendingPathComponent("picker.mov")
    let managed = sandbox.appendingPathComponent("SharedDrafts", isDirectory: true)
    try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    try Data([4, 5, 6]).write(to: source)
    let store = CapturedVideoStore(managedDirectory: managed)
    let imported = try await store.importVideo(from: source)

    try await store.removeVideoIfOwned(imported)

    #expect(!FileManager.default.fileExists(atPath: imported.path))
  }
}
