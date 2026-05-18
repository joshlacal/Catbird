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

  // Notch-based haptic feedback (fires on state transitions, not continuous)
  @State private var dragNotch: Int = 0

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

    if let customWidth = drawerWidth {
      self.drawerWidth = customWidth
    } else {
      let isIPad = PlatformDeviceInfo.isIPad
      if isIPad {
        self.drawerWidth = min(320, PlatformScreenInfo.width * 0.4)
      } else {
        self.drawerWidth = min(PlatformScreenInfo.width * 0.7, 375)
      }
    }

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
      let adaptiveDrawerWidth = min(self.drawerWidth, geometry.size.width * 0.8)
      let progress = drawerProgress(width: adaptiveDrawerWidth)
      let drawerOffset = -adaptiveDrawerWidth * (1 - progress)
      let scrimOpacity = progress * 0.3

      ZStack(alignment: .leading) {
        // Root content stays anchored — no .offset, no transform. Only the
        // drawer and scrim move. This is the core fix for the multi-track
        // animation jank from the previous implementation.
        content

        // Scrim. Always present so its opacity animates smoothly; hit testing
        // is only enabled when there is something to tap-to-close.
        Color.black
          .opacity(scrimOpacity)
          .ignoresSafeArea(.all)
          .allowsHitTesting(scrimOpacity > 0.01)
          .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
              isDrawerOpen = false
            }
          }
          .accessibilityAction(named: "Close Feeds Menu") {
            withAnimation {
              isDrawerOpen = false
            }
          }
          .accessibilityLabel(scrimOpacity > 0.01 ? "Close drawer background" : "")
          .accessibilityAddTraits(scrimOpacity > 0.01 ? .isButton : [])

        // Drawer slides in from the leading edge as a Liquid Glass shade on
        // iOS 26+, with an ultraThinMaterial fallback for iOS 18-25. The
        // inSideDrawer environment value lets the drawer's child content know
        // to skip its own opaque background so the glass is visible.
        drawer
          .environment(\.inSideDrawer, true)
          .frame(width: adaptiveDrawerWidth)
          .modifier(DrawerGlassBackground())
          .frame(maxHeight: .infinity)
          .offset(x: drawerOffset)
          .accessibilityAction(named: "Close Feeds Menu") {
            withAnimation {
              isDrawerOpen = false
            }
          }
          .accessibilityAddTraits(isOpen ? .isModal : [])
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

            // Notch-based haptic: only fires when crossing a threshold
            let step: CGFloat = 80
            let progress = abs(translation)
            let notch = Int(progress / step)
            if notch != dragNotch {
              dragNotch = notch
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
      .onAppear {
        dragNotch = 0
      }
      .onChange(of: isOpen) { _, newValue in
        if !newValue {
          dragOffset = 0
          dragNotch = 0
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
          }
        }

        let defaults = UserDefaults(suiteName: "group.blue.catbird.shared") ?? UserDefaults.standard
        defaults.set(newValue, forKey: "drawer_was_open")
      }
      .sensoryFeedback(.selection, trigger: dragNotch)
      .sensoryFeedback(.impact(weight: .medium), trigger: isOpen)
      .accessibilityElement(children: .contain)
    }
  }
}

/// Glass material for the drawer surface. Uses `.glassEffect()` on iOS 26+ for
/// true Liquid Glass; falls back to `.ultraThinMaterial` on earlier OS versions.
/// Kept outside `GlassEffectContainer` on purpose — the FAB owns its own
/// container for the compose matched-geometry transition and we don't want the
/// drawer to morph with it.
private struct DrawerGlassBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .background {
          Rectangle()
            .glassEffect(.regular, in: Rectangle())
        }
    } else {
      content
        .background(.ultraThinMaterial)
    }
  }
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
