//
//  AppIntentsSupportTests.swift
//  CatbirdTests
//
//  Network-free coverage for the hand-written App Intents support added in
//  the build-out: recordWrite rkey parsing, the Bluesky DM conversation
//  entity's ConvoView projection, and CreatePostIntent's pure helpers
//  (embed selection, mention candidate extraction).
//

import AppIntents
import Foundation
import Petrel
import Testing

@testable import Catbird

// MARK: - IntentRecordWriteSupport

@Suite("IntentRecordWriteSupport rkey parsing")
struct RecordWriteSupportTests {

  @Test func extractsRecordKeyFromViewerURI() throws {
    let uri = try ATProtocolURI(uriString: "at://did:plc:abc123/app.bsky.feed.like/3l5xyzrkey22")
    let rkey = try IntentRecordWriteSupport.recordKey(fromViewerURI: uri)
    #expect("\(rkey)" == "3l5xyzrkey22")
  }

  @Test func collectionOnlyURIThrows() throws {
    let uri = try ATProtocolURI(uriString: "at://did:plc:abc123/app.bsky.feed.like")
    #expect(throws: IntentError.self) {
      _ = try IntentRecordWriteSupport.recordKey(fromViewerURI: uri)
    }
  }
}

// MARK: - BskyConversationEntity

@Suite("BskyConversationEntity ConvoView projection")
struct BskyConversationEntityTests {

  static let selfDID = "did:plc:self00000000000000000000"
  static let otherDID = "did:plc:other0000000000000000000"

  static func member(
    did: String, handle: String, displayName: String?
  ) throws -> ChatBskyActorDefs.ProfileViewBasic {
    ChatBskyActorDefs.ProfileViewBasic(
      did: try DID(didString: did),
      handle: try Handle(handleString: handle),
      displayName: displayName,
      avatar: nil,
      associated: nil,
      viewer: nil,
      labels: nil,
      createdAt: nil,
      chatDisabled: nil,
      verification: nil,
      kind: nil
    )
  }

  static func convoView(
    lastMessage: ChatBskyConvoDefs.ConvoViewLastMessageUnion?,
    displayName: String? = "Alex Rivera",
    unreadCount: Int = 3,
    muted: Bool = false
  ) throws -> ChatBskyConvoDefs.ConvoView {
    ChatBskyConvoDefs.ConvoView(
      id: "3l5convoid123",
      rev: "rev1",
      members: [
        try member(did: selfDID, handle: "me.bsky.social", displayName: "Me"),
        try member(did: otherDID, handle: "alex.bsky.social", displayName: displayName),
      ],
      lastMessage: lastMessage,
      lastReaction: nil,
      muted: muted,
      status: nil,
      unreadCount: unreadCount,
      kind: nil
    )
  }

  static func messageView(text: String) throws -> ChatBskyConvoDefs.MessageView {
    ChatBskyConvoDefs.MessageView(
      id: "msg1",
      rev: "rev1",
      text: text,
      facets: nil,
      embed: nil,
      reactions: nil,
      replyTo: nil,
      sender: ChatBskyConvoDefs.MessageViewSender(did: try DID(didString: otherDID)),
      sentAt: ATProtocolDate(date: Date())
    )
  }

  @Test func titleUsesOtherMembersAndExcludesSelf() throws {
    let entity = BskyConversationEntity(
      from: try Self.convoView(lastMessage: nil), currentUserDID: Self.selfDID)
    #expect(entity.title == "Alex Rivera")
    #expect(entity.memberHandles == ["alex.bsky.social"])
    #expect(entity.unreadCount == 3)
    #expect(entity.muted == false)
  }

  @Test func titleFallsBackToHandleWhenDisplayNameMissing() throws {
    let entity = BskyConversationEntity(
      from: try Self.convoView(lastMessage: nil, displayName: nil),
      currentUserDID: Self.selfDID)
    #expect(entity.title == "@alex.bsky.social")
  }

  @Test func lastMessagePreviewComesFromMessageViewOnly() throws {
    let withMessage = BskyConversationEntity(
      from: try Self.convoView(
        lastMessage: .chatBskyConvoDefsMessageView(try Self.messageView(text: "hey there"))),
      currentUserDID: Self.selfDID)
    #expect(withMessage.lastMessagePreview == "hey there")

    let withoutMessage = BskyConversationEntity(
      from: try Self.convoView(lastMessage: nil), currentUserDID: Self.selfDID)
    #expect(withoutMessage.lastMessagePreview == nil)
  }
}

// MARK: - CreatePostIntent helpers

@Suite("CreatePostIntent embed builder & mention parsing")
struct CreatePostIntentTests {

  private func makeImage() -> AppBskyEmbedImages.Image {
    AppBskyEmbedImages.Image(
      image: Blob(type: "blob", mimeType: "image/jpeg", size: 1234),
      alt: "test",
      aspectRatio: nil
    )
  }

  private func makeQuoteRef() throws -> ComAtprotoRepoStrongRef {
    ComAtprotoRepoStrongRef(
      uri: try ATProtocolURI(uriString: "at://did:plc:abc/app.bsky.feed.post/3l5quoted"),
      cid: try CID.parse("bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku")
    )
  }

  @Test func noImagesNoQuoteMeansNoEmbed() {
    #expect(CreatePostEmbedBuilder.embed(images: [], quote: nil) == nil)
  }

  @Test func quoteOnlyBuildsRecordEmbed() throws {
    let embed = CreatePostEmbedBuilder.embed(images: [], quote: try makeQuoteRef())
    guard case .appBskyEmbedRecord = embed else {
      Issue.record("expected .appBskyEmbedRecord, got \(String(describing: embed))")
      return
    }
  }

  @Test func imagesOnlyBuildsImagesEmbed() {
    let embed = CreatePostEmbedBuilder.embed(images: [makeImage()], quote: nil)
    guard case .appBskyEmbedImages(let images) = embed else {
      Issue.record("expected .appBskyEmbedImages, got \(String(describing: embed))")
      return
    }
    #expect(images.images.count == 1)
  }

  @Test func imagesPlusQuoteBuildsRecordWithMedia() throws {
    let embed = CreatePostEmbedBuilder.embed(images: [makeImage()], quote: try makeQuoteRef())
    guard case .appBskyEmbedRecordWithMedia = embed else {
      Issue.record("expected .appBskyEmbedRecordWithMedia, got \(String(describing: embed))")
      return
    }
  }

  @Test func mentionCandidatesAreDedupedLowercasedAndOrdered() {
    let text = "hey @Alice.bsky.social and @bob.test — also @alice.bsky.social again, plus @ alone"
    let candidates = CreatePostEmbedBuilder.mentionCandidates(in: text)
    #expect(candidates == ["alice.bsky.social", "bob.test"])
  }

  @Test func textWithoutMentionsYieldsNoCandidates() {
    #expect(CreatePostEmbedBuilder.mentionCandidates(in: "no mentions here").isEmpty)
  }
}


