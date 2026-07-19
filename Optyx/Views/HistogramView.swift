import SwiftUI

/// Histogramme RVB superposé, dessiné en mode écran comme sur les
/// boîtiers photo. Les données arrivent normalisées 0…1 par canal.
struct HistogramView: View {
    let data: CameraController.HistogramData

    var body: some View {
        Canvas { context, size in
            context.blendMode = .screen
            let channels: [(values: [Float], color: Color)] = [
                (data.red, .red),
                (data.green, .green),
                (data.blue, Color(red: 0.35, green: 0.55, blue: 1.0)),
            ]
            for channel in channels {
                let values = channel.values
                guard values.count > 1 else { continue }
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = size.height * CGFloat(1 - min(1, value))
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(path, with: .color(channel.color.opacity(0.65)))
            }
        }
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        .allowsHitTesting(false)
    }
}
