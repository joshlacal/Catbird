#if DEBUG && os(iOS)
import Petrel
import SwiftUI
import UIKit

/// Offline diagnostics inside the production window owner and presentation host.
/// Route leaves are deliberately local; this does not exercise authenticated feeds.
@MainActor
struct SceneRuntimeFixture: View {
  static let launchArgument = "--scene-runtime-ui-fixture"
  static let accountDID = "did:plc:sceneruntimefixturetesta"
  private static var sharedAccountTask: Task<AppState, Never>?

  let scene: SceneWindowState
  private let suppliedAccount: AppState?
  @State private var account: AppState?
  @State private var issue: String?
  @State private var sessionIdentifier = "unattached"
  @State private var receivingSize = CGSize.zero
  @Environment(\.openWindow) private var openWindow
  @Environment(\.dismissWindow) private var dismissWindow

  init(scene: SceneWindowState, account: AppState? = nil) {
    self.scene = scene
    self.suppliedAccount = account
  }

  var body: some View {
    Group {
      if let account, let context = scene.context, !context.isInvalidated {
        SceneNavigationHost(
          appState: account, appStateManager: .shared, context: context
        ) {
          VStack(spacing: 12) {
            ScrollView {
              VStack(alignment: .leading, spacing: 8) {
                Text("Offline scene diagnostics").font(.headline)
                Text("Scene: \(scene.sceneID.uuidString)")
                  .accessibilityIdentifier("scene-runtime.scene")
                Text("Session: \(sessionIdentifier)")
                  .accessibilityIdentifier("scene-runtime.session")
                Text("Context: \(context.activityRegistrationID.uuidString)")
                  .accessibilityIdentifier("scene-runtime.context")
                Text("Account: \(context.accountDID)")
                  .accessibilityIdentifier("scene-runtime.account")
                Text("Services: \(String(describing: ObjectIdentifier(account)))")
                  .accessibilityIdentifier("scene-runtime.services")
                Text("Receiving: \(Int(receivingSize.width)) × \(Int(receivingSize.height))")
                  .accessibilityIdentifier("scene-runtime.bounds")
                Text("Tab: \(context.navigationManager.currentTabIndex)")
                  .accessibilityIdentifier("scene-runtime.tab")
                Text("Paths: \(pathDescription(context))")
                  .accessibilityIdentifier("scene-runtime.paths")
                Text("Claim: \(context.composerEditingSession.activeClaim?.token.uuidString ?? "none")")
                  .accessibilityIdentifier("scene-runtime.claim")
                Text("Draft: \(context.composerEditingSession.currentDraft?.postText ?? "none")")
                  .accessibilityIdentifier("scene-runtime.draft")
                Text("Anchor: \(Self.viewport(in: context).getScrollAnchor()?.postID ?? "none")")
                  .accessibilityIdentifier("scene-runtime.anchor")
                if let issue { Text(issue).foregroundStyle(.red) }
                HStack {
                  Button("Seed this window") {
                    do { try Self.seed(context) }
                    catch { issue = error.localizedDescription }
                  }
                  .accessibilityIdentifier("scene-runtime.seed")
                  Button("Other tab") {
                    let manager = context.navigationManager
                    manager.updateCurrentTab(manager.currentTabIndex == 1 ? 3 : 1)
                  }
                  .accessibilityIdentifier("scene-runtime.other-tab")
                }
                HStack {
                  Button("New window") { openWindow(id: "main") }
                    .accessibilityIdentifier("scene-runtime.new-window")
                  Button("Close this window") { dismissWindow() }
                    .accessibilityIdentifier("scene-runtime.close-window")
                }
              }
              .font(.caption.monospaced())
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding()
            }
            NavigationStack(path: context.navigationManager.pathBinding(
              for: context.navigationManager.currentTabIndex
            )) {
              Text("Local route root")
                .navigationTitle("Scene root")
                .navigationDestination(for: NavigationDestination.self) { _ in
                  Text("Local route in \(scene.sceneID.uuidString)")
                    .accessibilityIdentifier("scene-runtime.destination")
                    .navigationTitle("Scene marker")
                }
            }
            .frame(height: 180)
          }
        }
      } else {
        ProgressView(scene.isDisconnected ? "Window disconnected" : "Preparing offline scene")
      }
    }
    .background {
      SceneRuntimeSessionIdentifier { sessionIdentifier = $0 }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { receivingSize = $0 }
    .task {
      // Root initial observation runs first. No authentication or shared
      // lifecycle mutation is needed to exercise this window's account owner.
      await Task.yield()
      let prepared: AppState
      if let suppliedAccount {
        prepared = suppliedAccount
      } else {
        if Self.sharedAccountTask == nil {
          Self.sharedAccountTask = Task { await Self.makeAccount() }
        }
        guard let preparation = Self.sharedAccountTask else { return }
        prepared = await preparation.value
      }
      guard !Task.isCancelled, !scene.isDisconnected else { return }
      account = prepared
      scene.updateAccount(prepared)
    }
  }

  /// Construction only: this fixture never initializes account services, loads
  /// remote content, adopts authentication, or changes the manager lifecycle.
  static func makeAccount(did: String = accountDID) async -> AppState {
    let client = await ATProtoClient(baseURL: URL(string: "http://127.0.0.1:1")!)
    return AppState(userDID: did, client: client, regulatoryChecker: NoAgePrompt())
  }

  static func viewport(in context: SceneNavigationContext) -> FeedViewportState {
    context.feedViewportStore.state(accountDID: context.accountDID, feedIdentifier: "timeline")
  }

  @discardableResult
  static func seed(_ context: SceneNavigationContext) throws -> ComposerDraftClaim {
    let marker = "window-\(context.sceneID.uuidString.lowercased())"
    context.navigationManager.updateCurrentTab(1)
    context.navigationManager.clearPath(for: 1)
    _ = context.urlHandler.handle(URL(string: "tag://\(marker)")!, tabIndex: 1)
    let draft = makeDraft("Draft for \(marker)")
    let claim: ComposerDraftClaim
    if let existing = context.composerEditingSession.activeClaim {
      guard context.composerEditingSession.update(draft, claim: existing) else {
        throw ComposerEditingError.staleClaim
      }
      claim = existing
    } else {
      claim = try context.composerEditingSession.beginNew(draft: draft)
    }
    viewport(in: context).setScrollAnchor(.init(
      postID: marker, offsetFromTop: 37, timestamp: Date(), capturedTopInset: 64
    ))
    return claim
  }

  static func makeDraft(_ text: String) -> PostComposerDraft {
    PostComposerDraft(
      postText: text, mediaItems: [], videoItem: nil, selectedGif: nil,
      selectedLanguages: [], selectedLabels: [], outlineTags: [], threadEntries: [],
      isThreadMode: false, currentThreadIndex: 0, parentPostURI: nil, quotedPostURI: nil
    )
  }

  private func pathDescription(_ context: SceneNavigationContext) -> String {
    (0...4).map { "\($0)=\(context.navigationManager.tabPaths[$0]?.count ?? 0)" }
      .joined(separator: ", ")
  }

  private struct NoAgePrompt: AgeRegulatoryChecking {
    func preflight() async -> PlatformAgeSignal {
      PlatformAgeSignal(requirement: .none, ageBand: nil, significantChangeConsentRequired: false)
    }
    @MainActor
    func requestAgeBand(from viewController: UIViewController) async throws -> AgeBand? { nil }
  }
}

/// Reports the real platform session; two UIWindows in one session must not be
/// misreported as two independently created OS scenes.
private struct SceneRuntimeSessionIdentifier: UIViewRepresentable {
  var report: (String) -> Void

  func makeUIView(context: Context) -> IdentifierView {
    let view = IdentifierView()
    view.report = report
    return view
  }

  func updateUIView(_ uiView: IdentifierView, context: Context) {
    uiView.report = report
    uiView.publish()
  }

  final class IdentifierView: UIView {
    var report: ((String) -> Void)?
    private var lastIdentifier: String?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      publish()
    }

    func publish() {
      guard let identifier = window?.windowScene?.session.persistentIdentifier,
            identifier != lastIdentifier else { return }
      lastIdentifier = identifier
      Task { @MainActor [weak self] in self?.report?(identifier) }
    }
  }
}
#endif
