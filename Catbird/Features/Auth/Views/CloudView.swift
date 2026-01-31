import SwiftUI
import MetalKit
import OSLog
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
struct CloudView: UIViewRepresentable {
    @State private var renderer = CloudRenderer()
    @Environment(\.colorScheme) var colorScheme

    var opacity: Float = 0.9
    var cloudScale: Float = 2.0
    var animationSpeed: Float = 1.0
    var shaderMode: CloudRenderer.ShaderMode = .advanced
    /// Resolution scale factor (0.5 = half resolution, 1.0 = full). Lower = faster but blurrier.
    var resolutionScale: CGFloat = 0.75

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.backgroundColor = UIColor.clear
        mtkView.isOpaque = false
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        // 60fps is sufficient for slow cloud animation - saves 50% GPU work
        mtkView.preferredFramesPerSecond = 60

        // Render at reduced resolution for performance (clouds are soft/blurry anyway)
        let screenScale = UIScreen.main.scale
        mtkView.contentScaleFactor = screenScale * resolutionScale

        // Configure renderer
        renderer.opacity = opacity
        renderer.cloudScale = cloudScale
        renderer.animationSpeed = animationSpeed
        renderer.shaderMode = shaderMode
        renderer.updateColorScheme(isDark: colorScheme == .dark)


        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        renderer.updateColorScheme(isDark: colorScheme == .dark)
        renderer.opacity = opacity
        renderer.cloudScale = cloudScale
        renderer.animationSpeed = animationSpeed
        renderer.shaderMode = shaderMode
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {

        let renderer: CloudRenderer
        private var lastTime: CFTimeInterval = 0
        
        init(renderer: CloudRenderer) {
            self.renderer = renderer
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes if needed
        }
        
        func draw(in view: MTKView) {
            let currentTime = CACurrentMediaTime()
            if lastTime == 0 {
                lastTime = currentTime
            }
            
            let deltaTime = Float(currentTime - lastTime)
            lastTime = currentTime
            
            renderer.updateTime(deltaTime)
            
            guard let commandQueue = renderer.commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { 
                return 
            }
            
            renderer.render(in: view, commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }
}
#elseif os(macOS)
struct CloudView: NSViewRepresentable {
    @State private var renderer = CloudRenderer()
    @Environment(\.colorScheme) var colorScheme

    var opacity: Float = 0.9
    var cloudScale: Float = 2.0
    var animationSpeed: Float = 1.0
    var shaderMode: CloudRenderer.ShaderMode = .advanced
    /// Resolution scale factor (0.5 = half resolution, 1.0 = full). Lower = faster but blurrier.
    var resolutionScale: CGFloat = 0.75

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.layer?.backgroundColor = NSColor.clear.cgColor
        mtkView.layer?.isOpaque = false
        mtkView.framebufferOnly = false
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        // 60fps is sufficient for slow cloud animation - saves 50% GPU work
        mtkView.preferredFramesPerSecond = 60

        // Render at reduced resolution for performance (clouds are soft/blurry anyway)
        if let screen = NSScreen.main {
            mtkView.layer?.contentsScale = screen.backingScaleFactor * resolutionScale
        }

        // Configure renderer
        renderer.opacity = opacity
        renderer.cloudScale = cloudScale
        renderer.animationSpeed = animationSpeed
        renderer.shaderMode = shaderMode
        renderer.updateColorScheme(isDark: colorScheme == .dark)


        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        renderer.updateColorScheme(isDark: colorScheme == .dark)
        renderer.opacity = opacity
        renderer.cloudScale = cloudScale
        renderer.animationSpeed = animationSpeed
        renderer.shaderMode = shaderMode
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(renderer: renderer)
    }
    
    class Coordinator: NSObject, MTKViewDelegate {

        let renderer: CloudRenderer
        private var lastTime: CFTimeInterval = 0
        
        init(renderer: CloudRenderer) {
            self.renderer = renderer
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle size changes if needed
        }
        
        func draw(in view: MTKView) {
            let currentTime = CACurrentMediaTime()
            if lastTime == 0 {
                lastTime = currentTime
            }
            
            let deltaTime = Float(currentTime - lastTime)
            lastTime = currentTime
            
            renderer.updateTime(deltaTime)
            
            guard let commandQueue = renderer.commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { 
                return 
            }
            
            renderer.render(in: view, commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }
}
#endif
