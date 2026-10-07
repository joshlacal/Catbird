import MetalKit
import OSLog
import SwiftUI

/// Animated blue sky with soft drifting clouds, used behind the login screen.
///
/// Draws `sky_blobs_fragment` (SkyShader.metal). The sky is soft, so it renders at
/// half resolution and 30fps; with `animated == false` (Reduce Motion) it draws a
/// single still frame and only redraws when SwiftUI updates the view.
struct SkyView {
  var animated: Bool = true
  /// Fraction of the display scale to render at. Clouds are soft, so 0.5 is invisible.
  var resolutionScale: CGFloat = 0.5

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale

  func makeCoordinator() -> SkyRenderer { SkyRenderer() }

  @MainActor
  private func makeView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: context.coordinator.device)
    view.delegate = context.coordinator
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    configure(view, context: context)
    return view
  }

  @MainActor
  private func configure(_ view: MTKView, context: Context) {
    context.coordinator.isDark = colorScheme == .dark
    context.coordinator.animated = animated
    view.preferredFramesPerSecond = 30
    view.isPaused = !animated
    view.enableSetNeedsDisplay = !animated
    #if os(iOS)
    let scale = displayScale * resolutionScale
    if view.contentScaleFactor != scale { view.contentScaleFactor = scale }
    #endif
    if !animated { view.setNeedsDisplay(view.bounds) }
  }
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
  /// Starting the clock part-way in means the first frame already has a settled layout.
  private static let timeOffset: Double = 20

  let device: MTLDevice?
  private let queue: MTLCommandQueue?
  private let pipeline: MTLRenderPipelineState?
  private let noise: MTLTexture?
  private let sampler: MTLSamplerState?
  private let start = CACurrentMediaTime()
  private let skyLogger = Logger(subsystem: "blue.catbird", category: "SkyView")

  var isDark = false
  var animated = true

  override init() {
    let device = MTLCreateSystemDefaultDevice()
    self.device = device
    queue = device?.makeCommandQueue()
    noise = device.flatMap(Self.makeNoiseTexture)

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.sAddressMode = .repeat
    samplerDescriptor.tAddressMode = .repeat
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.mipFilter = .linear
    sampler = device?.makeSamplerState(descriptor: samplerDescriptor)

    var pipeline: MTLRenderPipelineState?
    if let device, let library = device.makeDefaultLibrary() {
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "sky_blobs_vertex")
      descriptor.fragmentFunction = library.makeFunction(name: "sky_blobs_fragment")
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }
    self.pipeline = pipeline
    super.init()
    if pipeline == nil { skyLogger.error("Sky pipeline unavailable; login background will be blank") }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard let pipeline, let queue, let noise, let sampler,
          let pass = view.currentRenderPassDescriptor,
          let drawable = view.currentDrawable,
          let commandBuffer = queue.makeCommandBuffer(),
          let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }

    let elapsed = animated ? CACurrentMediaTime() - start : 0
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

  // swiftlint:disable identifier_name
  /// 256×256 tileable value noise with four octaves in RGBA (8, 16, 32 and 64 cells
  /// across). Deterministic, so the sky looks the same on every launch.
  private static func makeNoiseTexture(device: MTLDevice) -> MTLTexture? {
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
          let queue = device.makeCommandQueue(),
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

#Preview("Sky") {
  SkyView()
    .ignoresSafeArea()
}
