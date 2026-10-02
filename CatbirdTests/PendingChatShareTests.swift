@testable import Catbird
import Petrel
import Foundation
import Testing

struct PendingChatShareTests {
  @Test("Shared-post preview carries its author and text")
  func previewEmbedCarriesAuthorAndText() throws {
    let post = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc"),
      authorDID: try DID(didString: "did:plc:author"),
      text: "A post to discuss"
    )

    let preview = PendingChatShare.makePreviewEmbed(from: post)

    #expect(preview.authorDisplayName == "Author")
    #expect(preview.authorHandle == "author.test")
    #expect(preview.text == "A post to discuss")
  }

  @Test("An unavailable record preserves the author without inventing preview text")
  func unknownRecordHasNoPreviewText() throws {
    let post = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc"),
      authorDID: try DID(didString: "did:plc:author"),
      record: .object([:])
    )

    let preview = PendingChatShare.makePreviewEmbed(from: post)

    #expect(preview.authorHandle == "author.test")
    #expect(preview.text == "")
  }
}

@MainActor
struct PendingChatShareOwnershipTests {
  private func share(account: String, conversation: String = "conversation") throws -> PendingChatShare {
    let post = PublicPostTestFixtures.makePostView(
      uri: try ATProtocolURI(uriString: "at://did:plc:author/app.bsky.feed.post/3kabc"),
      authorDID: try DID(didString: "did:plc:author")
    )
    return PendingChatShare(
      accountDID: account, convoId: conversation,
      postRef: ComAtprotoRepoStrongRef(uri: post.uri, cid: post.cid),
      previewEmbed: PendingChatShare.makePreviewEmbed(from: post)
    )
  }

  @Test("Pending post handoffs are account and conversation scoped, and consumed once")
  func accountIsolationAndSingleConsumption() throws {
    let store = PendingChatShareStore()
    let first = try share(account: "did:plc:first")
    let second = try share(account: "did:plc:second")
    store.stage(first)
    store.stage(second)
    #expect(store.consume(accountDID: second.accountDID, convoId: first.convoId, expectedID: first.id) == nil)
    #expect(store.consume(accountDID: first.accountDID, convoId: "another", expectedID: first.id) == nil)
    #expect(store.consume(accountDID: first.accountDID, convoId: first.convoId, expectedID: first.id)?.id == first.id)
    #expect(store.consume(accountDID: first.accountDID, convoId: first.convoId, expectedID: first.id) == nil)
    #expect(store.peek(accountDID: second.accountDID, convoId: second.convoId)?.id == second.id)
  }

  @Test("An old confirmation cannot consume a newer shared post")
  func staleConfirmationPreservesNewShare() throws {
    let store = PendingChatShareStore()
    let first = try share(account: "did:plc:first")
    let replacement = try share(account: "did:plc:first")
    store.stage(first)
    let revision = store.revision
    store.stage(replacement)
    #expect(store.revision > revision)
    #expect(store.consume(accountDID: first.accountDID, convoId: first.convoId, expectedID: first.id) == nil)
    #expect(store.peek(accountDID: first.accountDID, convoId: first.convoId)?.id == replacement.id)
  }

  @Test("Staging a shared post preserves typed message text")
  func stagingPreservesDraftText() throws {
    let pending = try share(account: "did:plc:first")
    var draft = BlueskyConversationDraft()
    draft.text = "My existing unsent thoughts"
    pending.apply(to: &draft)
    #expect(draft.text == "My existing unsent thoughts")
    #expect(draft.postRef == pending.postRef)
    #expect(draft.attachedEmbed?.text == pending.previewEmbed.text)
  }

  @Test("Copy and native sharing use the same DID fallback URL")
  func fallbackURL() {
    #expect(ActionButtonViewModel.shareURL(handle: "handle.invalid", did: "did:plc:author", recordKey: "3kabc")?.absoluteString == "https://bsky.app/profile/did:plc:author/post/3kabc")
    #expect(ActionButtonViewModel.shareURL(handle: "author.test", did: "did:plc:author", recordKey: "3kabc")?.absoluteString == "https://bsky.app/profile/author.test/post/3kabc")
    #expect(ActionButtonViewModel.shareURL(handle: "author.test", did: "did:plc:author", recordKey: nil) == nil)
  }
}

#if os(iOS)
@MainActor
private final class SuspendedShareResult<Value> {
  private var continuation: CheckedContinuation<Value, Error>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var started = false

  func request() async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      self.started = true
      for waiter in self.startWaiters { waiter.resume() }
      self.startWaiters = []
    }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { self.startWaiters.append($0) }
  }

  func finish(_ value: Value) {
    continuation?.resume(returning: value)
    continuation = nil
  }
}

@MainActor
struct ShareRecipientSelectionTests {
  private let account = "did:plc:owner"

  private func profile(_ suffix: String, policy: String = "all", viewer: [String: Any] = [:]) throws -> AppBskyActorDefs.ProfileViewBasic {
    let json: [String: Any] = [
      "did": "did:plc:\(suffix)", "handle": "\(suffix).test",
      "associated": ["chat": ["allowIncoming": policy]], "viewer": viewer
    ]
    return try JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self, from: JSONSerialization.data(withJSONObject: json))
  }

  @Test("Older typeahead results cannot replace the latest query")
  func latestSearchWins() async throws {
    let first = SuspendedShareResult<[AppBskyActorDefs.ProfileViewBasic]>()
    let second = SuspendedShareResult<[AppBskyActorDefs.ProfileViewBasic]>()
    let model = ShareRecipientSelectionModel(accountDID: account, activeAccount: { self.account }, search: { query in
      try await (query == "first" ? first : second).request()
    }, resolve: { _ in "unused" })
    let firstTask = Task { await model.searchRecipients("first", debounce: .zero) }
    await first.waitUntilStarted()
    let secondTask = Task { await model.searchRecipients("second", debounce: .zero) }
    await second.waitUntilStarted()
    second.finish([try profile("second")])
    await secondTask.value
    first.finish([try profile("first")])
    await firstTask.value
    #expect(model.searchResults.map { $0.did.didString() } == ["did:plc:second"])
    #expect(!model.isSearching)
  }

  @Test("Clearing the search cannot resurrect an old result")
  func clearingSearchInvalidatesResult() async throws {
    let request = SuspendedShareResult<[AppBskyActorDefs.ProfileViewBasic]>()
    let model = ShareRecipientSelectionModel(accountDID: account, activeAccount: { self.account }, search: { _ in
      try await request.request()
    }, resolve: { _ in "unused" })
    let task = Task { await model.searchRecipients("person", debounce: .zero) }
    await request.waitUntilStarted()
    await model.searchRecipients("", debounce: .zero)
    request.finish([try profile("person")])
    await task.value
    #expect(model.searchResults.isEmpty)
    #expect(!model.isSearching)
  }

  @Test("Dismissed and switched-account recipient lookups cannot navigate")
  func cancelledOrSwitchedSelection() async {
    for dismiss in [false, true] {
      let request = SuspendedShareResult<String>()
      var activeAccount: String? = account
      let model = ShareRecipientSelectionModel(accountDID: account, activeAccount: { activeAccount }, search: { _ in [] }, resolve: { _ in
        try await request.request()
      })
      let task = Task { await model.select(recipientDID: "did:plc:recipient") }
      await request.waitUntilStarted()
      if dismiss { model.cancel() } else { activeAccount = "did:plc:other" }
      request.finish("must-not-open")
      #expect(await task.value == nil)
      #expect(model.errorMessage == nil)
    }
  }

  @Test("Repeated taps make one lookup and eligibility failure remains visible")
  func repeatedSelectionAndFailure() async {
    let request = SuspendedShareResult<String>()
    var lookups = 0
    let model = ShareRecipientSelectionModel(accountDID: account, activeAccount: { self.account }, search: { _ in [] }, resolve: { _ in
      lookups += 1
      _ = try await request.request()
      throw ShareRecipientError.unavailable
    })
    let task = Task { await model.select(recipientDID: "did:plc:recipient") }
    await request.waitUntilStarted()
    #expect(await model.select(recipientDID: "did:plc:other") == nil)
    request.finish("ignored")
    #expect(await task.value == nil)
    #expect(lookups == 1)
    #expect(model.errorMessage == ShareRecipientError.unavailable.localizedDescription)
    #expect(!model.isSelecting)
  }

  @Test("Search failure is visible and a later successful query recovers")
  func searchFailureAndRetry() async throws {
    let recipient = try profile("recipient")
    let model = ShareRecipientSelectionModel(accountDID: account, activeAccount: { self.account }, search: { query in
      if query == "fail" { throw ShareRecipientError.lookupFailed }
      return [recipient]
    }, resolve: { _ in "unused" })
    await model.searchRecipients("fail", debounce: .zero)
    #expect(model.errorMessage != nil)
    await model.searchRecipients("retry", debounce: .zero)
    #expect(model.errorMessage == nil)
    #expect(model.searchResults.count == 1)
  }

  @Test("Recipient messaging policy uses follows-viewer direction and denies blocked/unknown policy")
  func recipientEligibility() throws {
    #expect(ShareRecipientSelectionModel.canMessage(try profile("all")))
    #expect(!ShareRecipientSelectionModel.canMessage(try profile("none", policy: "none")))
    #expect(!ShareRecipientSelectionModel.canMessage(try profile("unknown", policy: "future")))
    #expect(!ShareRecipientSelectionModel.canMessage(try profile("following", policy: "following", viewer: ["following": "at://did:plc:owner/app.bsky.graph.follow/3abc"])))
    #expect(ShareRecipientSelectionModel.canMessage(try profile("followed", policy: "following", viewer: ["followedBy": "at://did:plc:followed/app.bsky.graph.follow/3abc"])))
    #expect(!ShareRecipientSelectionModel.canMessage(try profile("blocked", viewer: ["blockedBy": true])))
  }
}
#endif
