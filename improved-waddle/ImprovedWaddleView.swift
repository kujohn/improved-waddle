import ScreenSaver
import MetalKit
import MSDFFontKit

class ImprovedWaddleView: ScreenSaverView {
    private var metalView: MTKView!
    private var renderer: MetalRenderer!
    
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setupMetal()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMetal()
    }
    
    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }
        
        metalView = MTKView(frame: bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60
        
        renderer = MetalRenderer(device: device)
        metalView.delegate = renderer
        
        addSubview(metalView)
    }
    
    override var hasConfigureSheet: Bool {
        return false
    }
    
    override var configureSheet: NSWindow? {
        return nil
    }
}