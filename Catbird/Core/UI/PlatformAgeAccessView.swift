import Observation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The protected subtree is created only while its operation is admitted.
/// Navigation, Settings and contextual safety controls belong outside this wrapper.
struct PlatformAgeProtectedContent<ProtectedContent: View>: View, Equatable {
  @Environment(AppState.self) private var appState
  let operation: AgeRestrictedOperation
  let safetyTarget: String?
  let identityKey: String?
  private let content: () -> ProtectedContent

  init(
    operation: AgeRestrictedOperation,
    safetyTarget: String? = nil,
    identityKey: String? = nil,
    @ViewBuilder content: @escaping () -> ProtectedContent
  ) {
    self.operation = operation
    self.safetyTarget = safetyTarget
    self.identityKey = identityKey
    self.content = content
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.operation == rhs.operation && lhs.safetyTarget == rhs.safetyTarget else {
      return false
    }
    if let lhsKey = lhs.identityKey, let rhsKey = rhs.identityKey {
      return lhsKey == rhsKey
    }
    return lhs.identityKey == nil && rhs.identityKey == nil
  }
  var body: some View {
    let allowed = appState.ageAccess.allows(operation)
    Group {
      if allowed { content() }
      else { Color.clear }
    }
    .overlay {
      // Keep this presentation host alive so a safety sheet is not torn down
      // when a passive requirement refresh changes content access.
      PlatformAgeAccessNotice(operation: operation, safetyTarget: safetyTarget)
        .opacity(allowed ? 0 : 1)
        .allowsHitTesting(!allowed)
        .accessibilityHidden(allowed)
    }
  }
}

extension View {
  func platformAgeProtected(_ operation: AgeRestrictedOperation) -> some View {
    PlatformAgeProtectedContent(operation: operation) { self }
  }

  func platformAgePresentation(
    appState: AppState, manager: AppStateManager, context: SceneNavigationContext
  ) -> some View {
    modifier(PlatformAgePresentationModifier(
      appState: appState, appStateManager: manager, sceneContext: context))
  }
}

private struct PlatformAgePresenterKey: EnvironmentKey {
  static let defaultValue: PlatformAgeScenePresenter? = nil
}

private extension EnvironmentValues {
  var platformAgePresenter: PlatformAgeScenePresenter? {
    get { self[PlatformAgePresenterKey.self] }
    set { self[PlatformAgePresenterKey.self] = newValue }
  }
}

private struct PlatformAgeAccessNotice: View {
  @Environment(AppState.self) private var appState
  @Environment(\.platformAgePresenter) private var presenter
  let operation: AgeRestrictedOperation
  let safetyTarget: String?
  @State private var showingSafetyTools = false
  @State private var settingsRequest: SceneSettingsRequest?
  #if os(iOS)
  @State private var origin: UIViewController?
  #endif

  private var isResolvedMatureRestriction: Bool {
    operation == .matureContent
      && !appState.ageAccess.isCheckingRequirement && !appState.ageAccess.isRequesting
      && appState.ageAccess.allows(.generalContent) && appState.ageAccess.restrictsMatureContent
  }

  private var isBusy: Bool {
    appState.ageAccess.isCheckingRequirement || appState.ageAccess.isRequesting
      || !appState.ageAccess.requiresCheck
  }

  private var unavailableExplanation: String {
    #if os(iOS)
    "Your device’s age requirements currently prevent using this feature. You can retry the system check. Settings and safety tools remain available."
    #else
    "This device cannot complete the required age check. You can retry to check current availability. Settings and safety tools remain available."
    #endif
  }

  /// A pending or in-flight check shows only a quiet spinner. Content stays withheld
  /// by the wrapper; no copy, restriction UI or safety links are shown until settled.
  private var showsPendingIndicator: Bool {
    !isResolvedMatureRestriction && isBusy
  }

  var body: some View {
    Group {
      if showsPendingIndicator {
        ProgressView()
          .accessibilityLabel("Loading")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(spacing: 20) {
            if isResolvedMatureRestriction {
              Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
              Text("Mature content is unavailable")
                .font(.headline)
              Text("Mature content is restricted under the current age requirements. Other features, Settings, and safety tools remain available.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            } else {
              Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
              Text("This feature is unavailable")
                .font(.headline)
              Text(unavailableExplanation)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
              Button("Retry") { retry() }
                .buttonStyle(.borderedProminent)
                .disabled(presenter == nil)
                .accessibilityIdentifier("platform_age_retry")
            }

            safetyLinks
          }
          .frame(maxWidth: 480)
          .padding(24)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .accessibilityIdentifier("platform_age_access_notice")
    .background { originAnchor }
    .sheet(isPresented: $showingSafetyTools) {
      PlatformAgeSafetyToolsView(initialTarget: safetyTarget)
    }
    .sheet(item: $settingsRequest) { request in
      SettingsView(initialTarget: request.route.target)
    }
  }

  private var safetyLinks: some View {
    VStack(spacing: 12) {
      Button("Report or Block") { showingSafetyTools = true }
      Button("Moderation Settings") { settingsRequest = SceneSettingsRequest(route: .moderation) }
      Button("Blocked Accounts") {
        settingsRequest = SceneSettingsRequest(route: SettingsRoute(target: .init(screen: .blockedAccounts)))
      }
      Button("Muted Accounts") {
        settingsRequest = SceneSettingsRequest(route: SettingsRoute(target: .init(screen: .mutedAccounts)))
      }
      Button("Contact Developer") {
        settingsRequest = SceneSettingsRequest(route: SettingsRoute(target: .init(screen: .help)))
      }
      Button("Settings & Account") { settingsRequest = SceneSettingsRequest(route: .home) }
    }
  }

  @ViewBuilder
  private var originAnchor: some View {
    #if os(iOS)
    PlatformAgePresenterAnchor { controller in
      if origin !== controller { origin = controller }
    }
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
    #endif
  }

  private func retry() {
    #if os(iOS)
    presenter?.retry(from: origin)
    #else
    presenter?.retry()
    #endif
  }
}

private struct PlatformAgePresentationModifier: ViewModifier {
  let appState: AppState
  let appStateManager: AppStateManager
  let sceneContext: SceneNavigationContext
  @Environment(\.scenePhase) private var scenePhase
  @State private var presenter = PlatformAgeScenePresenter()

  func body(content: Content) -> some View {
    content
      .environment(\.platformAgePresenter, presenter)
      .background { presentationAnchor }
      .onAppear {
        presenter.configure(appState: appState, manager: appStateManager, context: sceneContext)
        presenter.updatePhase(scenePhase)
      }
      .onChange(of: scenePhase) { _, phase in presenter.updatePhase(phase) }
      .onChange(of: appState.ageAccess.revision) { _, _ in presenter.considerAutomaticRequest() }
      .onChange(of: appState.ageAccess.isRequesting) { _, requesting in
        if !requesting { presenter.considerAutomaticRequest() }
      }
      .onChange(of: appState.isTransitioningAccounts) { _, transitioning in
        if transitioning { presenter.cancelPendingRequest() }
        else { presenter.considerAutomaticRequest() }
      }
      .onChange(of: sceneContext.isInvalidated) { _, invalidated in
        if invalidated { presenter.invalidate() }
      }
      .onChange(of: appStateManager.settingsAccountContextRevision) { _, _ in
        presenter.invalidate()
      }
      .onDisappear { presenter.invalidate() }
  }

  @ViewBuilder
  private var presentationAnchor: some View {
    #if os(iOS)
    PlatformAgePresenterAnchor { presenter.attach($0) }
      .frame(width: 0, height: 0)
      .accessibilityHidden(true)
    #endif
  }
}

/// Owns only this scene's request task. Cancelling it cannot suspend a different
/// window's prompt or the account's shared passive requirement lookup.
@MainActor
@Observable
private final class PlatformAgeScenePresenter {
  @ObservationIgnored private weak var appState: AppState?
  @ObservationIgnored private weak var manager: AppStateManager?
  @ObservationIgnored private weak var context: SceneNavigationContext?
  @ObservationIgnored private var phase: ScenePhase = .inactive
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var automaticAttempted = false
  @ObservationIgnored private var hasActivated = false
  @ObservationIgnored private var isConfigured = false
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  #if os(iOS)
  @ObservationIgnored private weak var anchor: UIViewController?
  #endif

  func configure(appState: AppState, manager: AppStateManager, context: SceneNavigationContext) {
    self.appState = appState
    self.manager = manager
    self.context = context
    isConfigured = true
  }

  private var isCurrent: Bool {
    guard isConfigured, let appState, let manager, let context else { return false }
    return manager.lifecycle.isAuthenticated && manager.lifecycle.appState === appState
      && !context.isInvalidated && context.accountDID == appState.userDID
      && !appState.isTransitioningAccounts
  }

  func updatePhase(_ phase: ScenePhase) {
    let previous = self.phase
    self.phase = phase
    if phase == .background {
      refreshTask?.cancel()
      refreshTask = nil
      cancelPendingRequest()
      automaticAttempted = false
    } else if phase == .active {
      if previous == .background || !hasActivated {
        hasActivated = true
        refreshRequirements()
      }
      considerAutomaticRequest()
    }
  }

  func cancelPendingRequest() {
    generation = UUID()
    refreshTask?.cancel()
    refreshTask = nil
    requestTask?.cancel()
    requestTask = nil
  }

  func invalidate() {
    isConfigured = false
    refreshTask?.cancel()
    refreshTask = nil
    cancelPendingRequest()
    automaticAttempted = false
  }

  private func refreshRequirements() {
    guard isCurrent, let appState, refreshTask == nil else { return }
    refreshTask = Task { @MainActor [weak self, weak appState] in
      guard let appState else { return }
      await appState.ageAccess.refreshRequirements()
      guard !Task.isCancelled, let self else { return }
      self.refreshTask = nil
      self.considerAutomaticRequest()
    }
  }

  func considerAutomaticRequest() {
    guard isCurrent, let appState else { return }
    if !appState.ageAccess.requiresCheck {
      automaticAttempted = false
      return
    }
    guard phase == .active, !automaticAttempted, !appState.ageAccess.isCheckingRequirement,
          !appState.ageAccess.isRequesting, requestTask == nil else { return }
    #if os(iOS)
    guard let anchor, let controller = readyPresenter(from: anchor, automatic: true) else { return }
    beginRequest(from: controller, automatic: true)
    #endif
  }

  #if os(iOS)
  func attach(_ controller: UIViewController?) {
    anchor = controller
    considerAutomaticRequest()
  }

  func retry(from origin: UIViewController?) {
    guard phase == .active, isCurrent, let appState,
          !appState.ageAccess.isCheckingRequirement, !appState.ageAccess.isRequesting,
          refreshTask == nil, let origin,
          readyPresenter(from: origin, automatic: false) != nil else { return }
    automaticAttempted = true
    let attemptID = UUID()
    generation = attemptID
    refreshTask = Task { @MainActor [weak self, weak appState, weak origin] in
      guard let appState else { return }
      await appState.ageAccess.refreshRequirements()
      guard let self, !Task.isCancelled, self.generation == attemptID else { return }
      self.refreshTask = nil
      guard self.isCurrent, self.phase == .active, appState.ageAccess.requiresCheck,
            !appState.ageAccess.isRequesting, let origin,
            let controller = self.readyPresenter(from: origin, automatic: false) else { return }
      self.beginRequest(from: controller, automatic: false)
    }
  }

  private func readyPresenter(from origin: UIViewController, automatic: Bool) -> UIViewController? {
    guard let window = origin.viewIfLoaded?.window,
          window.windowScene?.activationState == .foregroundActive,
          case .ready(let controller) = SceneBrowserPresentationAnchor.resolvePresenter(in: window) else { return nil }
    if automatic {
      // The root must not present automatically above a report, Settings, browser,
      // camera or other existing modal, even when that modal itself is stable.
      var candidate: UIViewController? = controller
      while let current = candidate {
        if current.presentingViewController != nil { return nil }
        candidate = current.parent
      }
    } else {
      // A user's Retry may originate inside a restricted sheet. Only that visible
      // sheet's own controller may host the system UI.
      var candidate: UIViewController? = origin
      var containsPresenter = false
      while let current = candidate {
        if current === controller { containsPresenter = true; break }
        candidate = current.parent
      }
      guard containsPresenter else { return nil }
    }
    return controller
  }

  private func beginRequest(from controller: UIViewController, automatic: Bool) {
    guard isCurrent, let appState, let manager, let context,
          let window = controller.viewIfLoaded?.window, requestTask == nil else { return }
    let requestID = UUID()
    generation = requestID
    let registrationID = context.activityRegistrationID
    let accountRevision = manager.settingsAccountContextRevision
    let client = appState.client
    requestTask = Task { @MainActor [weak self, weak appState, weak controller, weak window] in
      guard let self else { return }
      defer {
        if self.generation == requestID { self.requestTask = nil }
      }
      guard let appState, let controller, let window,
            !Task.isCancelled, self.isCurrent, self.phase == .active,
            !appState.ageAccess.isRequesting,
            self.readyPresenter(from: controller, automatic: false) === controller else { return }
      self.automaticAttempted = true
      if automatic, !appState.ageAccess.claimAutomaticRequest() { return }
      await appState.requestPlatformAgeBand(from: controller, isCurrent: { [weak self, weak window] in
        guard let self, let window, let windowScene = window.windowScene else { return false }
        return !Task.isCancelled && self.isCurrent && self.generation == requestID
          && self.phase != .background && windowScene.activationState != .background
          && windowScene.activationState != .unattached
          && self.context?.activityRegistrationID == registrationID
          && self.manager?.settingsAccountContextRevision == accountRevision
          && self.appState?.client === client
      })
    }
  }
  #else
  func retry() {
    // Native macOS has no UIKit request bridge. A passive refresh may remove a
    // requirement; unsupported acquisition itself never supplies an allow result.
    guard phase == .active, isCurrent else { return }
    refreshRequirements()
  }
  #endif
}

#if os(iOS)
private struct PlatformAgePresenterAnchor: UIViewControllerRepresentable {
  let attached: @MainActor (UIViewController?) -> Void

  func makeUIViewController(context: Context) -> PlatformAgeAnchorController {
    PlatformAgeAnchorController(attached: attached)
  }

  func updateUIViewController(_ controller: PlatformAgeAnchorController, context: Context) {
    controller.attached = attached
  }

  static func dismantleUIViewController(_ controller: PlatformAgeAnchorController, coordinator: ()) {
    controller.attached(nil)
  }
}

private final class PlatformAgeAnchorController: UIViewController {
  var attached: @MainActor (UIViewController?) -> Void

  init(attached: @escaping @MainActor (UIViewController?) -> Void) {
    self.attached = attached
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func loadView() {
    view = UIView(frame: .zero)
    view.isUserInteractionEnabled = false
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    attached(self)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    Task { @MainActor [weak self] in
      guard let self, self.viewIfLoaded?.window != nil else { return }
      self.attached(self)
    }
  }
}
#endif
