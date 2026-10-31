//
//  BlueskyMessageEmbedHydrationTests.swift
//  CatbirdTests
//
//  getMessages returns shared posts as hydrated `app.bsky.embed.record#view`
//  records. The transcript seeds ChatRecordEmbedStore with them, so a shared
//  post renders without refetching it (perf teardown P135). These tests pin
//  which messages contribute a record to that seed.
//
//  Adapted from Oct 12 ooyowomr: the integration keeps Oct 11's seed in
//  BlueskyConversationDataSource instead of a hydrated field on the adapter,
//  so the tests exercise `hydratedSharedPosts(in:)`, the filter that seed uses.
//

import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Bluesky message embed hydration")
struct BlueskyMessageEmbedHydrationTests {
  private let postURI = "at://did:plc:author1234567890123456/app.bsky.feed.post/shared1"

  private func sharedPostRecord() throws -> AppBskyEmbedRecord.ViewRecordUnion {
    .appBskyEmbedRecordViewRecord(AppBskyEmbedRecord.ViewRecord(
      uri: try ATProtocolURI(uriString: postURI),
      cid: CID.fromBlob(Data("shared-post".utf8)),
      author: AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: "did:plc:author1234567890123456"),
        handle: try Handle(handleString: "author.bsky.social"),
        displayName: "Author"),
      value: .knownType(AppBskyFeedPost(
        text: "A shared post", entities: nil, facets: nil, reply: nil, embed: nil,
        langs: nil, labels: nil, tags: nil,
        createdAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_800_000_000)))),
      likeCount: 4,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_800_000_000))))
  }

  private func message(
    id: String = "msg_1", embedding record: AppBskyEmbedRecord.ViewRecordUnion?
  ) throws -> ChatBskyConvoDefs.MessageView {
    ChatBskyConvoDefs.MessageView(
      id: id, rev: "1", text: "", facets: nil,
      embed: record.map { .appBskyEmbedRecordView(AppBskyEmbedRecord.View(record: $0)) },
      reactions: nil, replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:alice")),
      sentAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_800_000_100)))
  }

  @Test("A shared post contributes the hydrated record getMessages returned")
  func sharedPostCarriesHydratedRecord() throws {
    let record = try sharedPostRecord()
    let shared = BlueskyConversationDataSource.hydratedSharedPosts(in: [try message(embedding: record)])

    #expect(shared.count == 1)
    #expect(shared.first?.uri == postURI)
    #expect(shared.first?.record == record)
  }

  @Test("Shared posts the server could not hydrate are left to load as before")
  func unhydratedRecordsAreSkipped() throws {
    let uri = try ATProtocolURI(uriString: postURI)
    let messages = [
      try message(id: "not_found", embedding: .appBskyEmbedRecordViewNotFound(
        AppBskyEmbedRecord.ViewNotFound(uri: uri, notFound: true))),
      try message(id: "blocked", embedding: .appBskyEmbedRecordViewBlocked(
        AppBskyEmbedRecord.ViewBlocked(
          uri: uri, blocked: true,
          author: AppBskyFeedDefs.BlockedAuthor(did: try DID(didString: "did:plc:author1234567890123456"))))),
      try message(id: "detached", embedding: .appBskyEmbedRecordViewDetached(
        AppBskyEmbedRecord.ViewDetached(uri: uri, detached: true))),
    ]
    #expect(BlueskyConversationDataSource.hydratedSharedPosts(in: messages).isEmpty)
  }

  @Test("A message without an embed contributes nothing")
  func plainMessageIsSkipped() throws {
    let messages = [try message(id: "plain", embedding: nil), try message(id: "shared", embedding: try sharedPostRecord())]
    let shared = BlueskyConversationDataSource.hydratedSharedPosts(in: messages)
    #expect(shared.map(\.uri) == [postURI])
  }
}
