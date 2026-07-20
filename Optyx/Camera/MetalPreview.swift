import AVKit
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
    /// Génération de la trame présentée : le blit n'est exécuté qu'UNE fois
    /// par nouvelle trame. Re-blitter à 120 Hz une image dont le buffer
    /// sous-jacent est réécrit par l'anneau produisait des flashs
    /// périodiques (scintillement mesuré toutes les ~5 trames caméra).
    private var generation = 0
    private var drawnGeneration = -1

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
        generation &+= 1
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        lock.lock()
        let current = image
        let currentGeneration = generation
        lock.unlock()
        // Déjà affichée : le drawable précédent reste à l'écran.
        guard currentGeneration != drawnGeneration else { return }
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
        drawnGeneration = currentGeneration
    }
}

/// Enveloppe SwiftUI de la MTKView du viseur.
struct MetalPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer
    /// Déclencheur matériel : appelé quand l'utilisateur appuie sur un
    /// bouton de volume (ou le bouton Commande de l'appareil photo) alors
    /// que le viseur est actif — comme l'app Appareil photo d'Apple.
    var onHardwareShutter: (() -> Void)?

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        // 120 Hz : le blit est quasi gratuit, et une boucle d'affichage à
        // 30 Hz non synchronisée avec l'arrivée des trames caméra ajoutait
        // jusqu'à 33 ms de gigue de présentation (saccades perçues).
        view.preferredFramesPerSecond = 120
        view.backgroundColor = .black

        if #available(iOS 17.2, *), let onHardwareShutter {
            // L'interaction ne capte les boutons physiques que lorsqu'une
            // session de capture est active ; sinon iOS garde son
            // comportement normal (volume).
            let interaction = AVCaptureEventInteraction { event in
                guard event.phase == .ended else { return }
                onHardwareShutter()
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
