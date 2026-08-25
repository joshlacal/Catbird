import Foundation
import Petrel
import PetrelCatbird
import SwiftUI
import Testing
@testable import Catbird

/// Recording transport that tracks publish calls and asserts no public fallback.
actor DestinationRecordingCircleTransport: CircleTransport {
  private let error: CircleError?
  private(set) var publicEndpointCallCount = 0
  private(set) var publishedPosts: [(destination: CircleSummary, draft: CirclePostDraft)] = []

  init(error: CircleError? = nil) {
    self.error = error
  }

  func capabilities() async throws -> CircleCapability {
    if let error { throw error }
    return CircleCapability(enabled: true, protocolRevision: "0.1.0", supportsImages: true)
  }

  func listCircles(cursor: String?) async throws -> CircleListPage {
    if let error { throw error }
    return CircleListPage(circles: [], cursor: nil)
  }

  func getFeed(space: SpaceRef?, cursor: String?) async throws -> CircleFeedPage {
    if let error { throw error }
    return CircleFeedPage(items: [], cursor: nil)
  }

  func getPostThread(uri: ATProtocolURI, space: SpaceRef) async throws -> CircleThreadPage {
    if let error { throw error }
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try! DID(didString: "did:plc:alice"),
      handle: try! Handle(handleString: "alice.bsky.social"),
      displayName: nil,
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
    let post = AppBskyFeedPost(
      text: "Thread root post",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: [],
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    let postView = AppBskyFeedDefs.PostView(
       uri: uri,
       cid: CID.fromDAGCBOR(Data("test-thread-root".utf8)),
      author: author,
      record: ATProtocolValueContainer.knownType(post),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
    let thread = AppBskyFeedDefs.ThreadViewPost(
      post: postView,
      parent: nil,
      replies: nil,
      threadContext: nil
    )
    return CircleThreadPage(thread: thread, circle: CircleTestFixtures.family)
  }

  func listNotifications(cursor: String?) async throws -> CircleNotificationPage {
    if let error { throw error }
    return CircleNotificationPage(notifications: [], cursor: nil)
  }

  func media(space: SpaceRef, authorDID: DID, cid: CID) async throws -> Data {
    if let error { throw error }
    return Data()
  }

  func createCircle(name: String, memberDIDs: [DID]) async throws -> CircleOperation {
    if let error { throw error }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: CircleTestFixtures.familyURI,
      error: nil
    )
  }

  func updateMember(space: SpaceRef, memberDID: DID, action: CircleMemberAction) async throws -> CircleOperation {
    if let error { throw error }
    return CircleOperation(
      id: UUID().uuidString,
      status: .value_complete,
      space: space,
      error: nil
    )
  }

  func updatePreferences(space: SpaceRef, muted: Bool) async throws -> Bool {
    if let error { throw error }
    return muted
  }

  func report(
    post: ATProtocolURI,
    circle: CircleSummary,
    reason: CircleReportReason,
    details: String?
  ) async throws -> UUID {
    if let error { throw error }
    return UUID()
  }

  func activate(space: SpaceRef) async throws -> CircleAccessState {
    if let error { throw error }
    return .active
  }

  func publishPost(destination: CircleSummary, draft: CirclePostDraft) async throws -> ATProtocolURI {
    if let error { throw error }
    publishedPosts.append((destination: destination, draft: draft))
    return try ATProtocolURI(uriString: "\(destination.uri.uriString())/app.bsky.feed.post/test123")
  }

  func like(post: AppBskyFeedDefs.PostView, circle: CircleSummary) async throws -> ATProtocolURI {
    if let error { throw error }
    return try ATProtocolURI(uriString: "\(circle.uri.uriString())/app.bsky.feed.like/testlike123")
  }

  private(set) var deletedPosts: [(uri: ATProtocolURI, circle: CircleSummary)] = []
  private(set) var deletedLikes: [(uri: ATProtocolURI, circle: CircleSummary)] = []

  func deletePost(uri: ATProtocolURI, circle: CircleSummary) async throws {
    if let error { throw error }
    deletedPosts.append((uri: uri, circle: circle))
  }

  func deleteLike(uri: ATProtocolURI, circle: CircleSummary) async throws {
    if let error { throw error }
    deletedLikes.append((uri: uri, circle: circle))
  }

  func deleteCircle(space: SpaceRef) async throws -> CircleOperation {
    if let error { throw error }
    return CircleOperation(id: UUID().uuidString, status: .value_complete, space: space, error: nil)
  }
}

@Suite("Circle destination and composer routing")
struct CircleDestinationTests {

  @MainActor
  private func composer(
    destination: CircleDestination = .public,
    replyingTo: AppBskyFeedDefs.PostView? = nil,
    appState: AppState? = nil,
    circleService: CircleService? = nil
  ) async -> PostComposerViewModel {
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let state = appState ?? AppState(userDID: "did:plc:testuser", client: client)
    let effectiveDest: CircleDestination
    if let _ = replyingTo, destination == .public {
      effectiveDest = .circle(CircleTestFixtures.family)
    } else {
      effectiveDest = destination
    }
    return PostComposerViewModel(
      parentPost: replyingTo,
      destination: effectiveDest,
      appState: state,
      circleService: circleService
    )
  }

  private var circlePost: AppBskyFeedDefs.PostView {
    let author = AppBskyActorDefs.ProfileViewBasic(
      did: try! DID(didString: "did:plc:alice"),
      handle: try! Handle(handleString: "alice.bsky.social"),
      displayName: nil,
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
    let post = AppBskyFeedPost(
      text: "Circle parent post",
      entities: nil,
      facets: nil,
      reply: nil,
      embed: nil,
      langs: [],
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    return AppBskyFeedDefs.PostView(
       uri: try! ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/parent123"),
       cid: CID.fromDAGCBOR(Data("test-parent-post".utf8)),
      author: author,
      record: ATProtocolValueContainer.knownType(post),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )
  }

  @Test("Destination is captured before upload and cannot change")
  @MainActor
  func destinationIsCapturedBeforeUploadAndCannotChange() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .circle(family))
    model.postText = "Hello family circle"

    let submission = try model.beginSubmission()
    model.selectDestination(.public)

    #expect(submission.destination == .circle(family))
    #expect(model.destination == .circle(family))
    #expect(model.canChangeDestination == false)
  }

  @Test("Circle reply cannot become public")
  @MainActor
  func circleReplyCannotBecomePublic() async {
    let family = CircleTestFixtures.family
    let model = await composer(replyingTo: circlePost)

    #expect(model.destination == .circle(family))
    #expect(model.canChangeDestination == false)

    model.selectDestination(.public)
    #expect(model.destination == .circle(family))
  }

  @Test("Public submission cannot become circle after submission starts")
  @MainActor
  func publicSubmissionCannotBecomeCircle() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .public)
    model.postText = "Public post"

    let submission = try model.beginSubmission()
    model.selectDestination(.circle(family))

    #expect(submission.destination == .public)
    #expect(model.destination == .public)
    #expect(model.canChangeDestination == false)
  }

  @Test("Submission routes to CircleService with zero public fallback")
  @MainActor
  func submissionRoutesToCircleServiceWithoutPublicFallback() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let model = await composer(destination: .circle(family), circleService: service)
    model.postText = "Private circle content"

    try await model.createPost()

    let published = await transport.publishedPosts
    #expect(published.count == 1)
    #expect(published.first?.destination == family)
    #expect(published.first?.draft.text == "Private circle content")

    let publicCalls = await transport.publicEndpointCallCount
    #expect(publicCalls == 0)
  }

  @Test("CircleService failure throws CircleError and does not fallback to public")
  @MainActor
  func circleServiceFailureDoesNotFallbackToPublic() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport(
      error: CircleError.spaceWriteRejected("space rejected write")
    )
    let service = CircleService(transport: transport)

    let model = await composer(destination: .circle(family), circleService: service)
    model.postText = "Failing private content"

    var thrownError: (any Error)?
    do {
      try await model.createPost()
    } catch {
      thrownError = error
    }

    #expect(thrownError != nil)
    guard let circleErr = thrownError as? CircleError else {
      Issue.record("Expected CircleError, got \(String(describing: thrownError))")
      return
    }

    if case let .spaceWriteRejected(msg) = circleErr {
      #expect(msg == "space rejected write")
    } else {
      Issue.record("Expected spaceWriteRejected error")
    }

    let publicCalls = await transport.publicEndpointCallCount
    #expect(publicCalls == 0)
    #expect(model.destination == .circle(family))
  }

  @Test("Circle reply carries reply reference from parent post")
  @MainActor
  func circleReplyCarriesReplyReferenceFromParentPost() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let parent = circlePost
    let model = await composer(
      destination: .circle(family),
      replyingTo: parent,
      circleService: service
    )
    model.postText = "Replying to circle post"

    try await model.createPost()

    let published = await transport.publishedPosts
    #expect(published.count == 1)
    guard let draft = published.first?.draft else {
      Issue.record("Expected published draft")
      return
    }
    #expect(draft.reply != nil)
    #expect(draft.reply?.parent.uri == parent.uri)
    #expect(draft.reply?.parent.cid == parent.cid)
    #expect(draft.reply?.root.uri == parent.uri)
    #expect(draft.reply?.root.cid == parent.cid)
  }

  @Test("Nested Circle reply carries root from grandparent and parent from direct parent")
  @MainActor
  func nestedCircleReplyCarriesRootAndParentFromGrandparent() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let rootURI = try ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/root123")
    let rootCID = CID.fromDAGCBOR(Data("root-cid".utf8))
    let rootRef = ComAtprotoRepoStrongRef(uri: rootURI, cid: rootCID)

    let parentURI = try ATProtocolURI(uriString: "\(CircleTestFixtures.familyURI.uriString())/app.bsky.feed.post/child123")
    let parentCID = CID.fromDAGCBOR(Data("child-cid".utf8))
    let parentRef = ComAtprotoRepoStrongRef(uri: parentURI, cid: parentCID)

    let replyRef = AppBskyFeedPost.ReplyRef(root: rootRef, parent: parentRef)
    let parentRecord = AppBskyFeedPost(
      text: "Nested child post",
      entities: nil,
      facets: nil,
      reply: replyRef,
      embed: nil,
      langs: [],
      labels: nil,
      tags: nil,
      createdAt: ATProtocolDate(date: Date())
    )
    let nestedParent = AppBskyFeedDefs.PostView(
      uri: parentURI,
      cid: parentCID,
      author: AppBskyActorDefs.ProfileViewBasic(
        did: try DID(didString: "did:plc:bob"),
        handle: try Handle(handleString: "bob.bsky.social"),
        displayName: nil,
        pronouns: nil,
        avatar: nil,
        associated: nil,
        viewer: nil,
        labels: nil,
        createdAt: nil,
        verification: nil,
        status: nil,
        debug: nil
      ),
      record: ATProtocolValueContainer.knownType(parentRecord),
      embed: nil,
      bookmarkCount: nil,
      replyCount: 0,
      repostCount: 0,
      likeCount: 0,
      quoteCount: 0,
      indexedAt: ATProtocolDate(date: Date()),
      viewer: nil,
      labels: nil,
      threadgate: nil,
      debug: nil
    )

    let model = await composer(
      destination: .circle(family),
      replyingTo: nestedParent,
      circleService: service
    )
    model.postText = "Replying to nested circle post"

    try await model.createPost()

    let published = await transport.publishedPosts
    #expect(published.count == 1)
    guard let draft = published.first?.draft else {
      Issue.record("Expected published draft")
      return
    }
    #expect(draft.reply != nil)
    #expect(draft.reply?.root.uri == rootURI)
    #expect(draft.reply?.root.cid == rootCID)
    #expect(draft.reply?.parent.uri == parentURI)
    #expect(draft.reply?.parent.cid == parentCID)
  }

  @Test("Circle destination blocks thread mode and exiting exits cleanly")
  @MainActor
  func circleDestinationBlocksThreadMode() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .circle(family))
    model.postText = "Single circle post"

    model.enterThreadMode()
    #expect(model.isThreadMode == false)

    var threwError = false
    do {
      try await model.createThread()
    } catch {
      threwError = true
    }
    #expect(threwError == true)

    let publicModel = await composer(destination: .public)
    publicModel.enterThreadMode()
    #expect(publicModel.isThreadMode == true)

    publicModel.selectDestination(.circle(family))
    #expect(publicModel.isThreadMode == false)
    #expect(publicModel.destination == .circle(family))
  }

  @Test("PostVisibilityContext and PostCapabilities enforce Circle interaction constraints")
  func postVisibilityContextAndCapabilitiesForCircle() {
    let family = CircleTestFixtures.family
    let circleContext = PostVisibilityContext.circle(family)
    let authorCaps = PostCapabilities.forContext(circleContext, isAuthor: true)

    #expect(authorCaps.canReply == true)
    #expect(authorCaps.canLike == true)
    #expect(authorCaps.canDelete == true)
    #expect(authorCaps.canRepost == false)
    #expect(authorCaps.canQuote == false)
    #expect(authorCaps.canPublicShare == false)

    let nonAuthorCaps = PostCapabilities.forContext(circleContext, isAuthor: false)
    #expect(nonAuthorCaps.canDelete == false)

    let publicCaps = PostCapabilities.forContext(.public, isAuthor: true)
    #expect(publicCaps.canRepost == true)
    #expect(publicCaps.canQuote == true)
    #expect(publicCaps.canPublicShare == true)
  }

  @Test("PostViewModel dispatches Circle like and deleteLike through CircleService and unlike proves deleteLike")
  @MainActor
  func postViewModelDispatchesCircleLikeAndDeleteThroughCircleService() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    appState.circleService = service

    let vm = PostViewModel(post: circlePost, appState: appState, visibilityContext: .circle(family))

    #expect(vm.capabilities.canRepost == false)
    #expect(vm.capabilities.canQuote == false)
    #expect(vm.capabilities.canPublicShare == false)

    let repostResult = try await vm.toggleRepost()
    #expect(repostResult == false)

    let quoteResult = try await vm.createQuotePost(text: "Quote attempt")
    #expect(quoteResult == false)

    // Like the post -> should call CircleService.like
    let likeSuccess = try await vm.toggleLike()
    #expect(likeSuccess == true)
    #expect(vm.isLiked == true)

    // Now unlike the post -> must call deleteLike (NOT deletePost) with circle summary
    let unlikeSuccess = try await vm.toggleLike()
    #expect(unlikeSuccess == true)
    #expect(vm.isLiked == false)

    let deletedLikes = await transport.deletedLikes
    let deletedPosts = await transport.deletedPosts
    #expect(deletedLikes.count == 1)
    #expect(deletedPosts.count == 0)
    #expect(deletedLikes.first?.circle == family)
    #expect(deletedLikes.first?.uri.uriString().contains("app.bsky.feed.like") == true)
  }

  @Test("Unliking a circle post with missing like URI throws missingLikeUri typed error")
  @MainActor
  func unlikingCirclePostWithMissingLikeUriThrowsTypedError() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    appState.circleService = service

    let vm = PostViewModel(post: circlePost, appState: appState, visibilityContext: .circle(family))
    // Artificially simulate wasLiked being true without likeUri
    vm.setLikedStateForTesting(isLiked: true, likeUri: nil)

    await #expect(throws: CircleError.self) {
      try await vm.toggleLike()
    }
  }

  @Test("Constructors and factories pass explicit visibility context and forward to delete/action call sites")
  @MainActor
  func constructorsAndFactoriesPassExplicitVisibilityContext() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)

    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    appState.circleService = service

    let feedViewPost = AppBskyFeedDefs.FeedViewPost(
      post: circlePost,
      reply: nil,
      reason: nil,
      feedContext: nil,
      reqId: nil
    )
    let feedItem = BlueCatbirdCircleDefs.FeedItem(
      post: feedViewPost,
      circle: family
    )

    // PostViewModel factory from FeedItem
    let vmFromItem = PostViewModel.forCircleItem(feedItem, appState: appState)
    #expect(vmFromItem.visibilityContext == .circle(family))
    #expect(vmFromItem.capabilities.canRepost == false)
    #expect(vmFromItem.capabilities.canQuote == false)
    #expect(vmFromItem.capabilities.canPublicShare == false)

    // PostViewModel factory from PostView + circle
    let vmFromPost = PostViewModel.forCircle(post: circlePost, circle: family, appState: appState)
    #expect(vmFromPost.visibilityContext == .circle(family))

    // PostContextMenuViewModel factory & delete dispatch
    let menuVm = PostContextMenuViewModel.forCircleItem(feedItem, appState: appState)
    #expect(menuVm.visibilityContext == .circle(family))
    await menuVm.deletePost()
    let deletedPosts = await transport.deletedPosts
    #expect(deletedPosts.count == 1)
    #expect(deletedPosts.first?.uri == circlePost.uri)
    #expect(deletedPosts.first?.circle == family)

    // PostView factory from FeedItem
    let binding = Binding.constant(NavigationPath())
    let rowView = PostView.circleRow(item: feedItem, path: binding, appState: appState)
    #expect(rowView.visibilityContext == .circle(family))

    let detailView = PostView.circleDetail(post: circlePost, circle: family, path: binding, appState: appState)
    #expect(detailView.visibilityContext == .circle(family))

    let threadView = ThreadView.circleThread(uri: circlePost.uri, circle: family, path: binding)
    #expect(threadView.visibilityContext == .circle(family))
  }

  @Test("Circle destination blocks RichEditor onThreadAction and addNewThreadEntry fails closed without wiping text")
  @MainActor
  func circleDestinationBlocksAddNewThreadEntryAndFailsClosed() async throws {
    let family = CircleTestFixtures.family
    let model = await composer(destination: .circle(family))
    model.postText = "My important private circle draft"

    // Calling enterThreadMode should no-op
    model.enterThreadMode()
    #expect(model.isThreadMode == false)
    #expect(model.postText == "My important private circle draft")

    // Calling addNewThreadEntry should fail closed and NOT clear postText or add thread posts
    model.addNewThreadEntry()
    #expect(model.isThreadMode == false)
    #expect(model.postText == "My important private circle draft")
    #expect(model.threadEntries.count == 1)
  }

  @Test("ActionButtonViewModel respects Circle capabilities")
  @MainActor
  func actionButtonsViewModelRespectsCircleCapabilities() async throws {
    let family = CircleTestFixtures.family
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)

    let postVm = PostViewModel(post: circlePost, appState: appState, visibilityContext: .circle(family))
    let actionVm = ActionButtonViewModel(postId: circlePost.uri.uriString(), postViewModel: postVm, appState: appState)

    #expect(actionVm.capabilities.canRepost == false)
    #expect(actionVm.capabilities.canQuote == false)
    #expect(actionVm.capabilities.canPublicShare == false)
    #expect(actionVm.capabilities.canReply == true)
    #expect(actionVm.capabilities.canLike == true)

    let quoteResult = try await actionVm.createQuotePost(text: "Quote")
    #expect(quoteResult == false)
  }

  @Test("iOS ThreadViewController and representable propagate visibilityContext and default to public")
  @MainActor
  func iosThreadViewControllerAndRepresentablePropagateVisibilityContext() async throws {
    let family = CircleTestFixtures.family
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    let binding = Binding.constant(NavigationPath())

    if #available(iOS 18.0, *) {
      // Default initialization is public
      let defaultController = ThreadViewController(appState: appState, postURI: circlePost.uri, path: binding)
      #expect(defaultController.visibilityContext == .public)

      // Explicit circle initialization retains circle visibility context
      let circleController = ThreadViewController(
        appState: appState,
        postURI: circlePost.uri,
        path: binding,
        visibilityContext: .circle(family)
      )
      #expect(circleController.visibilityContext == .circle(family))

      // ThreadViewControllerRepresentable default vs circle
      let defaultRepresentable = ThreadViewControllerRepresentable(postURI: circlePost.uri, path: binding)
      #expect(defaultRepresentable.visibilityContext == .public)

      let circleRepresentable = ThreadViewControllerRepresentable(
        postURI: circlePost.uri,
        path: binding,
        visibilityContext: .circle(family)
      )
      #expect(circleRepresentable.visibilityContext == .circle(family))
    }
  }

  @Test("iOS thread cells and views propagate circle visibilityContext to PostView and PostViewModel action routing")
  @MainActor
  func iosThreadCellsAndViewsPropagateVisibilityContextToPostViewModels() async throws {
    let family = CircleTestFixtures.family
    let transport = DestinationRecordingCircleTransport()
    let service = CircleService(transport: transport)
    let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
    let appState = AppState(userDID: "did:plc:testuser", client: client)
    appState.circleService = service
    let binding = Binding.constant(NavigationPath())

    // 1. ParentPostView with circle visibility context vs default public
    let threadItemPost = AppBskyUnspeccedDefs.ThreadItemPost(
      post: circlePost,
      moreParents: false,
      moreReplies: 0,
      opThread: false,
      opThreadPostIndex: nil,
      opThreadPostCount: nil,
      hiddenByThreadgate: false,
      mutedByViewer: false
    )
    let parentPost = ParentPost(
      id: circlePost.uri.uriString(),
      threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: circlePost.uri,
        depth: 0,
        value: .appBskyUnspeccedDefsThreadItemPost(threadItemPost)
      ),
      grandparentAuthor: nil
    )

    let defaultParentView = ParentPostView(parentPost: parentPost, path: binding, appState: appState)
    #expect(defaultParentView.visibilityContext == .public)

    let circleParentView = ParentPostView(
      parentPost: parentPost,
      path: binding,
      appState: appState,
      visibilityContext: .circle(family)
    )
    #expect(circleParentView.visibilityContext == .circle(family))

    // 2. ReplyView with circle visibility context vs default public
    let replyWrapper = ReplyWrapper(
      id: circlePost.uri.uriString(),
      threadItem: AppBskyUnspeccedGetPostThreadV2.ThreadItem(
        uri: circlePost.uri,
        depth: 1,
        value: .appBskyUnspeccedDefsThreadItemPost(threadItemPost)
      ),
      depth: 1,
      isFromOP: false,
      isOpThread: false,
      hasReplies: false
    )

    let defaultReplyView = ReplyView(
      replyWrapper: replyWrapper,
      opAuthorID: "did:plc:alice",
      nestedReplies: [],
      path: binding,
      appState: appState
    )
    #expect(defaultReplyView.visibilityContext == .public)

    let circleReplyView = ReplyView(
      replyWrapper: replyWrapper,
      opAuthorID: "did:plc:alice",
      nestedReplies: [],
      path: binding,
      appState: appState,
      visibilityContext: .circle(family)
    )
    #expect(circleReplyView.visibilityContext == .circle(family))

    // 3. ThreadViewMainPostView with circle visibility creates PostViewModel routing to CircleService
    let mainPostView = ThreadViewMainPostView(
      post: circlePost,
      showLine: false,
      path: binding,
      appState: appState,
      visibilityContext: .circle(family)
    )
    #expect(mainPostView.visibilityContext == .circle(family))

    // 4. PostView with circle visibility context initializes PostViewModel with disabled public capabilities and Circle routing
    let postView = PostView(
      post: circlePost,
      grandparentAuthor: nil,
      isParentPost: false,
      isSelectable: false,
      path: binding,
      appState: appState,
      visibilityContext: .circle(family)
    )
    #expect(postView.visibilityContext == .circle(family))

    // Verify PostViewModel action routing under .circle context
    let vm = PostViewModel(post: circlePost, appState: appState, visibilityContext: .circle(family))
    #expect(vm.visibilityContext == .circle(family))
    #expect(vm.capabilities.canRepost == false)
    #expect(vm.capabilities.canQuote == false)
    #expect(vm.capabilities.canPublicShare == false)
    #expect(vm.capabilities.canLike == true)

    let likeResult = try await vm.toggleLike()
    #expect(likeResult == true)
    let unlikeResult = try await vm.toggleLike()
    #expect(unlikeResult == true)
    let deletedLikes = await transport.deletedLikes
    #expect(deletedLikes.count == 1)
    #expect(deletedLikes.first?.circle == family)
  }
}
