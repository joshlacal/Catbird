//
//  ThreadManagerPrefillTests.swift
//  CatbirdTests
//
//  The tapped-post cache behind the thread anchor prefill (P080).
//

import Foundation
import Petrel
import Testing
@testable import Catbird

/// The cache is a process-wide static, so these tests run one at a time, start from an
/// empty cache and use their own URIs.
@Suite("Thread anchor prefill cache", .serialized)
struct ThreadManagerPrefillTests {
  private static let viewer = "did:plc:prefillviewer"

  init() {
    ThreadManager.clearPrefillCache()
  }

  private static func post(_ name: String) throws -> AppBskyFeedDefs.PostView {
    PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:prefillauthor/app.bsky.feed.post/\(name)"),
      authorDID: try DID(didString: "did:plc:prefillauthor"),
      text: name
    )
  }

  @Test("A stored post is returned once, and only to the account that stored it")
  func singleUseReadPerAccount() throws {
    let post = try Self.post("single-use")
    ThreadManager.storePrefillPost(post, userDID: "did:plc:prefillviewer-a")

    #expect(ThreadManager.prefillPost(for: post.uri, userDID: "did:plc:prefillviewer-b") == nil)
    #expect(ThreadManager.prefillPost(for: post.uri, userDID: "did:plc:prefillviewer-a") == post)
    #expect(ThreadManager.prefillPost(for: post.uri, userDID: "did:plc:prefillviewer-a") == nil)
  }

  @Test("Without an account nothing is stored or returned")
  func requiresAnAccount() throws {
    let post = try Self.post("no-account")
    ThreadManager.storePrefillPost(post, userDID: nil)
    ThreadManager.storePrefillPost(post, userDID: "")

    #expect(ThreadManager.prefillPost(for: post.uri, userDID: nil) == nil)
    #expect(ThreadManager.prefillPost(for: post.uri, userDID: "") == nil)
  }

  @Test("An entry is good for ten seconds")
  func entriesExpire() throws {
    let post = try Self.post("expiry")
    let stored = Date(timeIntervalSinceReferenceDate: 1_000)

    ThreadManager.storePrefillPost(post, userDID: Self.viewer, now: stored)
    #expect(ThreadManager.prefillPost(for: post.uri, userDID: Self.viewer, now: stored.addingTimeInterval(9.9)) == post)

    ThreadManager.storePrefillPost(post, userDID: Self.viewer, now: stored)
    #expect(ThreadManager.prefillPost(for: post.uri, userDID: Self.viewer, now: stored.addingTimeInterval(10)) == nil)
  }

  @Test("Storing a post prunes the entries that have expired")
  func storePrunesExpiredEntries() throws {
    let old = try Self.post("pruned-old")
    let new = try Self.post("pruned-new")
    let start = Date(timeIntervalSinceReferenceDate: 2_000)

    ThreadManager.storePrefillPost(old, userDID: Self.viewer, now: start)
    ThreadManager.storePrefillPost(new, userDID: Self.viewer, now: start.addingTimeInterval(11))

    // Read with a clock at which `old` would still be fresh: it is gone because the
    // second store pruned it.
    #expect(ThreadManager.prefillPost(for: old.uri, userDID: Self.viewer, now: start.addingTimeInterval(1)) == nil)
    #expect(ThreadManager.prefillPost(for: new.uri, userDID: Self.viewer, now: start.addingTimeInterval(12)) == new)
  }

  @Test("Clearing the cache drops every entry")
  func clearDropsEveryEntry() throws {
    let post = try Self.post("cleared")
    ThreadManager.storePrefillPost(post, userDID: Self.viewer)
    ThreadManager.clearPrefillCache()

    #expect(ThreadManager.prefillPost(for: post.uri, userDID: Self.viewer) == nil)
  }
}
