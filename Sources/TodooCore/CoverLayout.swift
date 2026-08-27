import Foundation

public struct CoverLayout: Equatable, Sendable {
    public let rotation: Int
    public let zoom: Double
    public let scale: Double
    public let drawWidth: Double
    public let drawHeight: Double
    public let rotatedDrawWidth: Double
    public let rotatedDrawHeight: Double
    public let overflowX: Double
    public let overflowY: Double
    public let cropX: Double
    public let cropY: Double
}

public enum CoverLayoutError: Error, LocalizedError {
    case invalidSource
    case invalidTarget
    case invalidRotation
    case invalidZoom

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "原图尺寸无效。"
        case .invalidTarget: return "目标尺寸无效。"
        case .invalidRotation: return "旋转角度必须为 0、90、180 或 270。"
        case .invalidZoom: return "图片缩放必须在 1×–8× 之间。"
        }
    }
}

public func computeCoverLayout(
    sourceWidth: Double,
    sourceHeight: Double,
    targetWidth: Double = Double(CardDisplay.width),
    targetHeight: Double = Double(CardDisplay.height),
    rotation: Int = 0,
    focusX: Double = 50,
    focusY: Double = 50,
    zoom: Double = 1
) throws -> CoverLayout {
    guard sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else {
        throw CoverLayoutError.invalidSource
    }
    guard targetWidth.isFinite, targetHeight.isFinite, targetWidth > 0, targetHeight > 0 else {
        throw CoverLayoutError.invalidTarget
    }
    guard [0, 90, 180, 270].contains(rotation) else { throw CoverLayoutError.invalidRotation }
    guard zoom.isFinite, (1 ... 8).contains(zoom) else { throw CoverLayoutError.invalidZoom }

    let rotatedWidth = rotation.isMultiple(of: 180) ? sourceWidth : sourceHeight
    let rotatedHeight = rotation.isMultiple(of: 180) ? sourceHeight : sourceWidth
    let baseScale = max(targetWidth / rotatedWidth, targetHeight / rotatedHeight)
    let scale = baseScale * zoom
    let drawWidth = sourceWidth * scale
    let drawHeight = sourceHeight * scale
    let rotatedDrawWidth = rotatedWidth * scale
    let rotatedDrawHeight = rotatedHeight * scale
    let overflowX = max(0, rotatedDrawWidth - targetWidth)
    let overflowY = max(0, rotatedDrawHeight - targetHeight)
    let cropX = overflowX * min(100, max(0, focusX)) / 100
    let cropY = overflowY * min(100, max(0, focusY)) / 100

    return CoverLayout(
        rotation: rotation,
        zoom: zoom,
        scale: scale,
        drawWidth: drawWidth,
        drawHeight: drawHeight,
        rotatedDrawWidth: rotatedDrawWidth,
        rotatedDrawHeight: rotatedDrawHeight,
        overflowX: overflowX,
        overflowY: overflowY,
        cropX: cropX,
        cropY: cropY
    )
}

