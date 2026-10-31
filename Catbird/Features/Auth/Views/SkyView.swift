import MetalKit
import OSLog
import SwiftUI

/// Animated blue sky with soft drifting clouds, used behind the login screen.
///
/// Draws `sky_blobs_fragment` (SkyShader.metal). The sky is soft, so it renders at
/// half resolution and 30fps; with `animated == false` (Reduce Motion) it draws a
/// single still frame and only redraws when SwiftUI updates the view.
/// Environment key to pause sky animation (e.g. when covered by modal sheets).
private struct SkyAnimationPausedKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

extension EnvironmentValues {
  var skyAnimationPaused: Bool {
    get { self[SkyAnimationPausedKey.self] }
    set { self[SkyAnimationPausedKey.self] = newValue }
  }
}

struct SkyView {
  var animated: Bool = true
  /// Fraction of the display scale to render at. Clouds are soft, so 0.5 is invisible.
  var resolutionScale: CGFloat = 0.5

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale
  @Environment(\.skyAnimationPaused) private var skyAnimationPaused

  func makeCoordinator() -> SkyRenderer { SkyRenderer() }

  @MainActor
  private func makeView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: context.coordinator.device)
    context.coordinator.currentView = view
    view.delegate = context.coordinator
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    configure(view, context: context)
    return view
  }

  @MainActor
  private func configure(_ view: MTKView, context: Context) {
    let isEffectivelyAnimated = animated && !skyAnimationPaused
    context.coordinator.isDark = colorScheme == .dark
    context.coordinator.animated = isEffectivelyAnimated
    view.preferredFramesPerSecond = 30
    view.isPaused = !isEffectivelyAnimated
    view.enableSetNeedsDisplay = !isEffectivelyAnimated
    #if os(iOS)
    let scale = displayScale * resolutionScale
    if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
    #endif
    if !isEffectivelyAnimated { view.setNeedsDisplay(view.bounds) }
  }
}

extension Notification.Name {
  static let skyResourcesDidUpdate = Notification.Name("blue.catbird.skyResourcesDidUpdate")
}

/// Lazily initialized shared Metal resources for SkyView instances, avoiding redundant
/// device, command queue, sampler allocations, and offloading pipeline/noise generation.
final class SkyResources: @unchecked Sendable {
  static let shared = SkyResources()

  let device: MTLDevice?
  let queue: MTLCommandQueue?
  let sampler: MTLSamplerState?
  private(set) var pipeline: MTLRenderPipelineState?
  private(set) var noise: MTLTexture?

  private let logger = Logger(subsystem: "blue.catbird", category: "SkyView")

  private init() {
    let dev = MTLCreateSystemDefaultDevice()
    self.device = dev
    self.queue = dev?.makeCommandQueue()

    if let dev {
      let samplerDescriptor = MTLSamplerDescriptor()
      samplerDescriptor.sAddressMode = .repeat
      samplerDescriptor.tAddressMode = .repeat
      samplerDescriptor.minFilter = .linear
      samplerDescriptor.magFilter = .linear
      samplerDescriptor.mipFilter = .linear
      self.sampler = dev.makeSamplerState(descriptor: samplerDescriptor)
    } else {
      self.sampler = nil
    }

    guard let dev, let queue else { return }

    // Asynchronously create pipeline state off the critical first-frame path
    if let library = dev.makeDefaultLibrary() {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "sky_blobs_vertex")
      descriptor.fragmentFunction = library.makeFunction(name: "sky_blobs_fragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      dev.makeRenderPipelineState(descriptor: descriptor) { [weak self] pipelineState, error in
        if let pipelineState {
          self?.pipeline = pipelineState
          DispatchQueue.main.async {
            NotificationCenter.default.post(name: .skyResourcesDidUpdate, object: nil)
          }
        } else if let error {
          self?.logger.error("Failed to compile sky pipeline: \(error.localizedDescription)")
        }
      }
    }

    // Generate 256k-texel noise texture in background Task using the existing queue
    Task.detached(priority: .utility) { [weak self] in
      let noiseTex = Self.buildNoiseTexture(device: dev, queue: queue)
      self?.noise = noiseTex
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .skyResourcesDidUpdate, object: nil)
      }
    }
  }

  // swiftlint:disable identifier_name
  /// 256×256 tileable value noise with four octaves in RGBA.
  private static func buildNoiseTexture(device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
    let size = 256
    let frequencies = [8, 16, 32, 64]
    let lattices = frequencies.enumerated().map { index, frequency -> [Float] in
      var state = UInt32(index + 1) &* 747_796_405 &+ 2_891_336_453
      return (0..<(frequency * frequency)).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return Float(state >> 8) / Float(1 << 24)
      }
    }

    var bytes = [UInt8](repeating: 0, count: size * size * 4)
    for channel in 0..<4 {
      let frequency = frequencies[channel], lattice = lattices[channel]
      for y in 0..<size {
        let fy = Float(y * frequency) / Float(size)
        let y0 = Int(fy) % frequency, y1 = (y0 + 1) % frequency
        var ty = fy - fy.rounded(.down)
        ty = ty * ty * (3 - 2 * ty)
        for x in 0..<size {
          let fx = Float(x * frequency) / Float(size)
          let x0 = Int(fx) % frequency, x1 = (x0 + 1) % frequency
          var tx = fx - fx.rounded(.down)
          tx = tx * tx * (3 - 2 * tx)
          let top = lattice[y0 * frequency + x0] + (lattice[y0 * frequency + x1] - lattice[y0 * frequency + x0]) * tx
          let bottom = lattice[y1 * frequency + x0] + (lattice[y1 * frequency + x1] - lattice[y1 * frequency + x0]) * tx
          let value = top + (bottom - top) * ty
          bytes[(y * size + x) * 4 + channel] = UInt8(max(0, min(255, value * 255)))
        }
      }
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor),
          let commandBuffer = queue.makeCommandBuffer(),
          let blit = commandBuffer.makeBlitCommandEncoder()
    else { return nil }
    texture.replace(
      region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
      withBytes: bytes, bytesPerRow: size * 4)
    blit.generateMipmaps(for: texture)
    blit.endEncoding()
    commandBuffer.commit()
    return texture
  }
  // swiftlint:enable identifier_name
}

#if os(iOS)
extension SkyView: UIViewRepresentable {
  func makeUIView(context: Context) -> MTKView {
    let view = makeView(context: context)
    view.isOpaque = true
    return view
  }

  func updateUIView(_ uiView: MTKView, context: Context) {
    configure(uiView, context: context)
  }
}
#elseif os(macOS)
extension SkyView: NSViewRepresentable {
  func makeNSView(context: Context) -> MTKView {
    makeView(context: context)
  }

  func updateNSView(_ nsView: MTKView, context: Context) {
    configure(nsView, context: context)
  }
}
#endif

final class SkyRenderer: NSObject, MTKViewDelegate {
  private static let timeOffset: Double = 20

  let resources: SkyResources
  var device: MTLDevice? { resources.device }
  private var elapsedTime: Double = 0
  private var lastActiveTime: CFTimeInterval?
  weak var currentView: MTKView?
  private var resourcesObserver: AnyObject?

  var isDark = false
  var animated = true

  override init() {
    self.resources = SkyResources.shared
    super.init()
    resourcesObserver = NotificationCenter.default.addObserver(
      forName: .skyResourcesDidUpdate,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self, let view = self.currentView, view.isPaused else { return }
      #if os(iOS)
      view.setNeedsDisplay(view.bounds)
      #elseif os(macOS)
      view.needsDisplay = true
      #endif
    }
  }

  deinit {
    if let observer = resourcesObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    self.currentView = view
    guard let pass = view.currentRenderPassDescriptor else { return }

    // Clear to base sky color so the first frame is never blank/black
    let clearColor = isDark
      ? MTLClearColor(red: 0.05, green: 0.08, blue: 0.15, alpha: 1.0)
      : MTLClearColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0)
    pass.colorAttachments[0].clearColor = clearColor
    pass.colorAttachments[0].loadAction = .clear

    guard let pipeline = resources.pipeline,
          let queue = resources.queue,
          let noise = resources.noise,
          let sampler = resources.sampler,
          let drawable = view.currentDrawable,
          let commandBuffer = queue.makeCommandBuffer()
    else {
      // If shaders or noise texture are still preparing asynchronously, commit the clear pass
      if let queue = resources.queue,
         let drawable = view.currentDrawable,
         let commandBuffer = queue.makeCommandBuffer(),
         let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
      }
      if view.isPaused {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
          guard let view, view.isPaused else { return }
          #if os(iOS)
          view.setNeedsDisplay(view.bounds)
          #elseif os(macOS)
          view.needsDisplay = true
          #endif
        }
      }
      return
    }

    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

    let now = CACurrentMediaTime()
    if animated {
      if let last = lastActiveTime {
        let delta = min(max(now - last, 0), 0.1)
        elapsedTime += delta
      }
      lastActiveTime = now
    } else {
      lastActiveTime = nil
    }
    let elapsed = elapsedTime
    var uniforms: [Float] = [
      Float(view.drawableSize.width), Float(view.drawableSize.height),
      Float(Self.timeOffset + elapsed), isDark ? 1 : 0
    ]
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Float>.stride * 4, index: 0)
    encoder.setFragmentTexture(noise, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}

#Preview("Sky") {
  SkyView()
    .ignoresSafeArea()
}
