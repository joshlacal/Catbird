import Foundation
import Petrel
import Testing
@testable import Catbird

@Suite("Post repost outcomes", .serialized)
@MainActor
struct PostViewModelRepostOutcomeTests {
  @Test("A missing repost record key throws and restores the previous state")
  func missingRecordKeyThrows() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    let appState = AppState(userDID: "did:plc:viewer", client: client)
    let post = PostViewModelTestFixtures.testPost
    let incompleteURI = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost")
    let viewModel = PostViewModel(post: post, appState: appState)
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      shadow.decideRepost(incompleteURI)
    }
    await viewModel.checkInteractionState()

    do {
      _ = try await viewModel.toggleRepost()
      Issue.record("A repost without a record key must throw instead of returning a success-like result.")
    } catch PostViewModel.PostViewModelError.unableToFindRecordKey {
      // The key check must run before getDid(), which rejects this unauthenticated client.
    }

    #expect(viewModel.isReposted)
    #expect(viewModel.repostUri == incompleteURI)
    let shadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
    #expect(shadow?.repostUri == incompleteURI)
  }

  @Test("A failed removal restores the real repost URI and keeps unrelated shadow state")
  func failedRemovalRestoresRecordURI() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    let appState = AppState(userDID: "did:plc:viewer", client: client)
    let post = PostViewModelTestFixtures.testPostWithLikeAndRepost
    let viewModel = PostViewModel(post: post, appState: appState)
    await viewModel.start(post: post)
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      shadow.bookmarked = true
      shadow.pinned = true
    }

    do {
      _ = try await viewModel.toggleRepost()
      Issue.record("Removing a repost with an unauthenticated client must fail.")
    } catch {
      #expect(String(describing: error).contains("unauthenticatedClient"))
    }

    #expect(viewModel.isReposted)
    #expect(viewModel.repostUri == post.viewer?.repost)
    let shadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
    #expect(shadow?.repostUri == post.viewer?.repost)
    #expect(shadow?.likeUri == post.viewer?.like)
    #expect(shadow?.bookmarked == true)
    #expect(shadow?.pinned == true)
    let merged = await appState.postShadowManager.mergeShadow(post: post)
    #expect(merged.repostCount == post.repostCount)
    #expect(merged.viewer?.repost == post.viewer?.repost)
  }

  @Test("A failed creation clears the optimistic repost placeholder")
  func failedCreationClearsOptimisticState() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    let appState = AppState(userDID: "did:plc:viewer", client: client)
    let post = PostViewModelTestFixtures.testPost
    let viewModel = PostViewModel(post: post, appState: appState)

    do {
      _ = try await viewModel.toggleRepost()
      Issue.record("Creating a repost with an unauthenticated client must fail.")
    } catch {
      #expect(String(describing: error).contains("unauthenticatedClient"))
    }

    #expect(!viewModel.isReposted)
    #expect(viewModel.repostUri == nil)
    let shadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
    #expect(shadow?.repostUri == nil)
    let merged = await appState.postShadowManager.mergeShadow(post: post)
    #expect(merged.repostCount == post.repostCount)
    #expect(merged.viewer?.repost == nil)
  }

  @Test("A failed removal preserves a usable shadow URI when the local URI has no key")
  func failedRemovalPreservesShadowFallback() async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    let appState = AppState(userDID: "did:plc:viewer", client: client)
    let post = PostViewModelTestFixtures.testPost
    let incompleteURI = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost")
    let actualURI = try ATProtocolURI(uriString: "at://did:plc:viewer/app.bsky.feed.repost/actual-repost")
    let viewModel = PostViewModel(post: post, appState: appState)
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      shadow.decideRepost(incompleteURI)
    }
    await viewModel.checkInteractionState()
    await appState.postShadowManager.updateShadow(forUri: post.uri.uriString()) { shadow in
      shadow.decideRepost(actualURI)
    }

    do {
      _ = try await viewModel.toggleRepost()
      Issue.record("Removing a repost with an unauthenticated client must fail.")
    } catch {
      // Reaching getDid proves that the fallback survived the optimistic shadow clear.
      #expect(String(describing: error).contains("unauthenticatedClient"))
    }

    #expect(viewModel.isReposted)
    #expect(viewModel.repostUri == actualURI)
    let shadow = await appState.postShadowManager.getShadow(forUri: post.uri.uriString())
    #expect(shadow?.repostUri == actualURI)
  }
}
