//
//  BirdSpinner.swift
//  Catbird
//
//  A tactile loading indicator: the 3D Catbird mascot rendered by RealityKit
//  (virtual camera, transparent background). Idles with a slow turn, slight
//  forward tilt and a gentle bob. Drag spins it (yaw, limited pitch) and
//  releases with inertia that eases back into the idle turn; tap squashes and
//  stretches it. Reduce Motion shows a still front three-quarter pose.
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
      .onChanged { value in motion.drag(translation: value.translation, viewSize: size) }
      .onEnded { value in motion.release(velocity: value.velocity, viewSize: size) }
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

  // MARK: Tuning
  /// Idle turn rate: one revolution every 8 s.
  private let idleYawRate: Float = .pi * 2 / 8
  /// Forward tilt (top toward the viewer) in radians.
  private let forwardTilt: Float = 0.14
  /// Still pose for Reduce Motion: beak turned 35° toward the viewer's right.
  private let staticYaw: Float = 35 * .pi / 180
  private let maxPitch: Float = 0.45
  private let maxYawRate: Float = 30
  private let bobAmplitude: Float = 0.025
  private let bobPeriod: Float = 2.6
  /// How quickly fling inertia relaxes back to the idle turn (1/s).
  private let inertiaRelax: Float = 1.1

  // MARK: State
  private var yaw: Float = 0
  private var yawRate: Float = .pi * 2 / 8
  private var pitch: Float = 0
  private var pitchRate: Float = 0
  private var clock: Float = 0
  private var bounceAge: Float?
  private var isDragging = false
  private var lastTranslation: CGSize = .zero
  private var lastFrontIndex = 0

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
    yaw = reduceMotion ? staticYaw : 0
    lastFrontIndex = frontIndex(for: yaw)

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

  func drag(translation: CGSize, viewSize: CGFloat) {
    if !isDragging {
      isDragging = true
      lastTranslation = .zero
      yawRate = 0
      pitchRate = 0
      PlatformHaptics.light()
      PlatformHaptics.prepare(.soft)
    }
    let radiansPerPoint = Float.pi / Float(max(viewSize, 1))
    let deltaX = Float(translation.width - lastTranslation.width)
    let deltaY = Float(translation.height - lastTranslation.height)
    lastTranslation = translation
    yaw += deltaX * radiansPerPoint
    pitch = min(max(pitch + deltaY * radiansPerPoint * 0.6, -maxPitch), maxPitch)
    tickIfPassingFront()
  }

  func release(velocity: CGSize, viewSize: CGFloat) {
    isDragging = false
    let radiansPerPoint = Float.pi / Float(max(viewSize, 1))
    yawRate = min(max(Float(velocity.width) * radiansPerPoint, -maxYawRate), maxYawRate)
    pitchRate = Float(velocity.height) * radiansPerPoint * 0.3
  }

  func bounce() {
    bounceAge = 0
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
    let delta = min(rawDelta, 1 / 20)  // don't jump after a hitch or pause

    if reduceMotion {
      bird.transform = Transform(
        scale: .one,
        rotation: simd_quatf(angle: forwardTilt, axis: [1, 0, 0])
          * simd_quatf(angle: staticYaw, axis: [0, 1, 0]),
        translation: .zero)
      return
    }

    clock += delta
    if !isDragging {
      // Inertia relaxes exponentially into the idle turn.
      yawRate += (idleYawRate - yawRate) * (1 - exp(-inertiaRelax * delta))
      yaw += yawRate * delta
      // Pitch springs back to level (critically-ish damped).
      let stiffness: Float = 40
      let damping: Float = 11
      pitchRate += (-stiffness * pitch - damping * pitchRate) * delta
      pitch = min(max(pitch + pitchRate * delta, -maxPitch), maxPitch)
      if abs(yawRate - idleYawRate) > 0.6 { tickIfPassingFront() } else { lastFrontIndex = frontIndex(for: yaw) }
    }
    yaw = yaw.truncatingRemainder(dividingBy: .pi * 2000)  // keep Float precision

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
    bird.transform = Transform(
      scale: scale,
      rotation: simd_quatf(angle: forwardTilt + pitch, axis: [1, 0, 0])
        * simd_quatf(angle: yaw, axis: [0, 1, 0]),
      translation: [0, bob + hop, 0])
  }

  // MARK: Haptic ticks

  private func frontIndex(for yaw: Float) -> Int {
    Int((yaw / (.pi * 2)).rounded())
  }

  /// A soft tick each time the beak swings past the viewer.
  private func tickIfPassingFront() {
    let index = frontIndex(for: yaw)
    if index != lastFrontIndex {
      lastFrontIndex = index
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
          Text(verbatim: "Drag to spin · tap to bounce")
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
