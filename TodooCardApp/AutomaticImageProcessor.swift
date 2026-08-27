import Foundation
import UIKit

struct AutomaticImageConfiguration: Sendable {
    let rotation: Int
    let focusX: Double
    let focusY: Double
    let zoom: Double
    let algorithm: DitherAlgorithm
    let strength: Float
    let brightnessCompensation: Float

    static let standard = AutomaticImageConfiguration(
        rotation: 0,
        focusX: 50,
        focusY: 50,
        zoom: 1,
        algorithm: .floydSteinberg,
        strength: 1,
        brightnessCompensation: 0
    )
}

enum AutomaticImageProcessor {
    static let maximumImageBytes = 100_000_000
    static let maximumImagePixels = 50_000_000

    static func makePayload(
        from data: Data,
        configuration: AutomaticImageConfiguration
    ) throws -> Data {
        guard !data.isEmpty else { throw AutomaticUpdateError.emptyImage }
        guard data.count <= maximumImageBytes else { throw AutomaticUpdateError.imageTooLarge }
        guard let decoded = UIImage(data: data) else { throw AutomaticUpdateError.invalidImage }

        let pixelWidth = decoded.cgImage?.width ?? Int(decoded.size.width * decoded.scale)
        let pixelHeight = decoded.cgImage?.height ?? Int(decoded.size.height * decoded.scale)
        let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixelCount <= maximumImagePixels else {
            throw AutomaticUpdateError.tooManyPixels
        }

        let request = ImageProcessingRequest(
            image: ImageProcessor.normalized(decoded),
            rotation: configuration.rotation,
            focusX: configuration.focusX,
            focusY: configuration.focusY,
            zoom: configuration.zoom,
            algorithm: configuration.algorithm,
            strength: configuration.strength,
            brightnessCompensation: configuration.brightnessCompensation
        )
        return try ImageProcessor.process(request).payload
    }
}

enum AutomaticUpdateError: LocalizedError {
    case emptyImage
    case imageTooLarge
    case invalidImage
    case tooManyPixels
    case transferInProgress
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyImage:
            return "没有收到图片内容。"
        case .imageTooLarge:
            return "图片超过 100 MB 安全限制。"
        case .invalidImage:
            return "无法解码图片，请改用 PNG、JPEG、HEIF 或 WebP。"
        case .tooManyPixels:
            return "图片超过 5000 万像素安全限制。"
        case .transferInProgress:
            return "TodooCard 正在执行另一项发送。"
        case .transferFailed(let message):
            return message
        }
    }
}
