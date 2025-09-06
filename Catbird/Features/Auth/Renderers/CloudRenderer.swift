import Metal
import MetalKit
import SwiftUI
import OSLog

@Observable
class CloudRenderer: NSObject {
    private let rendererLogger = Logger(subsystem: "blue.catbird", category: "CloudRenderer")

    private var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    private var pipelineState: MTLRenderPipelineState!
    private var advancedPipelineState: MTLRenderPipelineState!
    private var improvedPipelineState: MTLRenderPipelineState!
    private var ultraPipelineState: MTLRenderPipelineState!
    private var uniformBuffer: MTLBuffer!
    
    var time: Float = 0.0
    
    // Cloud parameters
    var opacity: Float = 0.7
    var cloudScale: Float = 1.0
    var animationSpeed: Float = 1.0
    var shaderMode: ShaderMode = .improved // Default to improved shader
    
    enum ShaderMode {
        case basic
        case improved
        case advanced
        case ultra
    }
    
    // Color scheme support - white clouds against blue sky
    var lightModeColor = simd_float4(1.0, 1.0, 1.0, 1.0) // Pure white clouds
    var darkModeColor = simd_float4(0.95, 0.95, 0.98, 1.0) // Slightly blue-tinted white for dark mode
    var isDarkMode = false
    
    struct CloudUniforms {
        var time: Float
        var resolution: simd_float2
        var opacity: Float
        var lightModeColor: simd_float4
        var darkModeColor: simd_float4
        var isDarkMode: Bool
        var cloudScale: Float
        var animationSpeed: Float
        var padding: simd_float3 // For alignment
    }
    
    override init() {
        super.init()
        setupMetal()
    }
    
    private func setupMetal() {
        // Get the default Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            rendererLogger.error("CloudRenderer: Metal is not supported on this device")
            return
        }
        
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        
        // Load the shader functions
        guard let library = device.makeDefaultLibrary() else {
            rendererLogger.error("CloudRenderer: Could not create default library")
            return
        }
        
        // Load basic shader functions
        guard let vertexFunction = library.makeFunction(name: "cloud_vertex"),
              let fragmentFunction = library.makeFunction(name: "cloud_fragment") else {
            rendererLogger.error("CloudRenderer: Could not load basic shader functions")
            return
        }
        
        // Load advanced shader functions
        guard let advancedVertexFunction = library.makeFunction(name: "cloud_vertex_advanced"),
              let advancedFragmentFunction = library.makeFunction(name: "cloud_fragment_advanced") else {
            rendererLogger.error("CloudRenderer: Could not load advanced shader functions")
            return
        }
        
        // Create basic render pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Disable blending since shader is fully opaque
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            rendererLogger.error("CloudRenderer: Could not create basic pipeline state: \(error)")
            return
        }
        
        // Create advanced render pipeline
        let advancedPipelineDescriptor = MTLRenderPipelineDescriptor()
        advancedPipelineDescriptor.vertexFunction = advancedVertexFunction
        advancedPipelineDescriptor.fragmentFunction = advancedFragmentFunction
        advancedPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Disable blending since shader is fully opaque
        advancedPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            advancedPipelineState = try device.makeRenderPipelineState(descriptor: advancedPipelineDescriptor)
        } catch {
            rendererLogger.error("CloudRenderer: Could not create advanced pipeline state: \(error)")
            return
        }
        
        // No vertex buffer needed for vertex ID-based rendering
        
        // Load improved shader functions
        guard let improvedVertexFunction = library.makeFunction(name: "cloud_vertex_improved"),
              let improvedFragmentFunction = library.makeFunction(name: "cloud_fragment_improved") else {
            rendererLogger.error("CloudRenderer: Could not load improved shader functions")
            return
        }
        
        // Create improved render pipeline
        let improvedPipelineDescriptor = MTLRenderPipelineDescriptor()
        improvedPipelineDescriptor.vertexFunction = improvedVertexFunction
        improvedPipelineDescriptor.fragmentFunction = improvedFragmentFunction
        improvedPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Disable blending since shader is fully opaque
        improvedPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            improvedPipelineState = try device.makeRenderPipelineState(descriptor: improvedPipelineDescriptor)
        } catch {
            rendererLogger.error("CloudRenderer: Could not create improved pipeline state: \(error)")
            return
        }
        
        // Load ultra shader functions
        guard let ultraVertexFunction = library.makeFunction(name: "cloud_vertex_ultra"),
              let ultraFragmentFunction = library.makeFunction(name: "cloud_fragment_ultra") else {
            rendererLogger.error("CloudRenderer: Could not load ultra shader functions")
            return
        }
        
        // Create ultra render pipeline
        let ultraPipelineDescriptor = MTLRenderPipelineDescriptor()
        ultraPipelineDescriptor.vertexFunction = ultraVertexFunction
        ultraPipelineDescriptor.fragmentFunction = ultraFragmentFunction
        ultraPipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        // Disable blending since shader is fully opaque
        ultraPipelineDescriptor.colorAttachments[0].isBlendingEnabled = false
        
        do {
            ultraPipelineState = try device.makeRenderPipelineState(descriptor: ultraPipelineDescriptor)
        } catch {
            rendererLogger.error("CloudRenderer: Could not create ultra pipeline state: \(error)")
            return
        }
        
        // Create uniform buffer
        uniformBuffer = device.makeBuffer(length: MemoryLayout<CloudUniforms>.stride, options: [])
        
    }
    
    func render(in view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        
        guard let drawable = view.currentDrawable else {
            return
        }
        
        let selectedPipelineState: MTLRenderPipelineState? = switch shaderMode {
        case .basic:
            pipelineState
        case .improved:
            improvedPipelineState
        case .advanced:
            advancedPipelineState
        case .ultra:
            ultraPipelineState
        }
        
        guard let selectedPipelineState = selectedPipelineState else {
            return
        }
        
        guard let uniformBuffer = uniformBuffer else {
            return
        }
        
        // Clear to transparent
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        
        // Update uniforms
        let resolution = simd_float2(Float(view.drawableSize.width), Float(view.drawableSize.height))
        updateUniforms(resolution: resolution)
        
        // Create render encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { 
            return 
        }
        
        renderEncoder.setRenderPipelineState(selectedPipelineState)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        
        // Set vertex buffer for ultra shader (which uses uniforms in vertex shader)
        if shaderMode == .ultra {
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        }
        
        // Draw full-screen quad using vertex ID-based rendering
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
    }
    
    private func updateUniforms(resolution: simd_float2) {
        var uniforms = CloudUniforms(
            time: time,
            resolution: resolution,
            opacity: opacity,
            lightModeColor: lightModeColor,
            darkModeColor: darkModeColor,
            isDarkMode: isDarkMode,
            cloudScale: cloudScale,
            animationSpeed: animationSpeed,
            padding: simd_float3(0, 0, 0)
        )
        
        let uniformsPointer = uniformBuffer.contents().bindMemory(to: CloudUniforms.self, capacity: 1)
        uniformsPointer.pointee = uniforms
    }
    
    func updateTime(_ deltaTime: Float) {
        time += deltaTime
    }
    
    func updateColorScheme(isDark: Bool) {
        isDarkMode = isDark
    }
}
