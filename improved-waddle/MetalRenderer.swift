import MetalKit
import MSDFFontKit

class MetalRenderer: NSObject {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState!
    private var vertexBuffer: MTLBuffer!
    private var uniformBuffer: MTLBuffer!
    private var startTime: Date = .init()
    private var fontAtlas: FontAtlas?
    private var fontTexture: MTLTexture?
    private var fontUniforms: FontUniforms?
    private var textMetricsBuffer: MTLBuffer?
    private var fontUniformsBuffer: MTLBuffer?
    private let maxCharacters = 100
    private let selectedFont: MSDFFontKit.Font = .ppacma
    private var displayText = "Mitakpa"
    private var charCount: Int32 = 0

    // Particle system properties
    private var particleComputePipeline: MTLComputePipelineState!
    private var particleRenderPipeline: MTLRenderPipelineState!
    private var particleBuffer: MTLBuffer!
    private var particleUniformsBuffer: MTLBuffer!
    private var particleVertexBuffer: MTLBuffer!
    private let particleCount = 500_000
    private var lastUpdateTime: Date = .init()

    // Text mask rendering properties
    private var textMaskPipeline: MTLRenderPipelineState!
    private var textMaskTexture: MTLTexture!
    private var textMaskRenderPassDescriptor: MTLRenderPassDescriptor!
    private let textMaskSize = CGSize(width: 1024, height: 256)

    struct Vertex {
        let position: SIMD2<Float>
        let texCoord: SIMD2<Float>
    }

    struct Uniforms {
        var time: Float
        var resolution: SIMD2<Float>
        var charCount: Int32
    }

    struct FontUniforms {
        var baseline: Float
        var lineHeight: Float
        var atlasSize: SIMD2<Float>
        var distanceRange: Float
    }

    struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var size: Float
        var rotation: Float
        var opacity: Float
        var targetPos: SIMD2<Float>
        var state: Float
        var holdTime: Float
    }

    struct ParticleUniforms {
        var time: Float
        var deltaTime: Float
        var particleCount: UInt32
    }

    init(device: MTLDevice) {
        self.device = device
        commandQueue = device.makeCommandQueue()!
        super.init()
        setupPipeline()
        setupBuffers()
        setupFont()
        setupTextMask()
        setupParticleSystem()
    }

    private func setupPipeline() {
        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!

        // Create vertex descriptor for all pipelines
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

        // Setup particle compute pipeline
        if let computeFunction = library.makeFunction(name: "updateParticles") {
            do {
                particleComputePipeline = try device.makeComputePipelineState(function: computeFunction)
            } catch {}
        }

        // Setup particle render pipeline
        if let particleVertexFunction = library.makeFunction(name: "particleVertex"),
           let particleFragmentFunction = library.makeFunction(name: "particleFragment")
        {
            let particleVertexDescriptor = MTLVertexDescriptor()
            particleVertexDescriptor.attributes[0].format = .float2
            particleVertexDescriptor.attributes[0].offset = 0
            particleVertexDescriptor.attributes[0].bufferIndex = 0
            particleVertexDescriptor.layouts[0].stride = MemoryLayout<SIMD2<Float>>.stride

            let particlePipelineDescriptor = MTLRenderPipelineDescriptor()
            particlePipelineDescriptor.vertexFunction = particleVertexFunction
            particlePipelineDescriptor.fragmentFunction = particleFragmentFunction
            particlePipelineDescriptor.vertexDescriptor = particleVertexDescriptor
            particlePipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            particlePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            particlePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            particlePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            particlePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            particlePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                particleRenderPipeline = try device.makeRenderPipelineState(descriptor: particlePipelineDescriptor)
            } catch {}
        }

        // Setup text mask render pipeline
        if let textMaskVertexFunction = library.makeFunction(name: "vertexShader"),
           let textMaskFragmentFunction = library.makeFunction(name: "textMaskFragment")
        {
            let textMaskPipelineDescriptor = MTLRenderPipelineDescriptor()
            textMaskPipelineDescriptor.vertexFunction = textMaskVertexFunction
            textMaskPipelineDescriptor.fragmentFunction = textMaskFragmentFunction
            textMaskPipelineDescriptor.vertexDescriptor = vertexDescriptor
            textMaskPipelineDescriptor.colorAttachments[0].pixelFormat = .r8Unorm

            do {
                textMaskPipeline = try device.makeRenderPipelineState(descriptor: textMaskPipelineDescriptor)
            } catch {}
        }

        // Create main render pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            renderPipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create render pipeline state: \(error)")
        }
    }

    private func setupBuffers() {
        let vertices: [Vertex] = [
            Vertex(position: SIMD2<Float>(-1, -1), texCoord: SIMD2<Float>(0, 1)),
            Vertex(position: SIMD2<Float>(1, -1), texCoord: SIMD2<Float>(1, 1)),
            Vertex(position: SIMD2<Float>(-1, 1), texCoord: SIMD2<Float>(0, 0)),
            Vertex(position: SIMD2<Float>(1, 1), texCoord: SIMD2<Float>(1, 0)),
        ]

        vertexBuffer = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<Vertex>.stride * vertices.count,
                                         options: [])

        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride,
                                          options: [])
    }

    private func setupFont() {
        do {
            fontAtlas = try MSDFFontKit.loadFont(selectedFont)

            guard let atlas = fontAtlas else { return }

            fontUniforms = FontUniforms(
                baseline: atlas.baseline,
                lineHeight: atlas.lineHeight,
                atlasSize: atlas.atlasSize,
                distanceRange: atlas.distanceRange
            )

            fontTexture = try atlas.loadTexture(device: device, resourceName: selectedFont.rawValue)

            let bufferSize = maxCharacters * MemoryLayout<CharMetrics>.stride
            textMetricsBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
            fontUniformsBuffer = device.makeBuffer(length: MemoryLayout<FontUniforms>.stride, options: .storageModeShared)

            updateTextMetrics()
        } catch {
            fatalError("Failed to load font: \(error)")
        }
    }

    private func setupTextMask() {
        // Create text mask texture
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: Int(textMaskSize.width),
            height: Int(textMaskSize.height),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textMaskTexture = device.makeTexture(descriptor: textureDescriptor)!

        // Create render pass descriptor
        textMaskRenderPassDescriptor = MTLRenderPassDescriptor()
        textMaskRenderPassDescriptor.colorAttachments[0].texture = textMaskTexture
        textMaskRenderPassDescriptor.colorAttachments[0].loadAction = .clear
        textMaskRenderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        textMaskRenderPassDescriptor.colorAttachments[0].storeAction = .store
    }

    private func setupParticleSystem() {
        // Create particle buffer
        let particleBufferSize = particleCount * MemoryLayout<Particle>.stride
        particleBuffer = device.makeBuffer(length: particleBufferSize, options: .storageModeShared)

        // Initialize particles by sampling the text mask to determine target positions
        initializeParticlesFromTextMask()

        // Create particle uniforms buffer
        particleUniformsBuffer = device.makeBuffer(length: MemoryLayout<ParticleUniforms>.stride, options: .storageModeShared)

        // Create quad vertices for particle instances
        let quadVertices: [SIMD2<Float>] = [
            SIMD2<Float>(-1, -1),
            SIMD2<Float>(1, -1),
            SIMD2<Float>(-1, 1),
            SIMD2<Float>(1, 1),
        ]
        particleVertexBuffer = device.makeBuffer(bytes: quadVertices,
                                                 length: MemoryLayout<SIMD2<Float>>.stride * quadVertices.count,
                                                 options: [])
    }

    private func updateTextMetrics() {
        guard let atlas = fontAtlas,
              let buffer = textMetricsBuffer else { return }

        let characters = Array(displayText)
        charCount = Int32(min(characters.count, maxCharacters))

        let pointer = buffer.contents().bindMemory(to: CharMetrics.self, capacity: maxCharacters)
        let fallbackMetrics = CharMetrics(
            atlasPos: SIMD2<Float>(0, 0),
            size: SIMD2<Float>(0, 0),
            offset: SIMD2<Float>(0, 0),
            advance: 13.0,
            charCode: 32
        )

        for i in 0 ..< Int(charCount) {
            let char = characters[i]
            pointer[i] = atlas.getMetrics(for: char) ?? atlas.getMetrics(for: " ") ?? fallbackMetrics
        }
    }

    private func initializeParticlesFromTextMask() {
        let particles = particleBuffer.contents().bindMemory(to: Particle.self, capacity: particleCount)

        // Initialize particles with target positions sampled from text shape
        for i in 0 ..< particleCount {
            // Generate target position by sampling text area until we find valid text pixels
            var targetX: Float = 0.5
            var targetY: Float = 0.5

            // Random target positions across full text area
            // Let the text mask determine which particles are visible
            targetX = Float.random(in: 0.05 ... 0.95)
            targetY = Float.random(in: 0.3 ... 0.7)

            // Much more varied starting positions - create clouds of dust
            let clusterIndex = i % 5 // Create 5 different spawn clusters
            var startX: Float = 0
            var startY: Float = 0

            switch clusterIndex {
            case 0: // Top left cloud
                startX = -0.4 - Float.random(in: 0 ... 0.3)
                startY = 0.7 + Float.random(in: -0.15 ... 0.15)
            case 1: // Middle left stream
                startX = -0.5 - Float.random(in: 0 ... 0.4)
                startY = 0.5 + Float.random(in: -0.2 ... 0.2)
            case 2: // Bottom left cloud
                startX = -0.3 - Float.random(in: 0 ... 0.3)
                startY = 0.3 + Float.random(in: -0.15 ... 0.15)
            case 3: // Far left scattered
                startX = -0.8 - Float.random(in: 0 ... 0.2)
                startY = Float.random(in: 0.2 ... 0.8)
            default: // Random positions
                startX = -0.2 - Float.random(in: 0 ... 0.6)
                startY = Float.random(in: 0.1 ... 0.9)
            }

            // Add noise to starting positions for organic feel
            startX += Float.random(in: -0.05 ... 0.05)
            startY += Float.random(in: -0.05 ... 0.05)

            // Varied spawn timing - more spaced out particles
            let waveDelay = Float(i) * 0.0008
            let randomDelay = Float.random(in: 0 ... 4.0)
            let spawnDelay = waveDelay + randomDelay

            let particleSize = Float.random(in: 0.001 ... 0.003)

            // Varied initial velocities - faster moving particles
            let velocityAngle = Float.random(in: -0.5 ... 0.5)
            let velocityMagnitude = Float.random(in: 0.03 ... 0.12)
            let baseVelocityX = velocityMagnitude * cos(velocityAngle) + 0.05
            let baseVelocityY = velocityMagnitude * sin(velocityAngle)
            let verticalBias = Float.random(in: -0.02 ... 0.01)

            particles[i] = Particle(
                position: SIMD2<Float>(startX, startY),
                velocity: SIMD2<Float>(baseVelocityX + Float.random(in: -0.01 ... 0.01),
                                       baseVelocityY + verticalBias),
                size: particleSize,
                rotation: Float.random(in: 0 ... 1) * .pi * 2,
                opacity: 0.0,
                targetPos: SIMD2<Float>(targetX, targetY),
                state: spawnDelay <= 0.01 ? 0.0 : -1.0,
                holdTime: spawnDelay
            )
        }
    }
}

extension MetalRenderer: MTKViewDelegate {
    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        // Render text mask first
        if textMaskPipeline != nil,
           let textMaskEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: textMaskRenderPassDescriptor)
        {
            renderTextMask(renderEncoder: textMaskEncoder)
            textMaskEncoder.endEncoding()
        }

        // Update particles with compute shader (now with text mask available)
        if particleComputePipeline != nil,
           let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        {
            updateParticles(computeEncoder: computeEncoder, drawableSize: view.drawableSize)
            computeEncoder.endEncoding()
        }

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let newText = "Mitakpa"
        if newText != displayText {
            displayText = newText
            updateTextMetrics()
        }

        let elapsed = Float(Date().timeIntervalSince(startTime))
        var uniforms = Uniforms(
            time: elapsed,
            resolution: SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            charCount: charCount
        )

        uniformBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<Uniforms>.stride)

        updateFontUniformsBuffer()

        configureRenderEncoder(renderEncoder)

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Render particles on top
        if particleRenderPipeline != nil {
            renderParticles(renderEncoder: renderEncoder, drawableSize: view.drawableSize)
        } else {}

        renderEncoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func updateFontUniformsBuffer() {
        guard let fontUniformsBuffer = fontUniformsBuffer,
              let fontUniforms = fontUniforms else { return }

        var uniforms = fontUniforms
        fontUniformsBuffer.contents().copyMemory(from: &uniforms, byteCount: MemoryLayout<FontUniforms>.stride)
    }

    private func configureRenderEncoder(_ renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(fontUniformsBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(textMetricsBuffer, offset: 0, index: 2)

        if let texture = fontTexture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }
    }

    private func updateParticles(computeEncoder: MTLComputeCommandEncoder, drawableSize _: CGSize) {
        let currentTime = Date()
        let deltaTime = Float(currentTime.timeIntervalSince(lastUpdateTime))
        lastUpdateTime = currentTime

        let elapsed = Float(currentTime.timeIntervalSince(startTime))

        var particleUniforms = ParticleUniforms(
            time: elapsed,
            deltaTime: min(deltaTime, 0.1),
            particleCount: UInt32(particleCount)
        )

        particleUniformsBuffer.contents().copyMemory(from: &particleUniforms,
                                                     byteCount: MemoryLayout<ParticleUniforms>.stride)

        computeEncoder.setComputePipelineState(particleComputePipeline)
        computeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(particleUniformsBuffer, offset: 0, index: 1)
        computeEncoder.setTexture(textMaskTexture, index: 0)

        let threadsPerThreadgroup = MTLSize(width: 64, height: 1, depth: 1)
        let threadgroups = MTLSize(width: (particleCount + 63) / 64, height: 1, depth: 1)
        computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
    }

    private func renderParticles(renderEncoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        var resolution = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        // Use standard rendering with GPU optimizations
        renderEncoder.setRenderPipelineState(particleRenderPipeline)
        renderEncoder.setVertexBuffer(particleVertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(particleBuffer, offset: 0, index: 1)
        renderEncoder.setVertexBytes(&resolution, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)

        // Draw instanced quads for all particles
        renderEncoder.drawPrimitives(type: .triangleStrip,
                                     vertexStart: 0,
                                     vertexCount: 4,
                                     instanceCount: particleCount)
    }

    private func renderTextMask(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(textMaskPipeline)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentBuffer(fontUniformsBuffer, offset: 0, index: 1)
        renderEncoder.setFragmentBuffer(textMetricsBuffer, offset: 0, index: 2)

        if let texture = fontTexture {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }

        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
