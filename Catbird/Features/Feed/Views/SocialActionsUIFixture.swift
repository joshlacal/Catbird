#if DEBUG
import Petrel
import SwiftData
import SwiftUI

/// Offline presentation entry point. No account bootstrap or authenticated
/// transport is available; individual action destinations are injected below.
struct SocialActionsUIFixture: View {
  @State private var appState: AppState?
  @State private var sceneContext: SceneNavigationContext?
  @State private var result = "No action selected"
  @State private var showingRecipients = false
  @State private var inspectingOwnLabels: Bool?
  @State private var stagedPost: ChatSharedPostPreview?
  @State private var message = ""
  @State private var fixtureSendCount = 0
  @State private var showingDrafts = false
  @State private var fixtureContainer: ModelContainer?

  var body: some View {
    NavigationStack {
      if let appState, let sceneContext {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text("Post actions")
              .font(.title2.bold())
            Text("A quiet afternoon by the water. A post to share with a friend.")
              .font(.body)
            HStack {
              Text("@river.test")
                .foregroundStyle(.secondary)
              Spacer()
              PostShareMenu(
                post: SocialActionsFixtureData.post,
                appState: appState,
                onChooseChat: { showingRecipients = true },
                onCopyLink: { result = $0.absoluteString }
              )
            }
            Divider()
            Text(result)
              .font(.callout)
              .textSelection(.enabled)
              .accessibilityIdentifier("socialFixtureResult")
            if stagedPost != nil {
              ChatMessageComposerView(
                text: $message,
                attachedPost: $stagedPost,
                conversationId: "fixtureconversation",
                onSend: { _, _ in
                  fixtureSendCount += 1
                  result = "Fixture Send tapped \(fixtureSendCount) time"
                },
                clearsDraftOnSend: false
              )
            }
            Divider()
            Button("Saved drafts") { showingDrafts = true }
              .accessibilityIdentifier("fixtureSavedDrafts")
            Button("Own account labels") { inspectingOwnLabels = true }
              .accessibilityIdentifier("fixtureOwnLabels")
            Button("Other account labels") { inspectingOwnLabels = false }
              .accessibilityIdentifier("fixtureOtherLabels")
            NavigationLink("Profile with Germ") {
              SocialFixtureProfile(appState: appState)
            }
            .accessibilityIdentifier("fixtureGermProfile")
          }
          .padding()
        }
        .environment(appState)
        .environment(sceneContext)
        .navigationTitle("Social actions")
        .sheet(isPresented: $showingDrafts) {
          DraftsListView(appState: appState) { draft in
            result = "Selected draft: \(draft.previewText)"
          }
          .environment(appState)
          .environment(sceneContext)
        }
        .sheet(isPresented: $showingRecipients) {
          ModernChatSelectionView(
            post: SocialActionsFixtureData.post,
            appState: appState,
            sceneContext: sceneContext,
            model: ShareRecipientSelectionModel(
              accountDID: SocialActionsFixtureData.viewerDID,
              originSceneID: sceneContext.sceneID,
              isOriginValid: { !sceneContext.isInvalidated },
              search: { query in
                if query.lowercased().contains("fail") { throw URLError(.notConnectedToInternet) }
                return [SocialActionsFixtureData.post.author]
              },
              resolve: { _ in "fixtureconversation" }
            ),
            conversations: [],
            onSelectConversation: { _ in
              stagedPost = PendingChatShare.makePreviewEmbed(from: SocialActionsFixtureData.post)
              result = "Post staged. No message sent."
              showingRecipients = false
            },
            onDismiss: { showingRecipients = false }
          )
          .environment(appState)
          .environment(sceneContext)
        }
        .sheet(isPresented: Binding(
          get: { inspectingOwnLabels != nil },
          set: { if !$0 { inspectingOwnLabels = nil } }
        )) {
          LabelsOnMeView(
            labels: SocialActionsFixtureData.labels(owned: inspectingOwnLabels == true),
            targetDescription: inspectingOwnLabels == true ? "Your fixture account" : "@river.test",
            viewerDID: SocialActionsFixtureData.viewerDID,
            reportingService: ReportingService(
              client: appState.atProtoClient!,
              reportTransport: { _, _ in false },
              activeAccountDID: { SocialActionsFixtureData.viewerDID }
            ),
            labelers: [SocialActionsFixtureData.labeler]
          )
          .environment(appState)
          .environment(sceneContext)
        }
      } else {
        ProgressView("Loading fixture")
      }
    }
    .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--social-large-text") ? .accessibility3 : .large)
    .task {
      let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
      let state = AppState(userDID: SocialActionsFixtureData.viewerDID, client: client)
      state.currentUserProfile = SocialActionsFixtureData.viewer
      AppStateManager.shared.setLifecycleForTesting(.authenticated(state))
      do {
        let container = try ModelContainer(for: DraftPost.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let local = try DraftPost.create(from: SocialActionsFixtureData.draft("A draft saved on this device."), accountDID: state.userDID)
        let recovery = try DraftPost.create(from: SocialActionsFixtureData.draft("My earlier wording, kept after an edit on another device."), accountDID: state.userDID)
        var recoveryState = DraftSyncState()
        recoveryState.recoveryReason = "Changed on another device. Your local version was preserved."
        recovery.syncMetadata = try JSONEncoder().encode(recoveryState)
        let media = try DraftPost.create(from: SocialActionsFixtureData.draft("A draft with a photo saved in another app."), accountDID: state.userDID)
        media.remoteId = "3fixturemedia"
        media.remoteMediaDeviceName = "Bluesky on iPhone"
        for draft in [local, recovery, media] { container.mainContext.insert(draft) }
        try container.mainContext.save()
        fixtureContainer = container
        state.composerDraftManager.configureForTesting(modelContext: container.mainContext)
      } catch {
        result = "Fixture storage error: \(error.localizedDescription)"
      }
      sceneContext = SceneNavigationContext(appState: state, sceneID: UUID())
      appState = state
    }
  }
}

private struct SocialFixtureProfile: View {
  let appState: AppState
  @State private var path = NavigationPath()
  @State private var editing = false
  @State private var viewModel: ProfileViewModel

  init(appState: AppState) {
    self.appState = appState
    _viewModel = State(initialValue: ProfileViewModel(
      client: appState.atProtoClient!,
      userDID: SocialActionsFixtureData.profile.did.didString(),
      currentUserDID: appState.userDID
    ))
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        ProfileHeader(
          profile: SocialActionsFixtureData.profile,
          viewModel: viewModel,
          appState: appState,
          isEditingProfile: $editing,
          path: $path,
          screenWidth: geometry.size.width,
          hideAvatar: true
        )
        .padding(.top, 20)
      }
    }
    .environment(appState)
    .navigationTitle("Profile")
  }
}

enum SocialActionsFixtureData {
  static let viewerDID = "did:plc:socialfixtureviewer"
  static func draft(_ text: String) -> PostComposerDraft {
    PostComposerDraft(
      postText: text, mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
    )
  }
  static let viewer = try! JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self, from: Data(#"{"did":"did:plc:socialfixtureviewer","handle":"viewer.test","displayName":"Fixture Viewer"}"#.utf8))
  static let profile = try! JSONDecoder().decode(AppBskyActorDefs.ProfileViewDetailed.self, from: Data(#"{"did":"did:plc:socialfixtureauthor","handle":"river.test","displayName":"River","description":"A profile with a declared external messaging action.","followersCount":12,"followsCount":24,"postsCount":50,"labels":[{"src":"did:plc:ar7c4by46qjdydhdevvrndac","uri":"did:plc:socialfixtureauthor","val":"joined-may","cts":"2026-05-28T00:00:00Z"}],"associated":{"germ":{"showButtonTo":"everyone","messageMeUrl":"https://germ.example/message"}}}"#.utf8))

  static func labels(owned: Bool) -> [ComAtprotoLabelDefs.Label] {
    [ComAtprotoLabelDefs.Label(
      src: try! DID(didString: ReportingService.officialBlueskyDID),
      uri: try! URI(uriString: owned ? viewerDID : profile.did.didString()),
      val: "joined-may",
      cts: ATProtocolDate(date: Date(timeIntervalSince1970: 1_780_000_000))
    )]
  }

  static let labeler: AppBskyLabelerDefs.LabelerViewDetailed = {
    let creator = try! JSONDecoder().decode(AppBskyActorDefs.ProfileView.self, from: Data(#"{"did":"did:plc:ar7c4by46qjdydhdevvrndac","handle":"labels.test","displayName":"Community Labels"}"#.utf8))
    return AppBskyLabelerDefs.LabelerViewDetailed(
      uri: try! ATProtocolURI(uriString: "at://did:plc:ar7c4by46qjdydhdevvrndac/app.bsky.labeler.service/self"),
      cid: CID.fromDAGCBOR(Data("labeler-fixture".utf8)),
      creator: creator,
      policies: .init(labelValues: [.init(rawValue: "joined-may")], labelValueDefinitions: [
        .init(identifier: "joined-may", severity: "inform", blurs: "none", locales: [
          .init(lang: LanguageCodeContainer(lang: Locale.Language(identifier: "en")), name: "Joined May 23", description: "This account joined the community in May. This is an informational label."),
        ]),
      ]),
      indexedAt: ATProtocolDate(date: Date(timeIntervalSince1970: 1_780_000_000))
    )
  }()
  static let post: AppBskyFeedDefs.PostView = {
    let author = try! JSONDecoder().decode(AppBskyActorDefs.ProfileViewBasic.self, from: Data(
      #"{"did":"did:plc:socialfixtureauthor","handle":"river.test","displayName":"River","associated":{"chat":{"allowIncoming":"all"}}}"#.utf8
    ))
    let date = ATProtocolDate(date: Date(timeIntervalSince1970: 1_780_000_000))
    return AppBskyFeedDefs.PostView(
      uri: try! ATProtocolURI(uriString: "at://did:plc:socialfixtureauthor/app.bsky.feed.post/3socialfixture"),
      cid: CID.fromDAGCBOR(Data("social-fixture".utf8)),
      author: author,
      record: .knownType(AppBskyFeedPost(
        text: "A quiet afternoon by the water. A post to share with a friend.",
        entities: nil, facets: nil, reply: nil, embed: nil, langs: nil,
        labels: nil, tags: nil, createdAt: date
      )),
      embed: nil, bookmarkCount: nil, replyCount: 0, repostCount: 0,
      likeCount: 0, quoteCount: nil, indexedAt: date, viewer: nil,
      labels: nil, threadgate: nil, debug: nil
    )
  }()
}
#endif
