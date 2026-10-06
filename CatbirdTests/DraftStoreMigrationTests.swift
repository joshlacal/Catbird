import Foundation
import SwiftData
import Testing
@testable import Catbird

/// Mirrors the previously shipped entity, deliberately without syncMetadata.
/// This fixture verifies the additive field against a real on-disk store.
private enum PreviousDraftStore {
  @Model
  final class DraftPost {
    var id: UUID
    var accountDID: String
    var createdDate: Date
    var modifiedDate: Date
    @Attribute(.externalStorage) var draftData: Data
    var previewText: String
    var hasMedia: Bool
    var isReply: Bool
    var isQuote: Bool
    var isThread: Bool
    var remoteId: String?
    var lastSyncedAt: Date?
    var remoteMediaDeviceName: String?

    init(id: UUID, data: Data) {
      self.id = id
      self.accountDID = "did:plc:migration-owner"
      self.createdDate = Date(timeIntervalSince1970: 123)
      self.modifiedDate = Date(timeIntervalSince1970: 456)
      self.draftData = data
      self.previewText = "Preserve the legacy draft"
      self.hasMedia = false
      self.isReply = false
      self.isQuote = false
      self.isThread = false
    }
  }
}

@Suite("Saved draft additive store migration", .serialized)
@MainActor
struct DraftStoreMigrationTests {
  @Test("Opening the previous store preserves draft bytes, identity and timestamps")
  func migratePreviousStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Drafts.store")
    let id = UUID()
    let payload = Data(#"{"postText":"Preserve the legacy draft","mediaItems":[],"selectedLanguages":[],"selectedLabels":[],"outlineTags":[],"threadEntries":[],"isThreadMode":false,"currentThreadIndex":0}"#.utf8)
    try writePreviousStore(url: url, id: id, payload: payload)
    let schema = Schema([DraftPost.self])
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let rows = try container.mainContext.fetch(FetchDescriptor<DraftPost>())
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.id == id)
    #expect(row.draftData == payload)
    #expect(row.modifiedDate == Date(timeIntervalSince1970: 456))
    #expect(row.syncMetadata == nil)
    #expect(try row.decodeDraft().postText == "Preserve the legacy draft")
  }

  private func writePreviousStore(url: URL, id: UUID, payload: Data) throws {
    let schema = Schema([PreviousDraftStore.DraftPost.self])
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    container.mainContext.insert(PreviousDraftStore.DraftPost(id: id, data: payload))
    try container.mainContext.save()
  }
}
