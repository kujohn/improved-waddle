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
    private let selectedFont: MSDFFontKit.Font = .ppacmaBlack
    private var displayText = "19"
    private var charCount: Int32 = 0

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

    init(device: MTLDevice) {
        self.device = device
        commandQueue = device.makeCommandQueue()!
        super.init()
        setupPipeline()
        setupBuffers()
        setupFont()
    }

    private func setupPipeline() {
        let library = device.makeDefaultLibrary()!
        let vertexFunction = library.makeFunction(name: "vertexShader")!
        let fragmentFunction = library.makeFunction(name: "fragmentShader")!

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride

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
}

extension MetalRenderer: MTKViewDelegate {
    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
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
}
