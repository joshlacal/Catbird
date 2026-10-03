#if os(iOS)
import Observation
import Petrel
import SwiftData
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import Catbird

/// Component captures with measured SwiftUI geometry, recognized visible text,
/// and retained state. These do not qualify whole-app window/device resizing.
@MainActor
final class SocialComponentLayoutTests: XCTestCase {
  func testProfileLabelsAreEnumeratedAtLargeTextAndRTL() async throws {
    try await withFixture { state, _ in
      let original = try XCTUnwrap(SocialActionsFixtureData.labels(owned: false).first)
      let otherIssuer = try DID(didString: "did:plc:independentlabeler")
      let otherLabel = ComAtprotoLabelDefs.Label(
        src: otherIssuer, uri: original.uri, val: original.val, cts: original.cts
      )
      let otherLabeler = AppBskyLabelerDefs.LabelerViewDetailed(
        uri: try ATProtocolURI(uriString: "at://\(otherIssuer.didString())/app.bsky.labeler.service/self"),
        cid: SocialActionsFixtureData.labeler.cid,
        creator: .init(did: otherIssuer, handle: try Handle(handleString: "independent.labels.test"), displayName: "Independent Labels"),
        policies: .init(labelValues: [.init(rawValue: original.val)], labelValueDefinitions: [
          .init(identifier: original.val, severity: "inform", blurs: "none", locales: [
            .init(lang: LanguageCodeContainer(lang: Locale.Language(identifier: "en")),
              name: "Community membership verified after participation", description: "An informational membership label")
          ])
        ]),
        indexedAt: original.cts
      )
      // Two issuers can apply the same value; both must retain their own row and details.
      let labels = AccountLabelPresentation.accountLabels(
        [original, otherLabel], subjectDID: original.uri.uriString(),
        subscribedIssuers: [original.src.didString(), otherIssuer.didString()]
      )
      var selections: [String] = []
      for direction in [LayoutDirection.leftToRight, .rightToLeft] {
        let rows = ProfileAccountLabelsView(
          labels: labels, viewerDID: state.userDID, isActiveViewer: { true },
          labelers: [SocialActionsFixtureData.labeler, otherLabeler],
          onSelectLabel: { selections.append($0.id) }
        )
        let content = ScrollView { rows.padding(.horizontal, 16) }
          .environment(\.layoutDirection, direction)
        try await self.captureSizes(
          component: direction == .leftToRight ? "profile-label-list-ltr" : "profile-label-list-rtl",
          state: state, content: content,
          expectedText: { name in
            name == "short" ? ["Joined May 23", "Issued by"]
              : ["Joined May 23", "Community membership verified", "Issued by"]
          },
          validateState: { _ in
            XCTAssertEqual(labels.count, 2)
            XCTAssertEqual(Set(labels.map(\.id)).count, 2)
            XCTAssertTrue(selections.isEmpty, "Layout changes must not open an inspector")
            XCTAssertTrue(labels.allSatisfy { !ReportingService.canAppeal($0, viewerDID: state.userDID) })
          }
        )
      }
    }
  }

  func testLabelInspectorResizesAtLargeText() async throws {
    try await withFixture { state, client in
      let labels = SocialActionsFixtureData.labels(owned: false)
      let inspector = LabelsOnMeView(
        labels: labels,
        targetDescription: "A profile with a long display name and informational account labels",
        viewerDID: state.userDID,
        reportingService: ReportingService(
          client: client, reportTransport: { _, _ in false },
          activeAccountDID: { SocialActionsFixtureData.viewerDID }
        ),
        labelers: [SocialActionsFixtureData.labeler]
      )
      try await self.captureSizes(
        component: "account-labels", state: state, content: inspector,
        expectedText: { _ in ["labels"] }
      ) { _ in
        XCTAssertEqual(labels.count, 1)
        let label = try XCTUnwrap(labels.first)
        XCTAssertEqual(AccountLabelPresentation(label: label, labeler: SocialActionsFixtureData.labeler).name, "Joined May 23")
        XCTAssertFalse(ReportingService.canAppeal(label, viewerDID: state.userDID))
      }
    }
  }

  func testProfileGermActionResizesAtLargeText() async throws {
    try await withFixture { state, client in
      let model = ProfileViewModel(
        client: client, userDID: SocialActionsFixtureData.profile.did.didString(), currentUserDID: state.userDID
      )
      model.selectedProfileTab = .media
      let navigation = ProfileLayoutState()
      navigation.path.append("retained-profile-destination")
      let profile = ProfileLayoutContent(state: state, model: model, navigation: navigation)
      try await self.captureSizes(
        component: "profile-germ", state: state, content: profile,
        expectedText: { name in
          name == "short" ? ["River"] : ["joined-may", "Germ DM", "Following", "Followers", "Posts"]
        }
      ) { _ in
        XCTAssertEqual(model.selectedProfileTab, .media)
        XCTAssertEqual(navigation.path.count, 1)
        XCTAssertFalse(navigation.editing)
        XCTAssertEqual(model.currentUserDID, state.userDID)
        XCTAssertEqual(AccountLabelPresentation.accountLabels(
          SocialActionsFixtureData.profile.labels ?? [],
          subjectDID: SocialActionsFixtureData.profile.did.didString(),
          subscribedIssuers: [ReportingService.officialBlueskyDID]
        ).count, 1)
        XCTAssertNotNil(GermProfileAction.make(
          metadata: SocialActionsFixtureData.profile.associated?.germ,
          profileDID: SocialActionsFixtureData.profile.did.didString(), viewerDID: state.userDID,
          loadedForViewerDID: model.currentUserDID, profileFollowsViewer: false, isBlocked: false
        ))
      }
    }
  }

  func testSavedDraftsResizeWithoutChangingDrafts() async throws {
    try await withFixture { state, _ in
      let container = try ModelContainer(for: DraftPost.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
      let local = try DraftPost.create(from: SocialActionsFixtureData.draft("A draft saved on this device."), accountDID: state.userDID)
      let recovery = try DraftPost.create(from: SocialActionsFixtureData.draft("My earlier wording, preserved after another device edited the draft."), accountDID: state.userDID)
      var syncState = DraftSyncState()
      syncState.recoveryReason = "Changed on another device. Your local version was preserved."
      recovery.syncMetadata = try JSONEncoder().encode(syncState)
      let media = try DraftPost.create(from: SocialActionsFixtureData.draft("A draft with a photo saved in another app."), accountDID: state.userDID)
      media.remoteId = "3fixturemedia"
      media.remoteMediaDeviceName = "Bluesky on iPhone"
      let drafts = [local, recovery, media]
      for draft in drafts { container.mainContext.insert(draft) }
      try container.mainContext.save()
      // This DEBUG seam bypasses legacy migration and disables remote sync.
      state.composerDraftManager.configureForTesting(modelContext: container.mainContext)
      let originalIDs = state.composerDraftManager.savedDrafts.map(\.id)
      let originalBytes = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0.draftData) })
      var selectedIDs: [UUID] = []
      let list = DraftsListView(appState: state) { selectedIDs.append($0.id) }
      try await self.captureSizes(
        component: "saved-drafts", state: state, content: list,
        expectedText: { _ in ["Drafts", "Sync with Bluesky"] }
      ) { _ in
        XCTAssertFalse(state.composerDraftManager.isDraftSyncEnabled)
        XCTAssertEqual(state.composerDraftManager.savedDrafts.map(\.id), originalIDs)
        XCTAssertTrue(selectedIDs.isEmpty, "Resizing must not select or publish a draft")
        let stored = try container.mainContext.fetch(FetchDescriptor<DraftPost>())
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0.draftData) }), originalBytes)
        XCTAssertEqual(media.remoteId, "3fixturemedia")
        XCTAssertEqual(media.remoteMediaDeviceName, "Bluesky on iPhone")
        XCTAssertNotNil(recovery.syncMetadata)
      }
    }
  }

  func testShareRecipientSearchRetainsQueryAndResultsAcrossSizes() async throws {
    try await withFixture { state, _ in
      var queries: [String] = []
      var resolvedRecipients: [String] = []
      var selectedConversations: [String] = []
      var dismissCount = 0
      let sceneContext = SceneNavigationContext(appState: state, sceneID: UUID())
      let model = ShareRecipientSelectionModel(
        accountDID: state.userDID,
        originSceneID: sceneContext.sceneID,
        isOriginValid: { !sceneContext.isInvalidated && sceneContext.accountDID == state.userDID },
        search: { query in queries.append(query); return [SocialActionsFixtureData.post.author] },
        resolve: { recipient in resolvedRecipients.append(recipient); return "fixtureconversation" }
      )
      let picker = ModernChatSelectionView(
        post: SocialActionsFixtureData.post, appState: state, sceneContext: sceneContext, model: model,
        conversations: [], onSelectConversation: { selectedConversations.append($0) },
        onDismiss: { dismissCount += 1 }
      )
      try await self.captureSizes(
        component: "share-recipients", state: state, content: picker,
        expectedText: { _ in ["Sharing as", "viewer.test"] },
        prepare: { hostView in
          let searchField = try XCTUnwrap(self.descendants(of: hostView).compactMap { $0 as? UITextField }.first)
          searchField.text = "river"
          searchField.sendActions(for: .editingChanged)
          try await self.eventually {
            queries == ["river"] && !model.isSearching && model.searchResults.count == 1
          }
        }
      ) { hostView in
        let searchField = try XCTUnwrap(self.descendants(of: hostView).compactMap { $0 as? UITextField }.first)
        XCTAssertEqual(searchField.text, "river")
        XCTAssertEqual(queries, ["river"], "Changing geometry must not restart the search")
        XCTAssertEqual(model.searchResults.map(\.did), [SocialActionsFixtureData.post.author.did])
        XCTAssertTrue(model.isCurrent)
        XCTAssertFalse(model.isSelecting)
        XCTAssertTrue(resolvedRecipients.isEmpty, "A resize must not start a chat")
        XCTAssertTrue(selectedConversations.isEmpty)
        XCTAssertEqual(dismissCount, 0)
      }
    }
  }

  private func withFixture(_ operation: (AppState, ATProtoClient) async throws -> Void) async throws {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:9")!)
    let state = AppState(userDID: SocialActionsFixtureData.viewerDID, client: client)
    state.currentUserProfile = SocialActionsFixtureData.viewer
    let oldLifecycle = AppStateManager.shared.lifecycle
    AppStateManager.shared.setLifecycleForTesting(.authenticated(state))
    defer { AppStateManager.shared.setLifecycleForTesting(oldLifecycle) }
    try await operation(state, client)
  }

  private func captureSizes<Content: View>(
    component: String,
    state: AppState,
    content: Content,
    expectedText: (String) -> [String],
    prepare: ((UIView) async throws -> Void)? = nil,
    validateState: (UIView) throws -> Void
  ) async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
    let window = UIWindow(windowScene: scene)
    let parent = UIViewController()
    window.rootViewController = parent
    window.makeKeyAndVisible()
    defer { window.isHidden = true; previousKeyWindow?.makeKey() }
    let probe = ComponentLayoutProbe()
    let sceneContext = SceneNavigationContext(appState: state, sceneID: UUID())
    let host = UIHostingController(rootView: ObservedLayoutContent(content: content, probe: probe)
      .environment(state)
      .environment(sceneContext)
      .dynamicTypeSize(.accessibility2))
    // Deliberately asymmetric; do not derive one side from the opposite side.
    let extraInsets = UIEdgeInsets(top: 17, left: 23, bottom: 11, right: 5)
    host.additionalSafeAreaInsets = extraInsets
    parent.addChild(host)
    parent.view.addSubview(host.view)
    host.didMove(toParent: parent)
    defer {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }

    let sizes: [(String, CGSize)] = [
      ("narrow", CGSize(width: 320, height: 640)),
      ("wide", CGSize(width: 700, height: 450)),
      ("short", CGSize(width: 390, height: 350)),
      ("tall", CGSize(width: 390, height: 900)),
      ("square", CGSize(width: 500, height: 500)),
      ("returned-narrow", CGSize(width: 320, height: 640)),
    ]
    var measurements: [[String: Any]] = []
    var initialMeasuredSize: CGSize?
    for (index, entry) in sizes.enumerated() {
      let (name, size) = entry
      window.frame = CGRect(origin: .zero, size: size)
      parent.view.frame = window.bounds
      host.view.frame = CGRect(origin: .zero, size: size)
      host.view.setNeedsLayout()
      window.layoutIfNeeded()
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(180))
      if index == 0, let prepare { try await prepare(host.view) }
      host.view.layoutIfNeeded()
      XCTAssertEqual(host.view.bounds.size, size, "Capture must match the requested component size")
      XCTAssertEqual(host.additionalSafeAreaInsets, extraInsets)
      XCTAssertGreaterThan(probe.size.width, 0, "SwiftUI must report its rendered size")
      XCTAssertGreaterThan(probe.size.height, 0)
      XCTAssertLessThanOrEqual(probe.size.width, size.width + 1)
      XCTAssertLessThanOrEqual(probe.size.height, size.height + 1)
      if index == 0 { initialMeasuredSize = probe.size }
      if name == "returned-narrow", let initialMeasuredSize { XCTAssertEqual(probe.size, initialMeasuredSize) }
      try validateState(host.view)

      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      XCTAssertEqual(image.size, size)
      let screenshot = XCTAttachment(image: image)
      screenshot.name = "\(component)-\(name)-\(Int(size.width))x\(Int(size.height))-accessibility2-asymmetric"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      let recognized = try recognizedText(in: image)
      let text = recognized.map(\.text).joined(separator: " ")
      for expected in expectedText(name) {
        XCTAssertTrue(text.localizedStandardContains(expected), "\(component)/\(name) must visibly render '\(expected)'; OCR found: \(text)")
      }
      measurements.append([
        "component": component, "case": name,
        "requestedWidth": size.width, "requestedHeight": size.height,
        "hostWidth": host.view.bounds.width, "hostHeight": host.view.bounds.height,
        "swiftUIWidth": probe.size.width, "swiftUIHeight": probe.size.height,
        "windowWidth": window.bounds.width, "windowHeight": window.bounds.height,
        "safeArea": ["top": host.view.safeAreaInsets.top, "left": host.view.safeAreaInsets.left,
                     "bottom": host.view.safeAreaInsets.bottom, "right": host.view.safeAreaInsets.right],
        "swiftUISafeArea": ["top": probe.insets.top, "left": probe.insets.leading,
                            "bottom": probe.insets.bottom, "right": probe.insets.trailing],
        "recognizedText": recognized.map { ["text": $0.text, "normalizedBounds": NSCoder.string(for: $0.bounds)] },
      ])
    }
    let receipt = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
    receipt.name = "\(component)-measured-component-layouts"
    receipt.lifetime = .keepAlways
    add(receipt)
  }

  private func descendants(of view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<30 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("The injected recipient search did not settle")
  }

  private func recognizedText(in image: UIImage) throws -> [(text: String, bounds: CGRect)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    let cgImage = try XCTUnwrap(image.cgImage)
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    return (request.results ?? []).compactMap { observation in
      observation.topCandidates(1).first.map { (text: $0.string, bounds: observation.boundingBox) }
    }.sorted { lhs, rhs in
      abs(lhs.bounds.midY - rhs.bounds.midY) > 0.01 ? lhs.bounds.midY > rhs.bounds.midY : lhs.bounds.minX < rhs.bounds.minX
    }
  }
}

@MainActor
@Observable
private final class ComponentLayoutProbe {
  var size = CGSize.zero
  var insets = EdgeInsets()
}

private struct ObservedLayoutContent<Content: View>: View {
  let content: Content
  let probe: ComponentLayoutProbe

  var body: some View {
    content.background {
      GeometryReader { geometry in
        Color.clear
          .onAppear { record(geometry) }
          .onChange(of: geometry.size) { _, _ in record(geometry) }
          .onChange(of: geometry.safeAreaInsets) { _, _ in record(geometry) }
      }
    }
  }

  private func record(_ geometry: GeometryProxy) {
    probe.size = geometry.size
    probe.insets = geometry.safeAreaInsets
  }
}

@MainActor
@Observable
private final class ProfileLayoutState {
  var path = NavigationPath()
  var editing = false
}

private struct ProfileLayoutContent: View {
  let state: AppState
  let model: ProfileViewModel
  let navigation: ProfileLayoutState

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        ProfileHeader(
          profile: SocialActionsFixtureData.profile, viewModel: model, appState: state,
          isEditingProfile: Binding(get: { navigation.editing }, set: { navigation.editing = $0 }),
          path: Binding(get: { navigation.path }, set: { navigation.path = $0 }),
          screenWidth: geometry.size.width, hideAvatar: true
        )
        .padding(.top, 20)
      }
    }
  }
}
#endif
