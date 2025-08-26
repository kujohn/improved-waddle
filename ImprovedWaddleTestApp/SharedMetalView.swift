import SwiftUI
import MetalKit

struct SharedMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        
        let metalView = MTKView()
        metalView.device = device
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        metalView.preferredFramesPerSecond = 60
        
        let renderer = MetalRenderer(device: device)
        metalView.delegate = renderer
        context.coordinator.renderer = renderer
        
        return metalView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var renderer: MetalRenderer?
    }
}