import Observation
import Petrel
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Owns a stable window identity independently of account content and layout.
@MainActor
@Observable
final class SceneWindowState {
  let sceneID: UUID
  private(set) var context: SceneNavigationContext?
  var pendingLaunchURL: URL?
  var unauthenticatedStarterPackItem: SceneStarterPackLandingItem?
  private(set) var isDisconnected = false

  @ObservationIgnored private let coordinator: SceneRouteCoordinator
  @ObservationIgnored private var phase: ScenePhase = .inactive
  @ObservationIgnored private var isPresentationAttached = false
  @ObservationIgnored private let feedActivity: SceneFeedActivityRegistration
  @ObservationIgnored private weak var accountState: AppState?
  @ObservationIgnored private var pendingComposerReopen: PendingComposerReopen?
  private(set) var starterPackFlowID: UUID?
  @ObservationIgnored private var starterPackResolution: Task<Void, Never>?
  @ObservationIgnored private var lifetimeObservation: SceneWindowLifetimeObservation?
  #if os(iOS)
  @ObservationIgnored private weak var presentingController: UIViewController?
  #endif

  init(
    sceneID: UUID = UUID(), coordinator: SceneRouteCoordinator? = nil,
    feedActivity: SceneFeedActivityRegistration? = nil
  ) {
    self.feedActivity = feedActivity ?? SceneFeedActivityRegistration()
    self.sceneID = sceneID
    self.coordinator = coordinator ?? .shared
  }

  /// Account replacement retains the window and its explicitly targeted pending routes.
  func updateAccount(_ appState: AppState?) {
    guard !isDisconnected else { return }
    if let context, !context.isInvalidated, accountState === appState {
      return
    }
    pendingComposerReopen = nil
    accountState = appState
    guard let appState else {
      feedActivity.replace(with: nil, phase: phase)
      context?.invalidate()
      context = nil
      coordinator.setActive(sceneID: sceneID, isActive: false)
      return
    }

    let context = SceneNavigationContext(appState: appState, sceneID: sceneID)
    // Register replaces and invalidates the old account without disconnecting this window.
    coordinator.register(context)
    self.context = context
    feedActivity.replace(with: context.activityRegistrationID, phase: phase)
    #if os(iOS)
    if let presentingController {
      context.urlHandler.registerTopViewController(presentingController)
    }
    #endif
    refreshActivity()
  }

  func updatePhase(_ phase: ScenePhase) {
    guard !isDisconnected else { return }
    self.phase = phase
    refreshActivity()
    feedActivity.update(phase: phase)
  }

  func setPresentationAttached(_ attached: Bool) {
    isPresentationAttached = attached
    refreshActivity()
  }

  func markFocused() {
    guard !isDisconnected else { return }
    coordinator.markFocused(sceneID: sceneID)
  }

  private func refreshActivity() {
    coordinator.setActive(
      sceneID: sceneID,
      isActive: !isDisconnected && isPresentationAttached && phase == .active
    )
  }

  func retainLaunchURL(_ url: URL) {
    pendingLaunchURL = url
    starterPackResolution?.cancel()
    guard context == nil else { return }
    starterPackResolution = Task { @MainActor [weak self] in
      let handler = URLHandler()
      let uri = await handler.resolveStarterPackURI(from: url)
      guard !Task.isCancelled, let self, !self.isDisconnected,
            self.context == nil, self.pendingLaunchURL == url, let uri else { return }
      let item = SceneStarterPackLandingItem(uri: uri)
      self.starterPackFlowID = item.flowID
      self.unauthenticatedStarterPackItem = item
    }
  }

  func clearPendingLaunchURL() {
    starterPackResolution?.cancel()
    starterPackResolution = nil
    pendingLaunchURL = nil
    unauthenticatedStarterPackItem = nil
    starterPackFlowID = nil
  }

  /// A removed handoff stays in this window until its editing session is ready.
  func reopenTransferredComposer(using manager: AppStateManager) {
    guard !isDisconnected, let context, !context.isInvalidated,
          manager.lifecycle.isAuthenticated,
          manager.lifecycle.appState?.userDID == context.accountDID else { return }
    if pendingComposerReopen == nil,
       let envelope = manager.pendingComposerReopen(
         sourceSceneID: sceneID, accountDID: context.accountDID
       ) {
      pendingComposerReopen = manager.claimComposerReopen(
        id: envelope.id, sourceSceneID: sceneID, accountDID: context.accountDID
      )
    }
    guard let envelope = pendingComposerReopen,
          envelope.sourceSceneID == sceneID, envelope.accountDID == context.accountDID else { return }
    do {
      let claim = try context.composerEditingSession.beginNew(draft: envelope.draft)
      context.postComposerRequest = ScenePostComposerRequest(editingClaim: claim)
      pendingComposerReopen = nil
    } catch {
      accountState?.toastManager.show(ToastItem(
        message: error.localizedDescription, icon: "exclamationmark.triangle.fill"
      ))
    }
  }

  func dismissStarterPackIfOwned() {
    if let starterPackFlowID,
       StarterPackOnboardingManager.shared.pendingContext?.flowID == starterPackFlowID {
      StarterPackOnboardingManager.shared.clearPendingContext()
    }
    clearPendingLaunchURL()
  }

  /// Called only by the attached platform window's actual disconnect/close signal.
  func disconnect() {
    guard !isDisconnected else { return }
    isDisconnected = true
    clearPendingLaunchURL()
    coordinator.disconnect(sceneID: sceneID)
    context?.invalidate()
    context = nil
    accountState = nil
    pendingComposerReopen = nil
    feedActivity.disconnect()
    lifetimeObservation = nil
  }

  #if os(iOS)
  func attach(to window: UIWindow, presenter: UIViewController?) {
    guard !isDisconnected else { return }
    presentingController = presenter
    if let presenter {
      context?.urlHandler.registerTopViewController(presenter)
    }
    if lifetimeObservation?.matches(window) != true {
      lifetimeObservation?.stopObserving()
      lifetimeObservation = SceneWindowLifetimeObservation(
        window: window, owner: self, coordinator: coordinator, feedActivity: feedActivity
      )
      let sessionID = window.windowScene?.session.persistentIdentifier ?? sceneID.uuidString
      window.restorationIdentifier = "Catbird-\(sessionID)"
      window.shouldGroupAccessibilityChildren = true
    }
    setPresentationAttached(true)
  }
  #elseif os(macOS)
  func attach(to window: NSWindow) {
    guard !isDisconnected else { return }
    if lifetimeObservation?.matches(window) != true {
      lifetimeObservation?.stopObserving()
      lifetimeObservation = SceneWindowLifetimeObservation(
        window: window, owner: self, coordinator: coordinator, feedActivity: feedActivity
      )
    }
    setPresentationAttached(true)
  }
  #endif
}

struct SceneStarterPackLandingItem: Identifiable {
  let flowID = UUID()
  let uri: ATProtocolURI
  var id: UUID { flowID }
}

/// SwiftUI can reevaluate its Scene modifier more than once for a single phase.
/// The shared lifecycle owner must not restart the same resume/suspension generation.
@MainActor
final class SceneApplicationPhaseObservation {
  static let shared = SceneApplicationPhaseObservation()
  private var lastPhase: ScenePhase?

  func accept(_ phase: ScenePhase) -> Bool {
    guard lastPhase != phase else { return false }
    lastPhase = phase
    return true
  }
}

/// SceneStorage preserves each window's draft-recovery identity across app launches.
struct CatbirdWindowRoot<Content: View>: View {
  let appStateManager: AppStateManager
  let onOpenURL: (URL, SceneWindowState) -> Void
  let onAccountReady: (SceneWindowState) -> Void
  @ViewBuilder var content: (SceneWindowState) -> Content
  @SceneStorage("catbird.sceneID.v1") private var storedSceneID = UUID().uuidString
  @State private var invalidStorageFallback = UUID()

  private var sceneID: UUID { UUID(uuidString: storedSceneID) ?? invalidStorageFallback }

  var body: some View {
    CatbirdWindowContentRoot(
      sceneID: sceneID, appStateManager: appStateManager,
      onOpenURL: onOpenURL, onAccountReady: onAccountReady, content: content
    )
    .id(sceneID)
    .onAppear {
      if UUID(uuidString: storedSceneID) == nil {
        storedSceneID = invalidStorageFallback.uuidString
      }
    }
  }
}

/// The @State owner is created inside the persisted window identity boundary.
private struct CatbirdWindowContentRoot<Content: View>: View {
  let appStateManager: AppStateManager
  let onOpenURL: (URL, SceneWindowState) -> Void
  let onAccountReady: (SceneWindowState) -> Void
  @ViewBuilder var content: (SceneWindowState) -> Content
  @State private var scene: SceneWindowState
  @Environment(\.scenePhase) private var scenePhase

  init(
    sceneID: UUID,
    appStateManager: AppStateManager,
    onOpenURL: @escaping (URL, SceneWindowState) -> Void,
    onAccountReady: @escaping (SceneWindowState) -> Void,
    @ViewBuilder content: @escaping (SceneWindowState) -> Content
  ) {
    self.appStateManager = appStateManager
    self.onOpenURL = onOpenURL
    self.onAccountReady = onAccountReady
    self.content = content
    self._scene = State(initialValue: SceneWindowState(sceneID: sceneID))
  }

  var body: some View {
    content(scene)
      .environment(appStateManager)
      .background {
        SceneWindowAnchor(owner: scene)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
      .onChange(of: appStateManager.lifecycle.appState.map(ObjectIdentifier.init), initial: true) { _, _ in
        // Lifecycle equality compares DIDs; a fresh service container for the same
        // account must still replace the context that captured the previous one.
        scene.updateAccount(appStateManager.lifecycle.appState)
        onAccountReady(scene)
        scene.reopenTransferredComposer(using: appStateManager)
        // A share-extension or Siri draft saved while signed out (or before restore) opens now.
        IncomingSharedDraftHandler.importIfAvailable()
      }
      .onChange(of: appStateManager.pendingComposerReopenRevision, initial: true) { _, _ in
        scene.reopenTransferredComposer(using: appStateManager)
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        scene.updatePhase(phase)
        if phase == .active {
          scene.reopenTransferredComposer(using: appStateManager)
          // Drafts handed over by the share extension while Catbird was in the background.
          IncomingSharedDraftHandler.importIfAvailable()
        }
      }
      .onOpenURL { url in
        scene.markFocused()
        onOpenURL(url, scene)
      }
  }
}

/// Account services remain shared; only the navigation/presentation environment is local.
struct SceneNavigationHost<Content: View>: View {
  let appState: AppState
  let appStateManager: AppStateManager
  @Bindable var context: SceneNavigationContext
  @ViewBuilder var content: () -> Content
  @State private var composerDetent: PresentationDetent = .large

  var body: some View {
    content()
      .id(context.activityRegistrationID)
      .applyAppStateEnvironment(appState)
      .environment(appStateManager)
      .environment(context)
      .sheet(item: $context.postComposerRequest) { request in
        PostComposerViewUIKit(
          parentPost: request.parentPost,
          quotedPost: request.quotedPost,
          initialText: request.initialText,
          appState: appState,
          editingSession: context.composerEditingSession,
          editingClaim: request.editingClaim
        )
        .applyAppStateEnvironment(appState)
        .environment(appStateManager)
        .environment(context)
        .toastContainer(using: appState.toastManager)
        .presentationDetents(request.parentPost == nil ? [.large] : [.medium, .large],
                             selection: $composerDetent)
        .presentationDragIndicator(.visible)
      }
      .onChange(of: context.postComposerRequest?.id) { _, _ in
        composerDetent = .large
      }
      .sheet(item: $context.settingsRequest) { request in
        SettingsView(initialTarget: request.route.target)
          .applyAppStateEnvironment(appState)
          .environment(appStateManager)
          .environment(context)
      }
  }
}

#if os(iOS)
private struct SceneWindowAnchor: UIViewRepresentable {
  let owner: SceneWindowState

  func makeUIView(context: Context) -> SceneWindowAnchorView {
    let view = SceneWindowAnchorView()
    view.isUserInteractionEnabled = false
    view.owner = owner
    return view
  }

  func updateUIView(_ uiView: SceneWindowAnchorView, context: Context) {
    uiView.owner = owner
    uiView.attachToWindow()
  }
}

private final class SceneWindowAnchorView: UIView {
  weak var owner: SceneWindowState?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    attachToWindow()
  }

  func attachToWindow() {
    guard let window else {
      owner?.setPresentationAttached(false)
      return
    }
    var responder: UIResponder? = self
    var presenter: UIViewController?
    while let current = responder {
      if let controller = current as? UIViewController,
         controller.viewIfLoaded?.window === window {
        presenter = controller
        break
      }
      responder = current.next
    }
    owner?.attach(to: window, presenter: presenter ?? window.rootViewController)
  }
}
#elseif os(macOS)
private struct SceneWindowAnchor: NSViewRepresentable {
  let owner: SceneWindowState

  func makeNSView(context: Context) -> SceneWindowAnchorView {
    let view = SceneWindowAnchorView()
    view.owner = owner
    return view
  }

  func updateNSView(_ nsView: SceneWindowAnchorView, context: Context) {
    nsView.owner = owner
    nsView.attachToWindow()
  }
}

private final class SceneWindowAnchorView: NSView {
  weak var owner: SceneWindowState?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    attachToWindow()
  }

  func attachToWindow() {
    guard let window else {
      owner?.setPresentationAttached(false)
      return
    }
    owner?.attach(to: window)
  }
}
#endif

/// Survives transient view detachment; only the platform close event disconnects a scene.
/// The close observer retains this object until that event, then removes its own tokens.
@MainActor
private final class SceneWindowLifetimeObservation {
  private weak var owner: SceneWindowState?
  private let sceneID: UUID
  private let coordinator: SceneRouteCoordinator
  private let feedActivity: SceneFeedActivityRegistration
  private var observers: [NSObjectProtocol] = []
  #if os(iOS)
  private weak var window: UIWindow?

  init(
    window: UIWindow, owner: SceneWindowState, coordinator: SceneRouteCoordinator,
    feedActivity: SceneFeedActivityRegistration
  ) {
    self.window = window
    self.owner = owner
    self.sceneID = owner.sceneID
    self.coordinator = coordinator
    self.feedActivity = feedActivity
    if let windowScene = window.windowScene {
      observers.append(NotificationCenter.default.addObserver(
        forName: UIScene.didDisconnectNotification, object: windowScene, queue: .main
      ) { [self] _ in
        MainActor.assumeIsolated { self.didDisconnect() }
      })
    }
    observers.append(NotificationCenter.default.addObserver(
      forName: UIWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak owner] _ in
      MainActor.assumeIsolated { owner?.markFocused() }
    })
  }

  func matches(_ window: UIWindow) -> Bool { self.window === window }
  #elseif os(macOS)
  private weak var window: NSWindow?

  init(
    window: NSWindow, owner: SceneWindowState, coordinator: SceneRouteCoordinator,
    feedActivity: SceneFeedActivityRegistration
  ) {
    self.window = window
    self.owner = owner
    self.sceneID = owner.sceneID
    self.coordinator = coordinator
    self.feedActivity = feedActivity
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [self] _ in
      MainActor.assumeIsolated { self.didDisconnect() }
    })
    observers.append(NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
    ) { [weak owner] _ in
      MainActor.assumeIsolated { owner?.markFocused() }
    })
  }

  func matches(_ window: NSWindow) -> Bool { self.window === window }
  #endif

  private func didDisconnect() {
    if let owner {
      owner.disconnect()
    } else {
      coordinator.disconnect(sceneID: sceneID)
      feedActivity.disconnect()
    }
    stopObserving()
  }

  func stopObserving() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
  }
}
