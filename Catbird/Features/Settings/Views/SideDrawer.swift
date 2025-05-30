//
//  SideDrawer.swift
//  Catbird
//
//  Created by Josh LaCalamito on 11/2/24.
//

import SwiftUI
import UIKit

class DrawerPanGestureRecognizer: UIPanGestureRecognizer {
  weak var coordinator: DrawerPanGesture.Coordinator?

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    maximumNumberOfTouches = 1
    allowedScrollTypesMask = .all
  }

  // Override the gesture recognizer's behavior
  override func shouldRequireFailure(of otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    // Let VoiceOver gestures take precedence
    if UIAccessibility.isVoiceOverRunning {
      return true
    }

    // Original logic
    if let view = self.view,
      let coordinator = coordinator,
      !coordinator.canRecognizeGesture(in: view) {
      return true
    }
    return false
  }
}

struct DrawerPanGesture: UIGestureRecognizerRepresentable {
  let onChanged: (CGFloat) -> Void
  let onEnded: (CGFloat, CGFloat) -> Void
  let canOpen: () -> Bool

  func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
    Coordinator(onChanged: onChanged, onEnded: onEnded, canOpen: canOpen)
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
  }

  class Coordinator: NSObject {
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var canOpen: () -> Bool

    init(
      onChanged: @escaping (CGFloat) -> Void,
      onEnded: @escaping (CGFloat, CGFloat) -> Void,
      canOpen: @escaping () -> Bool
    ) {
      self.onChanged = onChanged
      self.onEnded = onEnded
      self.canOpen = canOpen
    }

    func canRecognizeGesture(in view: UIView) -> Bool {
      return canOpen()
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
      // Only handle the gesture if we can open
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

struct SideDrawer<Content: View, DrawerContent: View>: View {
  let content: Content
  let drawer: DrawerContent
  let drawerWidth: CGFloat
  @Binding private var selectedTab: Int
  @Binding private var isDrawerOpen: Bool
  @Binding private var isRootView: Bool
  @State private var dragOffset: CGFloat = 0
  @State private var bounceOffset: CGFloat = 0

  // Device detection
  private let isIPad = UIDevice.current.userInterfaceIdiom == .pad

  // Responsive customizable properties
  private var bounceAmount: CGFloat { isIPad ? 0 : 0 }
  private var springStiffness: Double { isIPad ? 180 : 150 }
  private var springDamping: Double { isIPad ? 25 : 20 }
  private var dragThreshold: CGFloat { isIPad ? 0.2 : 0.3 }
  private var velocityThreshold: CGFloat { isIPad ? 150 : 100 }

  // Haptics
  let softHaptic = UIImpactFeedbackGenerator(style: .soft)
  let rigidHaptic = UIImpactFeedbackGenerator(style: .rigid)

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

    // Calculate adaptive drawer width if not provided
    if let customWidth = drawerWidth {
      self.drawerWidth = customWidth
    } else {
      let isIPad = UIDevice.current.userInterfaceIdiom == .pad
      if isIPad {
        self.drawerWidth = min(320, UIScreen.main.bounds.width * 0.4)
      } else {
        self.drawerWidth = min(UIScreen.main.bounds.width * 0.7, 375)
      }
    }

    self.content = content()
    self.drawer = drawer()
  }

  private var isOpen: Bool {
    isDrawerOpen && isRootView && selectedTab == 0
  }

  private var canOpen: Bool {
    // Only check if we can open if on home tab and root view
    guard selectedTab == 0 && isRootView else { return false }

    let wasOpen = isDrawerOpen
    isDrawerOpen = true
    let canBeOpened = isDrawerOpen
    isDrawerOpen = wasOpen
    return canBeOpened
  }

  var body: some View {
    GeometryReader { geometry in
      let adaptiveDrawerWidth = min(self.drawerWidth, geometry.size.width * 0.8)

      ZStack(alignment: .leading) {
        content
          .offset(x: max(0, effectiveOffset(drawerWidth: adaptiveDrawerWidth) + bounceOffset))
          .animation(
            .interpolatingSpring(stiffness: springStiffness, damping: springDamping),
            value: isOpen
          )
          .animation(
            .interpolatingSpring(stiffness: springStiffness, damping: springDamping),
            value: dragOffset
          )
          .animation(
            .interpolatingSpring(stiffness: springStiffness * 2, damping: springDamping),
            value: bounceOffset
          )
          .accessibilityAction(named: "Open Feeds Menu") {
            if !isDrawerOpen && canOpen {
              withAnimation {
                isDrawerOpen = true
              }
            }
          }

        if isOpen {
          Color.black
            .opacity(
              min(
                0.3, effectiveOffset(drawerWidth: adaptiveDrawerWidth) / adaptiveDrawerWidth * 0.3)
            )
            .ignoresSafeArea(.all)
            .onTapGesture {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                isDrawerOpen = false
              }
              rigidHaptic.impactOccurred()
            }
            .accessibilityAction(named: "Close Feeds Menu") {
              withAnimation {
                isDrawerOpen = false
              }
            }
            .accessibilityLabel("Close drawer background")
            .accessibilityAddTraits(.isButton)
        } else if effectiveOffset(drawerWidth: adaptiveDrawerWidth) > 0 {
          Color.black
            .opacity(
              min(
                0.3, effectiveOffset(drawerWidth: adaptiveDrawerWidth) / adaptiveDrawerWidth * 0.3)
            )
            .ignoresSafeArea(.all)
            .allowsHitTesting(false)
        }

        drawer
          .frame(width: adaptiveDrawerWidth)
          .offset(
            x: min(
              0,
              effectiveOffset(drawerWidth: adaptiveDrawerWidth) - adaptiveDrawerWidth + bounceOffset
            )
          )
          .animation(
            .interpolatingSpring(stiffness: springStiffness, damping: springDamping),
            value: isOpen
          )
          .animation(
            .interpolatingSpring(stiffness: springStiffness, damping: springDamping),
            value: dragOffset
          )
          .animation(
            .interpolatingSpring(stiffness: springStiffness * 2, damping: springDamping),
            value: bounceOffset
          )
          .accessibilityAction(named: "Close Feeds Menu") {
            withAnimation {
              isDrawerOpen = false
            }
          }
          .accessibilityAddTraits(isOpen ? .isModal : [])
      }
      .gesture(
        DrawerPanGesture(
          onChanged: { translation in
            if !isDrawerOpen && !canOpen {
              return
            }

            if isDrawerOpen {
              dragOffset = min(0, translation)
            } else {
              dragOffset = max(0, translation)
            }

            let translationInt = Int(abs(translation))
            if translationInt % 50 < 2 {
              softHaptic.impactOccurred(intensity: 0.3)
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

            if shouldOpen != isDrawerOpen {
              let velocityFactor = min(abs(velocity) / 1000, 1.0)
              withAnimation(.spring(response: 0.3, dampingFraction: 0.99)) {
                bounceOffset =
                  shouldOpen ? bounceAmount * velocityFactor : -bounceAmount * velocityFactor
              }

              DispatchQueue.main.asyncAfter(deadline: .now() + 0.99) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                  bounceOffset = 0
                }
              }

              rigidHaptic.impactOccurred(intensity: velocityFactor)
            }

            withAnimation(.spring(response: 0.3, dampingFraction: 0.99)) {
              isDrawerOpen = shouldOpen
              dragOffset = 0
            }
          },
          canOpen: { canOpen }
        )
      )
      .onChange(of: isOpen) { _, newValue in
        if !newValue {
          dragOffset = 0
          bounceOffset = 0
        } else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIAccessibility.post(notification: .screenChanged, argument: nil)
          }
        }
      }
      .hoverEffect(.lift)
      .accessibilityElement(children: .contain)
    }
  }

  private func effectiveOffset(drawerWidth: CGFloat) -> CGFloat {
    if isOpen {
      return drawerWidth + dragOffset
    } else {
      return dragOffset
    }
  }
}
