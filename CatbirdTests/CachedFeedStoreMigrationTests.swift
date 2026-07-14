import Foundation
import Petrel
import SwiftData
import Testing

@testable import Catbird

@Suite("Cached feed store migration")
struct CachedFeedStoreMigrationTests {
  @Test("Opening a v4 store preserves every non-cache data category")
  func v4StoreUpgradePreservesNonCacheData() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("CachedFeedStoreMigration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storeURL = directory.appendingPathComponent("Catbird.store")

    let draftID = UUID()
    let backupID = UUID()
    let repositoryID = UUID()
    try createLegacyV4Store(
      at: storeURL,
      draftID: draftID,
      backupID: backupID,
      repositoryID: repositoryID
    )

    let upgraded = try CatbirdSwiftDataStore.makeContainer(at: storeURL)
    let context = ModelContext(upgraded)

    let legacyRows = try context.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(legacyRows.map(\.id) == ["at://did:plc:author/app.bsky.feed.post/legacy-legacy-cid"])

    let manager = PersistentFeedStateManager(modelContainer: upgraded)
    let scopedRow = try #require(
      CachedFeedViewPost(from: makeFeedViewPost(), feedType: "timeline")
    )
    await manager.saveFeedData([scopedRow], for: "timeline")

    let refreshedContext = ModelContext(upgraded)
    let upgradedRows = try refreshedContext.fetch(FetchDescriptor<CachedFeedViewPost>())
    #expect(upgradedRows.map(\.id) == [scopedRow.id])

    let drafts = try refreshedContext.fetch(FetchDescriptor<DraftPost>())
    #expect(drafts.map(\.id) == [draftID])
    #expect(drafts.first?.previewText == "preserve this draft")

    let settings = try refreshedContext.fetch(FetchDescriptor<AppSettingsModel>())
    #expect(settings.count == 1)
    #expect(settings.first?.theme == "midnight")

    let backups = try refreshedContext.fetch(FetchDescriptor<BackupRecord>())
    #expect(backups.map(\.id) == [backupID])
    #expect(backups.first?.filePath == "backups/preserve.car")

    let repositories = try refreshedContext.fetch(FetchDescriptor<RepositoryRecord>())
    #expect(repositories.map(\.id) == [repositoryID])
    #expect(repositories.first?.userHandle == "preserve.test")
  }

  @Test("Cache identity upgrade never triggers whole-store schema quarantine")
  func cacheUpgradeDoesNotQuarantineSharedStore() throws {
    let appSource = try sourceFile("Catbird/App/CatbirdApp.swift")
    let cacheSource = try sourceFile("Catbird/Features/Feed/Models/CachedFeedViewPost.swift")

    #expect(appSource.contains("private static let currentSchemaVersion = 4"))
    #expect(!appSource.contains("v5: CachedFeedViewPost uniqueness changed"))
    #expect(cacheSource.contains("@Attribute(.unique) var id: String"))
    #expect(!cacheSource.contains("#Unique<CachedFeedViewPost>"))
  }

  private func createLegacyV4Store(
    at storeURL: URL,
    draftID: UUID,
    backupID: UUID,
    repositoryID: UUID
  ) throws {
    // The safe upgrade deliberately keeps the deployed v4 model shape. Build a
    // real on-disk v4 store with the production model type and a pre-upgrade,
    // globally keyed cache row, then reopen it through the app's store factory.
    let schema = Schema(CatbirdSwiftDataStore.modelTypes)
    let configuration = ModelConfiguration(
      "Catbird-v4",
      schema: schema,
      url: storeURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: [configuration])
    let context = ModelContext(container)

    let legacyPost = try #require(CachedFeedViewPost(from: makeFeedViewPost(), feedType: "timeline"))
    legacyPost.id = "at://did:plc:author/app.bsky.feed.post/legacy-legacy-cid"
    context.insert(legacyPost)
    context.insert(
      DraftPost(
        id: draftID,
        accountDID: "did:plc:preserve",
        draftData: Data("draft-data".utf8),
        previewText: "preserve this draft",
        hasMedia: false,
        isReply: false,
        isQuote: false,
        isThread: false
      )
    )
    let settings = AppSettingsModel(accountDID: "did:plc:preserve")
    settings.theme = "midnight"
    context.insert(settings)
    context.insert(
      BackupRecord(
        id: backupID,
        userDID: "did:plc:preserve",
        userHandle: "preserve.test",
        filePath: "backups/preserve.car",
        fileSize: 42,
        carDataHash: "hash",
        status: .completed
      )
    )
    context.insert(
      RepositoryRecord(
        id: repositoryID,
        backupRecordID: backupID,
        userDID: "did:plc:preserve",
        userHandle: "preserve.test",
        originalCarSize: 42
      )
    )
    try context.save()
  }

  private func makeFeedViewPost() throws -> AppBskyFeedDefs.FeedViewPost {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: "did:plc:author"),
      handle: try Handle(handleString: "author.test"),
      displayName: "Author",
      pronouns: nil,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      verification: nil,
      status: nil,
      debug: nil
    )
    let record = AppBskyFeedPost(
      text: "legacy cache row",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: nil,
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_000))
    )
    let post = AppBskyFeedDefs.PostView(
      uri: try ATProtocolURI(
        uriString: "at://did:plc:author/app.bsky.feed.post/legacy"
      ),
      cid: CID.fromDAGCBOR(Data("legacy-cid".utf8)),
      author: author,
      record: .knownType(record),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: nil,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_700_000_001)),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    return AppBskyFeedDefs.FeedViewPost(
      post: post,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
  }

  private func sourceFile(_ relativePath: String) throws -> String {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(
      contentsOf: repositoryRoot.appendingPathComponent(relativePath),
      encoding: .utf8
    )
  }
}
