import AVFoundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Construit le fichier photo final pour les photographes : rendu vintage
/// + métadonnées EXIF/TIFF/GPS de la capture d'origine préservées
/// + carte de profondeur (LiDAR / double objectif) embarquée en donnée
/// auxiliaire + distance au sujet inscrite dans l'EXIF.
enum PhotoMetadata {

    /// Encode l'image rendue en HEIC (JPEG en repli) avec :
    /// - toutes les métadonnées de la capture d'origine (exposition, ISO,
    ///   focale réelle, GPS…) ;
    /// - la carte de profondeur en donnée auxiliaire — la photo reste
    ///   ré-éditable avec sa profondeur, y compris dans le Studio d'Optyx ;
    /// - `SubjectDistance` / `SubjectDistRange` EXIF mesurés sur la carte
    ///   de profondeur (l'information de profondeur de champ) ;
    /// - l'objectif simulé consigné dans `LensModel` et `UserComment`.
    ///
    /// `depthData` vient d'une capture caméra ; s'il est nil, les données
    /// auxiliaires (matte portrait, disparité, profondeur) sont recopiées
    /// depuis `originalData` (cas du Studio).
    static func vintageImageData(rendered: UIImage,
                                 originalData: Data?,
                                 depthData: AVDepthData?,
                                 lens: LensProfile,
                                 intensity: Double) -> Data? {
        guard let cgImage = rendered.cgImage else { return nil }

        let source = originalData.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        var properties = source.flatMap {
            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
        } ?? [:]

        // L'orientation est déjà appliquée dans les pixels rendus.
        properties[kCGImagePropertyOrientation] = 1
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFSoftware] = "Optyx"
        properties[kCGImagePropertyTIFFDictionary] = tiff

        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifLensModel] = "\(lens.name) \(lens.focal) — simulation Optyx"
        exif[kCGImagePropertyExifUserComment] =
            "Simulation \(lens.name) à \(Int(intensity * 100)) %. "
            + "Profondeur mesurée par LiDAR / double objectif."
        if let distance = subjectDistance(from: depthData) {
            exif[kCGImagePropertyExifSubjectDistance] = distance
            exif[kCGImagePropertyExifSubjectDistRange] = distanceRange(distance)
        }
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92

        let data = NSMutableData()
        guard let destination =
                CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil)
                ?? CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        if let depthData {
            // Capture caméra : profondeur AVFoundation embarquée telle quelle.
            var auxTypeOut: NSString?
            if let auxDict = depthData.dictionaryRepresentation(forAuxiliaryDataType: &auxTypeOut),
               let auxTypeOut {
                CGImageDestinationAddAuxiliaryDataInfo(destination, auxTypeOut as CFString,
                                                       auxDict as CFDictionary)
            }
        } else if let source {
            // Studio : recopie les données auxiliaires du fichier d'origine.
            for auxType in [kCGImageAuxiliaryDataTypePortraitEffectsMatte,
                            kCGImageAuxiliaryDataTypeDisparity,
                            kCGImageAuxiliaryDataTypeDepth] {
                if let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxType) {
                    CGImageDestinationAddAuxiliaryDataInfo(destination, auxType, info)
                }
            }
        }

        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Distance au sujet en mètres : médiane d'une fenêtre centrale (20 %)
    /// de la carte de profondeur convertie en mètres.
    static func subjectDistance(from depthData: AVDepthData?) -> Double? {
        guard let depthData else { return nil }
        let depth = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = depth.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 4, height > 4 else { return nil }

        var samples: [Float] = []
        let step = max(1, width / 64)
        for y in stride(from: Int(Double(height) * 0.4),
                        to: Int(Double(height) * 0.6), by: step) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
            for x in stride(from: Int(Double(width) * 0.4),
                            to: Int(Double(width) * 0.6), by: step) {
                let value = row[x]
                if value.isFinite && value > 0 { samples.append(value) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return Double(samples[samples.count / 2])
    }

    /// Code EXIF SubjectDistRange : 1 macro (< 1 m), 2 rapproché (< 3 m),
    /// 3 lointain.
    private static func distanceRange(_ meters: Double) -> Int {
        if meters < 1 { return 1 }
        if meters < 3 { return 2 }
        return 3
    }
}
