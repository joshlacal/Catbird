//
//  SideDrawer.swift
//  Catbird
//
//  Created by Josh LaCalamito on 11/2/24.
//

import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
class DrawerPanGestureRecognizer: UIPanGestureRecognizer {
  weak var coordinator: DrawerPanGesture.Coordinator?

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    maximumNumberOfTouches = 1
    allowedScrollTypesMask = .all
  }

  override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    if UIAccessibility.isVoiceOverRunning {
      return true
    }

    if let view = self.view,
      let coordinator = coordinator,
      !coordinator.canRecognizeGesture(in: view) {
      return true
    }
    return false
  }

  // Cancel the gesture when the user is swiping in the "wrong" direction so
  // horizontal swipe actions on feed cells (like / reply) keep working. This
  // mirror logic is load-bearing — do not remove without re-validating that
  // post-row swipe actions still trigger.
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    super.touchesMoved(touches, with: event)

    guard let view = self.view else { return }
    let translation = self.translation(in: view)

    if let coordinator = coordinator, !coordinator.isDrawerOpen() {
      if translation.x < -10 {
        self.state = .cancelled
        return
      }
    }

    if let coordinator = coordinator, coordinator.isDrawerOpen() {
      if translation.x > 10 {
        self.state = .cancelled
        return
      }
    }
  }
}

struct DrawerPanGesture: UIGestureRecognizerRepresentable {
  let onChanged: (CGFloat) -> Void
  let onEnded: (CGFloat, CGFloat) -> Void
  let canOpen: () -> Bool
  let isDrawerOpen: () -> Bool

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator(onChanged: onChanged, onEnded: onEnded, canOpen: canOpen, isDrawerOpen: isDrawerOpen)
  }

  func makeUIGestureRecognizer(context: Context) -> DrawerPanGestureRecognizer {
    let gesture = DrawerPanGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePan(_:))
    )
    gesture.coordinator = context.coordinator
    return gesture
  }

  func updateGestureRecognizer(_ gestureRecognizer: DrawerPanGestureRecognizer, context: Context) {
    gestureRecognizer.coordinator = context.coordinator
    context.coordinator.onChanged = onChanged
    context.coordinator.onEnded = onEnded
    context.coordinator.canOpen = canOpen
    context.coordinator.isDrawerOpen = isDrawerOpen
  }

  class Coordinator: NSObject {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var canOpen: () -> Bool
    var isDrawerOpen: () -> Bool

    init(
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (CGFloat, CGFloat) -> Void,
      canOpen: @escaping () -> Bool,
      isDrawerOpen: @escaping () -> Bool
    ) {
      self.onChanged = onChanged
      self.onEnded = onEnded
      self.canOpen = canOpen
      self.isDrawerOpen = isDrawerOpen
    }

    func canRecognizeGesture(in view: UIView) -> Bool {
      return canOpen()
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
      guard canOpen() else { return }

      switch gesture.state {
      case .changed:
        let translation = gesture.translation(in: gesture.view).x
        onChanged(translation)
      case .ended:
        let translation = gesture.translation(in: gesture.view).x
        let velocity = gesture.velocity(in: gesture.view).x
        onEnded(translation, velocity)
      default:
        break
      }
    }
  }
}

/// Overlay-style side drawer. The root content stays anchored at its natural
/// position; only the drawer slides in from the leading edge over it, like the
/// iOS notification shade but horizontal. A scrim fades in with drawer progress
/// to dim the content below.
struct SideDrawer<Content: View, DrawerContent: View>: View {
  let content: Content
  let drawer: DrawerContent
  let drawerWidth: CGFloat
  @Binding private var selectedTab: Int
  @Binding private var isDrawerOpen: Bool
  @Binding private var isRootView: Bool

  // Live drag translation while the user is dragging. Positive values move the
  // drawer toward open from whatever its current resting state is.
  @State private var dragOffset: CGFloat = 0
  @State private var isDragging: Bool = false

  private let isIPad = PlatformDeviceInfo.isIPad

  private var dragThreshold: CGFloat { isIPad ? 0.2 : 0.3 }
  private var velocityThreshold: CGFloat { isIPad ? 150 : 100 }

  init(
    selectedTab: Binding<Int>,
    isRootView: Binding<Bool>,
    isDrawerOpen: Binding<Bool>,
    drawerWidth: CGFloat? = nil,
    @ViewBuilder content: () -> Content,
    @ViewBuilder drawer: () -> DrawerContent
  ) {
    self._selectedTab = selectedTab
    self._isRootView = isRootView
    self._isDrawerOpen = isDrawerOpen

    // Single source of truth for drawer width — full-bleed on phones, a fixed
    // panel on wider displays (see PlatformScreenInfo.responsiveDrawerWidth).
    self.drawerWidth = drawerWidth ?? PlatformScreenInfo.responsiveDrawerWidth

    self.content = content()
    self.drawer = drawer()
  }

  private var isOpen: Bool {
    isDrawerOpen && isRootView && selectedTab == 0
  }

  private var canOpen: Bool {
    selectedTab == 0 && isRootView
  }

  /// Progress of the drawer from closed (0) to fully open (1), accounting for
  /// the live drag translation.
  private func drawerProgress(width: CGFloat) -> CGFloat {
    let base: CGFloat = isOpen ? width : 0
    let raw = base + dragOffset
    return min(max(raw / width, 0), 1)
  }

  var body: some View {
    GeometryReader { geometry in
      let adaptiveDrawerWidth = min(self.drawerWidth, geometry.size.width)
      let progress = drawerProgress(width: adaptiveDrawerWidth)
      let drawerOffset = -adaptiveDrawerWidth * (1 - progress)

      ZStack(alignment: .leading) {
        // Root content stays anchored and is never re-rendered for the drawer:
        // the backdrop below applies a real UIKit backdrop blur over it instead
        // of a SwiftUI .blur, which re-rasterizes the whole feed every frame.
        content

        DrawerDismissBackdrop(
          progress: progress,
          metrics: ConcentricDrawerBackdropMetrics()
        ) {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isDrawerOpen = false
          }
        }

        // The drawer frame owns the slide gesture and bounds. FeedsStartPage
        // owns the separate concentric glass panels inside that frame.
        ConcentricLiquidGlassDrawer(surfaceStyle: .clear) {
          drawer
            .environment(\.inSideDrawer, true)
            .background(Color.clear)
        }
          .frame(width: adaptiveDrawerWidth)
          .frame(maxHeight: .infinity, alignment: .top)
          .hoverEffect(.lift)
          .offset(x: drawerOffset)
          .accessibilityAction(named: "Close Feeds Menu") {
            withAnimation {
              isDrawerOpen = false
            }
          }
          .accessibilityAddTraits(isOpen ? .isModal : [])
      }
      .accessibilityAction(named: "Open Feeds Menu") {
        guard !isOpen, canOpen else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
          isDrawerOpen = true
        }
      }
      .animation(isDragging ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: isOpen)
      .gesture(
        DrawerPanGesture(
          onChanged: { translation in
            if !isDrawerOpen && !canOpen {
              return
            }

            isDragging = true
            if isDrawerOpen {
              dragOffset = min(0, translation)
            } else {
              dragOffset = max(0, translation)
            }
          },
          onEnded: { translation, velocity in
            let shouldOpen: Bool
            if isDrawerOpen {
              shouldOpen =
                !(translation < -adaptiveDrawerWidth * dragThreshold
                  || velocity < -velocityThreshold)
            } else {
              shouldOpen =
                canOpen
                && (translation > adaptiveDrawerWidth * dragThreshold
                  || velocity > velocityThreshold)
            }

            isDragging = false
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              isDrawerOpen = shouldOpen
              dragOffset = 0
            }
          },
          canOpen: { canOpen },
          isDrawerOpen: { isOpen }
        )
      )
      .onChange(of: isOpen) { _, newValue in
        if !newValue {
          dragOffset = 0
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
          }
        }

        let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? UserDefaults.standard
        defaults.set(newValue, forKey: "drawer_was_open")
      }
      .sensoryFeedback(.impact(weight: .medium), trigger: isOpen) { _, _ in
        PlatformHaptics.isEnabled
      }
      .accessibilityElement(children: .contain)
    }
    // Ignoring the safe area lets the drawer extend to the device's true bezel
    // edge. Children that already manage their own safe area (NavigationStack,
    // TabView, etc.) are unaffected.
    .ignoresSafeArea()
  }
}

/// Full-screen backdrop between the root content and the drawer: a real
/// backdrop blur plus a light scrim, both scaled by drawer progress.
/// `Animatable` so the open/close spring scrubs the blur frame-by-frame
/// instead of snapping to the final radius.
private struct DrawerDismissBackdrop: View, Animatable {
  var progress: CGFloat
  let metrics: ConcentricDrawerBackdropMetrics
  let close: () -> Void

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  var body: some View {
    ZStack {
      ProgressiveBlurView(fraction: metrics.blurFraction(for: progress))

      Color.black
        .opacity(metrics.scrimOpacity(for: progress))
    }
      .contentShape(Rectangle())
      .allowsHitTesting(progress > 0.01)
      .onTapGesture(perform: close)
      .accessibilityAction(named: "Close Feeds Menu", close)
      .accessibilityLabel(progress > 0.01 ? "Close drawer background" : "")
      .accessibilityAddTraits(progress > 0.01 ? .isButton : [])
  }
}

/// Tuning for the drawer's dismiss backdrop. The blur is expressed as a
/// fraction of a full `UIBlurEffect` (0–1) scrubbed via a paused
/// `UIViewPropertyAnimator` — the same technique Control Center uses — so the
/// root content never re-renders while the drawer animates.
struct ConcentricDrawerBackdropMetrics: Equatable, Sendable {
  var maximumBlurFraction: CGFloat = 1.0
  var maximumScrimOpacity: CGFloat = 0.18

  func blurFraction(for progress: CGFloat) -> CGFloat {
    progress * maximumBlurFraction
  }

  func scrimOpacity(for progress: CGFloat) -> CGFloat {
    progress * maximumScrimOpacity
  }
}

/// Hosts a `UIVisualEffectView` whose blur is scrubbed by pausing a
/// `UIViewPropertyAnimator` mid-flight. The effect view samples layers already
/// composited behind it, so varying the blur costs one backdrop pass on the
/// GPU — no SwiftUI re-render of the content beneath.
private struct ProgressiveBlurView: UIViewRepresentable {
  var fraction: CGFloat

  func makeUIView(context: Context) -> ProgressiveBlurUIView {
    ProgressiveBlurUIView()
  }

  func updateUIView(_ uiView: ProgressiveBlurUIView, context: Context) {
    uiView.fraction = fraction
  }
}

final class ProgressiveBlurUIView: UIView {
  private let effectView = UIVisualEffectView(effect: nil)
  private var animator: UIViewPropertyAnimator?

  var fraction: CGFloat = 0 {
    didSet { applyFraction() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Touches must fall through to the SwiftUI tap-to-dismiss gesture behind
    // this view.
    isUserInteractionEnabled = false
    effectView.isUserInteractionEnabled = false
    effectView.frame = bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(effectView)

    // Backgrounding the app removes the paused animator's in-flight
    // animations, which would leave the blur stuck at a stale radius.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(rebuildAfterForeground),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      // A UIViewPropertyAnimator must not be deallocated while active/paused.
      teardownAnimator()
    } else {
      applyFraction()
    }
  }

  @objc private func rebuildAfterForeground() {
    teardownAnimator()
    applyFraction()
  }

  private func teardownAnimator() {
    animator?.stopAnimation(true)
    animator = nil
    effectView.effect = nil
  }

  private func applyFraction() {
    guard window != nil else { return }

    let clamped = min(max(fraction, 0), 1)

    // Keep the animator alive only while the drawer is actually revealing —
    // an idle paused animator at fraction 0 still pins UIKit animation state
    // for the whole app lifetime and breaks across backgrounding.
    guard clamped > 0 else {
      teardownAnimator()
      return
    }

    if animator == nil {
      let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [effectView] in
        effectView.effect = UIBlurEffect(style: .regular)
      }
      animator.pausesOnCompletion = true
      self.animator = animator
    }

    animator?.fractionComplete = clamped
  }
}

enum SideDrawerConstants {
  static let drawerInnerInset: CGFloat = 12
}
#endif

// MARK: - Environment Key

private struct InSideDrawerKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

extension EnvironmentValues {
  /// True when a view is being rendered inside the side drawer's overlay
  /// surface. Child views can use this to opt out of their own opaque
  /// backgrounds so the drawer's Liquid Glass / material remains visible.
  var inSideDrawer: Bool {
    get { self[InSideDrawerKey.self] }
    set { self[InSideDrawerKey.self] = newValue }
  }
}

#if os(iOS)
#Preview {
  @Previewable @State var selectedTab = 0
  @Previewable @State var isRootView = true
  @Previewable @State var isDrawerOpen = true

  SideDrawer(
    selectedTab: $selectedTab,
    isRootView: $isRootView,
    isDrawerOpen: $isDrawerOpen
  ) {
    ZStack {
      LinearGradient(
        colors: [.blue.opacity(0.25), .mint.opacity(0.2)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(spacing: 16) {
        Text("Timeline")
          .font(.largeTitle.weight(.bold))

        Text("Main content stays anchored while the drawer slides over it.")
          .font(.body)
          .multilineTextAlignment(.center)
          .foregroundStyle(.secondary)
          .padding(.horizontal)

        Button(isDrawerOpen ? "Close Drawer" : "Open Drawer") {
          withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isDrawerOpen.toggle()
          }
        }
        .buttonStyle(.borderedProminent)
      }
      .padding()
    }
  } drawer: {
    VStack(alignment: .leading, spacing: 16) {
      Text("Feeds")
        .font(.title2.weight(.semibold))

      Divider()

      Label("Following", systemImage: "person.2.fill")
      Label("Discover", systemImage: "sparkles")
      Label("Lists", systemImage: "list.bullet")
      Label("Bookmarks", systemImage: "bookmark.fill")

      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(24)
    .ignoresSafeArea()
  }
  .ignoresSafeArea()
}
#endif
