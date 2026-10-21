import AppKit
import CoreImage
import Vision

struct ImageEditing {
    static func normalizedPNG(_ data: Data) throws -> Data {
        guard let image = CIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        return try png(image)
    }
    static func rotate(_ data: Data, clockwise: Bool) throws -> Data {
        guard let image = CIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let rotated = image.transformed(by: CGAffineTransform(rotationAngle: clockwise ? -.pi / 2 : .pi / 2))
        let normalized = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX, y: -rotated.extent.minY))
        return try png(normalized)
    }
    static func removeBackground(_ data: Data) throws -> Data {
        let handler = VNImageRequestHandler(data: data)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw CocoaError(.featureUnsupported) }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        return try png(CIImage(cvPixelBuffer: buffer))
    }
    private static func png(_ image: CIImage) throws -> Data {
        guard let cgImage = CIContext().createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return data
    }
}
