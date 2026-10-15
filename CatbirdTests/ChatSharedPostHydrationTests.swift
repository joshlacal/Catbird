import Foundation
import Petrel
import Testing

@testable import Catbird

/// ChatManager records which atproto-accept-labelers header a getMessages page was hydrated under, so a
/// shared post renders from that page only when the header stayed the same from request to response.
@Suite("Chat shared-post hydration header")
@MainActor
struct ChatSharedPostHydrationTests {
  private let conversationID = "hydration-conversation"
  private let postURI = "at://did:plc:author1234567890123456/app.bsky.feed.post/shared1"
  private static let bsky = ModerationPrefs.blueskyModerationDID
  private static let labeler = "did:web:labeler.test"

  @Test("A page hydrated under one header records it for its shared posts")
  func pageUnderOneHeaderRecordsIt() async throws {
    let header = AppliedHeader([Self.labeler, Self.bsky])
    let record = try sharedPostRecord()
    let output = try page(sharing: record)
    let manager = await makeManager(header: header) { _ in (200, output) }

    await manager.loadMessages(convoId: conversationID, refresh: true)

    let hydration = manager.sharedPostHydrations(for: conversationID)[postURI]
    #expect(hydration?.labelerDIDs == [Self.bsky, Self.labeler].sorted())
    #expect(hydration?.record == record)
  }

  @Test("A page whose header changed while it was in flight records nothing")
  func headerChangeInFlightRecordsNothing() async throws {
    let header = AppliedHeader([Self.bsky, Self.labeler])
    let output = try page(sharing: try sharedPostRecord())
    let manager = await makeManager(header: header) { _ in
      header.value = [Self.bsky]
      return (200, output)
    }

    await manager.loadMessages(convoId: conversationID, refresh: true)

    #expect(manager.sharedPostHydrations(for: conversationID).isEmpty)
    #expect(manager.originalMessagesMap[conversationID]?.count == 1)
  }

  @Test("A page sent before any header was applied records nothing")
  func pageWithoutAHeaderRecordsNothing() async throws {
    let header = AppliedHeader(nil)
    let output = try page(sharing: try sharedPostRecord())
    let manager = await makeManager(header: header) { _ in (200, output) }

    await manager.loadMessages(convoId: conversationID, refresh: true)

    #expect(manager.sharedPostHydrations(for: conversationID).isEmpty)
  }

  @Test("A seed carries the page's header only while the message still holds the record that page returned")
  func seedCarriesTheHeaderOfItsOwnRecord() async throws {
    let header = AppliedHeader([Self.bsky, Self.labeler])
    let record = try sharedPostRecord()
    let output = try page(sharing: record)
    let manager = await makeManager(header: header) { _ in (200, output) }
    await manager.loadMessages(convoId: conversationID, refresh: true)
    let hydrations = manager.sharedPostHydrations(for: conversationID)
    let messages = try #require(manager.originalMessagesMap[conversationID]).values

    let seeds = BlueskyConversationDataSource.hydratedSharedPosts(in: messages, hydrations: hydrations)
    #expect(seeds.map(\.hydratedUnder) == [[Self.bsky, Self.labeler].sorted()])

    // The same post as a later getLog event delivered it, with a different copy of the record.
    let replaced = try message(embedding: try sharedPostRecord(likeCount: 9))
    let replacedSeeds = BlueskyConversationDataSource.hydratedSharedPosts(in: [replaced], hydrations: hydrations)
    #expect(replacedSeeds.map(\.uri) == [postURI])
    #expect(replacedSeeds.first?.hydratedUnder == nil)
  }

  // MARK: - Helpers

  private func makeManager(
    header: AppliedHeader,
    loader: @escaping @MainActor (ChatBskyConvoGetMessages.Parameters) async throws
      -> (Int, ChatBskyConvoGetMessages.Output?)
  ) async -> ChatManager {
    let client = await ATProtoClient(baseURL: URL(string: "https://hydration.invalid")!)
    return ChatManager(
      client: client,
      messagePageLoader: { _, parameters in try await loader(parameters) },
      appliedAcceptLabelers: { header.value })
  }

  private func sharedPostRecord(likeCount: Int = 4) throws -> AppBskyEmbedRecord.ViewRecordUnion {
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
      likeCount: likeCount,
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_800_000_000))))
  }

  private func message(embedding record: AppBskyEmbedRecord.ViewRecordUnion) throws -> ChatBskyConvoDefs.MessageView {
    ChatBskyConvoDefs.MessageView(
      id: "msg_1", rev: "1", text: "", facets: nil,
      embed: .appBskyEmbedRecordView(AppBskyEmbedRecord.View(record: record)),
      reactions: nil, replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: "did:plc:alice")),
      sentAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_800_000_100)))
  }

  private func page(sharing record: AppBskyEmbedRecord.ViewRecordUnion) throws -> ChatBskyConvoGetMessages.Output {
    .init(messages: [.chatBskyConvoDefsMessageView(try message(embedding: record))])
  }
}

/// The applied atproto-accept-labelers DIDs a test reports to ChatManager.
@MainActor
private final class AppliedHeader {
  var value: [String]?

  init(_ value: [String]?) {
    self.value = value
  }
}
