import CoreImage
import UIKit

/// Génère une scène de test procédurale (points lumineux sur fond sombre)
/// pour visualiser la signature de bokeh de chaque objectif dans le catalogue.
enum BokehPreview {

    /// Générateur pseudo-aléatoire déterministe : les aperçus sont stables.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    static func testScene(size: CGSize = CGSize(width: 720, height: 480)) -> CIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.05, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Léger dégradé de "rue de nuit"
            let colors = [UIColor(white: 0.10, alpha: 1).cgColor,
                          UIColor(white: 0.03, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 0, y: size.height),
                    options: [])
            }

            var rng = SeededGenerator(state: 0x0517_1936)
            let palette: [UIColor] = [
                UIColor(red: 1.00, green: 0.85, blue: 0.55, alpha: 1),
                UIColor(red: 1.00, green: 0.95, blue: 0.85, alpha: 1),
                UIColor(red: 0.65, green: 0.80, blue: 1.00, alpha: 1),
                UIColor(red: 1.00, green: 0.60, blue: 0.45, alpha: 1),
                UIColor(red: 0.75, green: 1.00, blue: 0.75, alpha: 1),
            ]

            for _ in 0..<46 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 0...size.height, using: &rng)
                let radius = CGFloat.random(in: 1.5...5.5, using: &rng)
                let color = palette[Int.random(in: 0..<palette.count, using: &rng)]
                color.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: x - radius, y: y - radius,
                                                     width: radius * 2, height: radius * 2))
            }

            // Silhouette de "sujet" au premier plan pour donner l'échelle
            UIColor(white: 0.16, alpha: 1).setFill()
            let subject = CGRect(x: size.width * 0.42, y: size.height * 0.45,
                                 width: size.width * 0.16, height: size.height * 0.55)
            ctx.cgContext.fillEllipse(in: subject)
        }
        return CIImage(image: image)
    }

    /// Scène de test rendue à travers un objectif donné.
    static func render(lens: LensProfile) -> UIImage? {
        guard let scene = testScene() else { return nil }
        return LensEngine.shared.renderUIImage(scene, lens: lens, intensity: 1.0)
    }
}
