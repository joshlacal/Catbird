import SwiftUI
import MetalKit
import OSLog

struct CloudView: UIViewRepresentable {
    @State private var renderer = CloudRenderer()
    @Environment(\.colorScheme) var colorScheme
    
    var opacity: Float = 0.9
    var cloudScale: Float = 2.0
    var animationSpeed: Float = 1.0
    var shaderMode: CloudRenderer.ShaderMode = .improved
    
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
        
        // High framerate for hyperrealistic cloud animation
        mtkView.preferredFramesPerSecond = 120
        
        // Configure renderer
        renderer.opacity = opacity
        renderer.cloudScale = cloudScale
        renderer.animationSpeed = animationSpeed
        renderer.shaderMode = shaderMode
        renderer.updateColorScheme(isDark: colorScheme == .dark)
        
        Logger(subsystem: "blue.catbird", category: "CloudView").debug("CloudView: MTKView configured with device: \(String(describing: mtkView.device))")
        
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
        private let coordinatorLogger = Logger(subsystem: "blue.catbird", category: "CloudView")

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
                coordinatorLogger.debug("CloudView: Failed to create command buffer")
                return 
            }
            
            renderer.render(in: view, commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
    }
}
