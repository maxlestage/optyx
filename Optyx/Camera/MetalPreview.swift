import CoreImage
import MetalKit
import SwiftUI

/// Affichage Metal du viseur : la chaîne de filtres est exécutée une seule
/// fois par trame caméra (rendue dans un CVPixelBuffer côté caméra) ; la
/// boucle d'affichage ne fait que recopier cette texture vers le drawable,
/// sans jamais re-exécuter les filtres ni repasser par le CPU.
final class PreviewRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let context: CIContext?
    private let lock = NSLock()
    private var image: CIImage?

    override init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()
        context = device.map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }
        super.init()
    }

    /// Publie une trame déjà rendue (wrapper de pixel buffer, pas une
    /// recette de filtres). Appelable depuis n'importe quelle file.
    func present(_ newImage: CIImage) {
        lock.lock()
        image = newImage
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let current = image
        lock.unlock()
        guard let current, let context, let commandQueue,
              !current.extent.isEmpty,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: drawableSize)

        // Aspect-fit centré sur fond noir.
        let scale = min(drawableSize.width / current.extent.width,
                        drawableSize.height / current.extent.height)
        let scaled = current.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let dx = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.minX
        let dy = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.minY
        let composed = scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .composited(over: CIImage(color: .black).cropped(to: bounds))

        context.render(composed, to: drawable.texture, commandBuffer: commandBuffer,
                       bounds: bounds,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
                           ?? CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Enveloppe SwiftUI de la MTKView du viseur.
struct MetalPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
