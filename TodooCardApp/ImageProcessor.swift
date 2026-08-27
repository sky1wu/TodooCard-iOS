import CryptoKit
import UIKit
#if canImport(TodooCore)
import TodooCore
#endif

struct ImageProcessingRequest: @unchecked Sendable {
    let image: UIImage
    let rotation: Int
    let focusX: Double
    let focusY: Double
    let zoom: Double
    let algorithm: DitherAlgorithm
    let strength: Float
}

struct ImageProcessingResult: @unchecked Sendable {
    let preview: UIImage
    let payload: Data
    let payloadSHA256: String
    let validation: PayloadValidation
}

enum ImageProcessorError: Error, LocalizedError {
    case renderFailed
    case bitmapContextFailed
    case previewCreationFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "无法生成目标尺寸的图片。"
        case .bitmapContextFailed: return "无法读取图片像素。"
        case .previewCreationFailed: return "无法生成六色预览。"
        }
    }
}

enum ImageProcessor {
    static func process(_ request: ImageProcessingRequest) throws -> ImageProcessingResult {
        let rendered = try renderCover(request)
        let rgba = try rgbaBytes(from: rendered)
        let codes = try ditherRGBA(
            rgba,
            width: CardDisplay.width,
            height: CardDisplay.height,
            algorithm: request.algorithm,
            strength: request.strength
        )
        let built = try T3PayloadBuilder.build(from: codes)
        let preview = try previewImage(from: codes)
        let digest = SHA256.hash(data: built.data).map { String(format: "%02x", $0) }.joined()
        return ImageProcessingResult(
            preview: preview,
            payload: built.data,
            payloadSHA256: digest,
            validation: built.validation
        )
    }

    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    private static func renderCover(_ request: ImageProcessingRequest) throws -> UIImage {
        let image = normalized(request.image)
        let layout = try computeCoverLayout(
            sourceWidth: image.size.width,
            sourceHeight: image.size.height,
            rotation: request.rotation,
            focusX: request.focusX,
            focusY: request.focusY,
            zoom: request.zoom
        )
        let target = CGSize(width: CardDisplay.width, height: CardDisplay.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: target, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: target))
            let graphics = context.cgContext
            graphics.saveGState()
            switch request.rotation {
            case 0:
                graphics.translateBy(x: -layout.cropX, y: -layout.cropY)
            case 90:
                graphics.translateBy(x: layout.rotatedDrawWidth - layout.cropX, y: -layout.cropY)
                graphics.rotate(by: .pi / 2)
            case 180:
                graphics.translateBy(
                    x: layout.rotatedDrawWidth - layout.cropX,
                    y: layout.rotatedDrawHeight - layout.cropY
                )
                graphics.rotate(by: .pi)
            case 270:
                graphics.translateBy(x: -layout.cropX, y: layout.rotatedDrawHeight - layout.cropY)
                graphics.rotate(by: -.pi / 2)
            default:
                break
            }
            graphics.interpolationQuality = .high
            image.draw(in: CGRect(x: 0, y: 0, width: layout.drawWidth, height: layout.drawHeight))
            graphics.restoreGState()
        }
    }

    private static func rgbaBytes(from image: UIImage) throws -> [UInt8] {
        guard let cgImage = image.cgImage else { throw ImageProcessorError.renderFailed }
        let width = CardDisplay.width
        let height = CardDisplay.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw ImageProcessorError.bitmapContextFailed }
        return bytes
    }

    private static func previewImage(from codes: [UInt8]) throws -> UIImage {
        var rgba = [UInt8](repeating: 255, count: codes.count * 4)
        let palette = Dictionary(uniqueKeysWithValues: nativePalette.map { ($0.code, $0) })
        for (index, code) in codes.enumerated() {
            guard let color = palette[code] else { continue }
            let offset = index * 4
            rgba[offset] = color.red
            rgba[offset + 1] = color.green
            rgba[offset + 2] = color.blue
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(
                width: CardDisplay.width,
                height: CardDisplay.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: CardDisplay.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { throw ImageProcessorError.previewCreationFailed }
        return UIImage(cgImage: image, scale: 1, orientation: .up)
    }
}
