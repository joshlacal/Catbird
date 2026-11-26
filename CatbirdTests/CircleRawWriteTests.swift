//
//  CircleRawWriteTests.swift
//  CatbirdTests
//
//  Fix wave 1, C1 + C4: records handed to the PDS reach it as the FFI's exact
//  bytes (never a Petrel re-encoding, which injects a nested `$type` the Rust
//  parser rejects), and Circle feed/thread reads ask for encrypted items.
//

import Foundation
import Petrel
import PetrelCatbird
import Testing
@testable import Catbird

/// Captures every raw procedure body the gateway sends and answers with a
/// scripted output.
actor CapturingRawXRPC: CircleRawXRPC {
  struct Call: Sendable { let nsid: String; let body: Data }
  private(set) var calls: [Call] = []
  var response: Data = Data("{}".utf8)

  func setResponse(_ value: Data) { response = value }

  func procedure(_ nsid: String, body: Data) async throws -> Data {
    calls.append(Call(nsid: nsid, body: body))
    return response
  }
}

private enum RawFixtures {
  static let alice = "did:plc:alice"
  static let encryptedSpace = try! SpaceRef(uriString: "at:space/did:plc:alice/blue.catbird.circle.encrypted/3enc")
  static let circle = CircleSummary(
    uri: encryptedSpace, circleId: try! TID(tidString: "3l7familycirc"), name: "Close",
    owner: try! DID(didString: alice), memberCount: 1, muted: nil
  )

  /// A key record as the FFI emits it: `senderEpoch` has NO `$type`, keys are
  /// in Rust's order, and there is an unknown field. Petrel's typed encoder
  /// would add `"$type":"blue.catbird.labyrinth.defs#epochPublic"` here.
  static let keyRecordJSON = """
  {"$type":"blue.catbird.circle.key","circleId":"3l7familycirc","keyVersion":1,\
  "sender":{"$type":"blue.catbird.labyrinth.mek#labyrinthSender","did":"did:plc:alice",\
  "senderEpochHead":{"$bytes":"oaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaGhoaE"},\
  "senderEpoch":{"epochNumber":0,"authPubkey":{"$bytes":"AAEC"},"encryptionPubkey":{"$bytes":"AwQF"}}},\
  "recipients":[{"$bytes":"AAEC"}],"reason":"created","createdAt":"2026-11-07T12:00:00.000Z"}
  """

  static let postRecordJSON = """
  {"$type":"blue.catbird.circle.post","circleId":"3l7familycirc","keyVersion":1,\
  "createdAt":"2026-11-07T12:00:00.000Z","ciphertext":{"$bytes":"AgICAgIC"},\
  "sig":{"$bytes":"EREREREREQ"},"authorEpochHead":{"$bytes":"WlpaWlpaWlo"},\
  "reply":{"root":{"uri":"at://did:plc:bob/blue.catbird.circle.post/3l7postaaaaa","cid":"\(cid)"},\
  "parent":{"uri":"at://did:plc:bob/blue.catbird.circle.post/3l7postaaaaa","cid":"\(cid)"}}}
  """

  static var cid: String { CID.fromDAGCBOR(Data("raw-write".utf8)).string }

  static func putRecordOutput(rkey: String) -> Data {
    Data("{\"uri\":\"at://did:plc:alice/blue.catbird.circle.key/\(rkey)\",\"cid\":\"\(cid)\"}".utf8)
  }

  static func applyWritesOutput(uri: String) -> Data {
    Data("""
    {"results":[{"$type":"com.atproto.space.applyWrites#createResult","uri":"\(uri)","cid":"\(cid)"}]}
    """.utf8)
  }
}

@Suite("Circle raw record writes (C1) and encrypted reads (C4)", .serialized)
struct CircleRawWriteTests {
  private func gateway(_ raw: CapturingRawXRPC) async -> GatewayCircleTransport {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    return GatewayCircleTransport(client: client, repoDID: { RawFixtures.alice }, rawXRPC: raw)
  }

  @Test("A key record reaches putRecord as the FFI's exact bytes, with no injected nested $type")
  func keyRecordIsWrittenVerbatim() async throws {
    let raw = CapturingRawXRPC()
    await raw.setResponse(RawFixtures.putRecordOutput(rkey: "000001"))
    let transport = await gateway(raw)

    _ = try await transport.putKeyRecord(
      space: RawFixtures.encryptedSpace, rkey: "000001", recordJSON: RawFixtures.keyRecordJSON
    )

    let call = try #require(await raw.calls.first)
    #expect(call.nsid == "com.atproto.space.putRecord")
    let record = try #require(RawJSON.member("record", in: call.body))
    #expect(record == Data(RawFixtures.keyRecordJSON.utf8))
    let body = String(decoding: call.body, as: UTF8.self)
    #expect(!body.contains("blue.catbird.labyrinth.defs#epochPublic"))
    // The envelope around it is the ordinary putRecord input.
    let object = try #require(try JSONSerialization.jsonObject(with: call.body) as? [String: Any])
    #expect(object["repo"] as? String == RawFixtures.alice)
    #expect(object["collection"] as? String == CircleConfiguration.keyCollection)
    #expect(object["rkey"] as? String == "000001")
    #expect(object["space"] as? String == RawFixtures.encryptedSpace.uriString())
    #expect(object["validate"] as? Bool == false)
  }

  @Test("A sealed post reaches applyWrites as the FFI's exact bytes")
  func postRecordIsWrittenVerbatim() async throws {
    let raw = CapturingRawXRPC()
    let postURI = try ATProtocolURI(uriString: "at://did:plc:alice/blue.catbird.circle.post/3l7postbbbbbb")
    await raw.setResponse(RawFixtures.applyWritesOutput(uri: postURI.uriString()))
    let transport = await gateway(raw)

    let written = try await transport.publishEncryptedPost(
      destination: RawFixtures.circle, postURI: postURI, recordJSON: RawFixtures.postRecordJSON
    )

    #expect(written == postURI)
    let call = try #require(await raw.calls.first)
    #expect(call.nsid == "com.atproto.space.applyWrites")
    let writes = try #require(RawJSON.member("writes", in: call.body))
    let create = try #require(RawJSON.elements(in: writes)?.first)
    let value = try #require(RawJSON.member("value", in: create))
    #expect(value == Data(RawFixtures.postRecordJSON.utf8))
    let createObject = try #require(try JSONSerialization.jsonObject(with: create) as? [String: Any])
    #expect(createObject["$type"] as? String == "com.atproto.space.applyWrites#create")
    #expect(createObject["collection"] as? String == CircleConfiguration.postCollection)
    #expect(createObject["rkey"] as? String == "3l7postbbbbbb")
    // Petrel's strongRef/replyRef encoders would add these.
    let body = String(decoding: call.body, as: UTF8.self)
    #expect(!body.contains("com.atproto.repo.strongRef"))
    #expect(!body.contains("app.bsky.feed.post#replyRef"))
  }

  @Test("A post sealed for another account is refused before anything is sent")
  func foreignPostIsRefused() async throws {
    let raw = CapturingRawXRPC()
    let transport = await gateway(raw)
    let foreign = try ATProtocolURI(uriString: "at://did:plc:mallory/blue.catbird.circle.post/3l7postbbbbbb")

    await #expect(throws: CircleError.encryptionUnavailable) {
      _ = try await transport.publishEncryptedPost(
        destination: RawFixtures.circle, postURI: foreign, recordJSON: RawFixtures.postRecordJSON
      )
    }
    #expect(await raw.calls.isEmpty)
  }

  @Test("Malformed record JSON is never sent")
  func malformedRecordIsRefused() async throws {
    let raw = CapturingRawXRPC()
    let transport = await gateway(raw)
    await #expect(throws: CircleError.self) {
      _ = try await transport.putKeyRecord(space: RawFixtures.encryptedSpace, rkey: "000001", recordJSON: "{\"a\":")
    }
    #expect(await raw.calls.isEmpty)
  }

  @Test("Circle feed and thread reads ask for encrypted items")
  func readsIncludeEncrypted() throws {
    let feed = GatewayCircleTransport.feedParameters(space: RawFixtures.encryptedSpace, cursor: "c1")
    #expect(feed.includeEncrypted == true)
    #expect(feed.space == RawFixtures.encryptedSpace)
    #expect(feed.cursor == "c1")
    #expect(feed.asQueryItems().contains(URLQueryItem(name: "includeEncrypted", value: "true")) == true)

    let uri = try ATProtocolURI(uriString: "at://did:plc:bob/blue.catbird.circle.post/3l7postaaaaa")
    let thread = GatewayCircleTransport.threadParameters(uri: uri, space: RawFixtures.encryptedSpace)
    #expect(thread.includeEncrypted == true)
    #expect(thread.uri == uri)
    #expect(thread.asQueryItems().contains(URLQueryItem(name: "includeEncrypted", value: "true")) == true)
  }
}
