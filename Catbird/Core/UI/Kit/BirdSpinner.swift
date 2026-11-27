//
//  BirdSpinner.swift
//  Catbird
//
//  A tactile loading indicator: the 3D Catbird mascot rendered by RealityKit
//  (virtual camera, transparent background). The bird pivots about the centre
//  of its head and looks around: idle, it glances in different directions
//  with a slight forward tilt and a gentle bob; drag, and it follows your
//  finger (up, down, left, right); tap, and it looks at you and bounces.
//  Reduce Motion shows a still front three-quarter pose.
//
//  Debug playground: `simctl launch <udid> blue.catbird -BirdSpinnerPlayground 1`
//

import OSLog
import RealityKit
import SwiftUI

struct BirdSpinner: View {
  var size: CGFloat = 120

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var motion = BirdSpinnerMotion()
  @State private var hasRendered = false

  var body: some View {
    RealityView { content in
      content.camera = .virtual
      content.environment = .default
      motion.onFirstFrame = { hasRendered = true }
      await motion.install(in: &content)
    } update: { _ in
      motion.reduceMotion = reduceMotion
    } placeholder: {
      Color.clear
    }
    .overlay {
      // Same art as the static launch screen, held until the 3D bird has
      // drawn its first frame, so a cold launch never shows a blank square.
      if !hasRendered {
        Image("LaunchIcon")
          .resizable()
          .scaledToFit()
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.25), value: hasRendered)
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .gesture(dragGesture, isEnabled: !reduceMotion)
    .onTapGesture { if !reduceMotion { motion.bounce() } }
    .onAppear { motion.reduceMotion = reduceMotion }
    .accessibilityElement()
    .accessibilityLabel(Text("Loading", comment: "Accessibility label for the 3D bird loading spinner."))
    .accessibilityAddTraits(.updatesFrequently)
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in motion.look(at: value.location, viewSize: size) }
      .onEnded { _ in motion.release() }
  }
}

// MARK: - Motion

/// Per-instance motion state, advanced once per rendered frame. Deliberately
/// not `@Observable`: the frame loop must not invalidate SwiftUI bodies.
@MainActor
final class BirdSpinnerMotion {
  var reduceMotion = false
  /// Called once, on the first rendered frame after the model is in the scene.
  var onFirstFrame: (@MainActor () -> Void)?

  /// Which way the bird is looking, coarsely; a change while dragging ticks.
  private enum Facing: Equatable {
    case front, left, right, upward, downward
  }

  /// A damped spring's stiffness (1/s²) and damping ratio.
  private struct Spring {
    let stiffness: Float
    let dampingRatio: Float
    var damping: Float { 2 * stiffness.squareRoot() * dampingRatio }
  }

  // MARK: Tuning
  /// Furthest the head turns left/right and up/down while following a finger.
  private let maxYaw: Float = 55 * .pi / 180
  private let maxPitch: Float = 38 * .pi / 180
  /// Range of the idle glances, kept well inside the drag limits.
  private let idleYaw: Float = 32 * .pi / 180
  private let idlePitch: Float = 16 * .pi / 180
  /// How long each idle glance is held, in seconds.
  private let idleHold: ClosedRange<Float> = 1.1...2.6
  /// Forward tilt (top toward the viewer) in radians.
  private let forwardTilt: Float = 0.10
  /// Still pose for Reduce Motion: beak turned 30° toward the viewer's right.
  private let staticYaw: Float = 30 * .pi / 180
  private let bobAmplitude: Float = 0.025
  private let bobPeriod: Float = 2.6
  /// Snappy while a finger leads, softer for idle glances.
  private let followSpring = Spring(stiffness: 140, dampingRatio: 0.8)
  private let idleSpring = Spring(stiffness: 34, dampingRatio: 0.75)

  // MARK: State
  private var yaw: Float = 0
  private var pitch: Float = 0
  private var yawRate: Float = 0
  private var pitchRate: Float = 0
  private var targetYaw: Float = 0
  private var targetPitch: Float = 0
  /// Seconds until the next idle glance.
  private var holdRemaining: Float = 1.2
  private var clock: Float = 0
  private var bounceAge: Float?
  private var isDragging = false
  private var facing: Facing = .front

  private var bird: Entity?
  private var subscription: EventSubscription?

  #if DEBUG
  private static let logger = Logger(subsystem: "blue.catbird", category: "BirdSpinner")
  private var statFrames = 0
  private var statTime: Float = 0

  /// Logs the instance's render-loop rate every 2 s (DEBUG builds only).
  private func recordFrame(delta: Float) {
    statFrames += 1
    statTime += delta
    guard statTime >= 2 else { return }
    let fps = Float(statFrames) / statTime
    Self.logger.debug("BirdSpinner fps=\(fps, format: .fixed(precision: 1), privacy: .public)")
    statFrames = 0
    statTime = 0
  }
  #endif

  /// Camera sits on +Z looking at the origin; the bird is 1 unit tall.
  private static let cameraDistance: Float = 2.8
  private static let fieldOfView: Float = 30

  func install(in content: inout RealityViewCameraContent) async {
    guard let bird = try? await BirdSpinnerAssets.makeBird() else { return }
    let environment = try? await BirdSpinnerAssets.fillEnvironment()
    self.bird = bird

    let rig = Entity()
    rig.addChild(bird)

    if let environment {
      let fill = Entity()
      fill.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
      rig.addChild(fill)
      bird.components.set(ImageBasedLightReceiverComponent(imageBasedLight: fill))
    }

    // One soft warm key light from the upper left, in front.
    let key = DirectionalLight()
    key.light.color = .init(red: 1.0, green: 0.92, blue: 0.80, alpha: 1)
    key.light.intensity = 2_600
    key.look(at: .zero, from: [-1.2, 1.4, 1.6], relativeTo: nil)
    rig.addChild(key)

    let camera = PerspectiveCamera()
    camera.camera.fieldOfViewInDegrees = Self.fieldOfView
    camera.position = [0, 0, Self.cameraDistance]
    rig.addChild(camera)

    content.add(rig)
    apply(delta: 0)
    subscription = content.subscribe(to: SceneEvents.Update.self) { [weak self] event in
      MainActor.assumeIsolated {
        self?.apply(delta: Float(event.deltaTime))
      }
    }
  }

  // MARK: Gestures

  /// Points the bird's gaze at a finger, given in the view's own coordinates.
  /// The head turns further the further the finger is from the centre, easing
  /// into its limits so a finger outside the view never snaps it around.
  func look(at location: CGPoint, viewSize: CGFloat) {
    if !isDragging {
      isDragging = true
      PlatformHaptics.light()
      PlatformHaptics.prepare(.soft)
    }
    let half = Float(max(viewSize, 1)) / 2
    let offsetX = (Float(location.x) - half) / half
    let offsetY = (Float(location.y) - half) / half
    // Positive yaw turns the beak (+Z) toward +X, the viewer's right; positive
    // pitch about X tips it down, so a finger below the centre looks down.
    targetYaw = maxYaw * tanh(offsetX * 1.2)
    targetPitch = maxPitch * tanh(offsetY * 1.2)
    tickIfFacingChanged()
  }

  /// Lets go: the bird holds the last look for a beat, then resumes glancing.
  func release() {
    isDragging = false
    holdRemaining = 0.7
  }

  /// Looks at the viewer and bounces.
  func bounce() {
    bounceAge = 0
    targetYaw = 0
    targetPitch = 0
    holdRemaining = 1.4
    PlatformHaptics.light()
  }

  // MARK: Frame loop

  private func apply(delta rawDelta: Float) {
    guard let bird else { return }
    if rawDelta > 0, let onFirstFrame {
      self.onFirstFrame = nil
      onFirstFrame()
    }
    #if DEBUG
    if rawDelta > 0 { recordFrame(delta: rawDelta) }
    #endif
    let delta = min(rawDelta, 1 / 30)  // don't jump after a hitch or pause

    if reduceMotion {
      bird.transform = Transform(
        scale: .one,
        rotation: simd_quatf(angle: staticYaw, axis: [0, 1, 0])
          * simd_quatf(angle: forwardTilt, axis: [1, 0, 0]),
        translation: .zero)
      return
    }

    clock += delta
    if !isDragging {
      holdRemaining -= delta
      if holdRemaining <= 0 { pickIdleGlance() }
    }

    let spring = isDragging ? followSpring : idleSpring
    step(&yaw, rate: &yawRate, toward: targetYaw, spring: spring, delta: delta)
    step(&pitch, rate: &pitchRate, toward: targetPitch, spring: spring, delta: delta)

    var scale = SIMD3<Float>(repeating: 1)
    var hop: Float = 0
    if var age = bounceAge {
      age += delta
      bounceAge = age < 1.2 ? age : nil
      // Squash first, then stretch, settling out; volume roughly preserved.
      let stretch = 1 - 0.22 * exp(-5.5 * age) * sin(17 * age)
      let squash = 1 / stretch.squareRoot()
      scale = [squash, stretch, squash]
      hop = 0.10 * exp(-6 * age) * max(0, sin(10 * age - 0.6))
    }

    let bob = bobAmplitude * sin(clock * 2 * .pi / bobPeriod)
    // Pitch in the head's own frame, then turn: a nod stays a nod at any yaw.
    bird.transform = Transform(
      scale: scale,
      rotation: simd_quatf(angle: yaw, axis: [0, 1, 0])
        * simd_quatf(angle: forwardTilt + pitch, axis: [1, 0, 0]),
      translation: [0, bob + hop, 0])
  }

  /// Semi-implicit Euler step of a damped spring; stable at frame-rate steps.
  private func step(_ value: inout Float, rate: inout Float, toward target: Float, spring: Spring, delta: Float) {
    rate += (spring.stiffness * (target - value) - spring.damping * rate) * delta
    value += rate * delta
  }

  /// Chooses the next idle glance: often back at the viewer, otherwise
  /// somewhere new and clearly different from where it is looking now.
  private func pickIdleGlance() {
    holdRemaining = Float.random(in: idleHold)
    if abs(targetYaw) + abs(targetPitch) > 0.05, Float.random(in: 0...1) < 0.35 {
      targetYaw = 0
      targetPitch = 0
      return
    }
    var nextYaw: Float
    repeat {
      nextYaw = Float.random(in: -idleYaw...idleYaw)
    } while abs(nextYaw - targetYaw) < idleYaw * 0.5
    targetYaw = nextYaw
    targetPitch = Float.random(in: -idlePitch...idlePitch)
  }

  // MARK: Haptic ticks

  private func currentFacing() -> Facing {
    let horizontal = targetYaw / maxYaw
    let vertical = targetPitch / maxPitch
    guard max(abs(horizontal), abs(vertical)) > 0.5 else { return .front }
    if abs(horizontal) >= abs(vertical) { return horizontal > 0 ? .right : .left }
    return vertical > 0 ? .downward : .upward
  }

  /// A soft tick each time the dragged gaze swings into a new direction.
  private func tickIfFacingChanged() {
    let next = currentFacing()
    if next != facing {
      facing = next
      PlatformHaptics.soft()
    }
  }
}

// MARK: - Playground

#if DEBUG
/// Debug screen for trying the spinner at several sizes.
struct BirdSpinnerPlayground: View {
  @State private var size: CGFloat = 220
  /// `-BirdSpinnerPlaygroundSingle 1` shows only the main instance, for
  /// measuring the cost of one spinner.
  @State private var showsSizes = !UserDefaults.standard.bool(forKey: "BirdSpinnerPlaygroundSingle")

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 32) {
          BirdSpinner(size: size)
            .accessibilityIdentifier("birdSpinner.main")
          Slider(value: $size, in: 60...320) {
            Text(verbatim: "Size")
          }
          .padding(.horizontal, 32)
          Toggle(isOn: $showsSizes) { Text(verbatim: "Show small sizes") }
            .padding(.horizontal, 32)
          if showsSizes {
            HStack(spacing: 24) {
              BirdSpinner(size: 44)
              BirdSpinner(size: 80)
              BirdSpinner(size: 120)
            }
          }
          Text(verbatim: "Drag to look around · tap to bounce")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
      }
      .navigationTitle(Text(verbatim: "Bird Spinner"))
    }
  }
}

#Preview("Bird spinner") {
  BirdSpinnerPlayground()
}
#endif
