import Foundation

public struct NativeColor: Equatable, Sendable {
    public let code: UInt8
    public let name: String
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(code: UInt8, name: String, red: UInt8, green: UInt8, blue: UInt8) {
        self.code = code
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public let nativePalette: [NativeColor] = [
    NativeColor(code: 0, name: "black", red: 0, green: 0, blue: 0),
    NativeColor(code: 1, name: "white", red: 255, green: 255, blue: 255),
    NativeColor(code: 2, name: "yellow", red: 255, green: 255, blue: 0),
    NativeColor(code: 3, name: "red", red: 255, green: 0, blue: 0),
    NativeColor(code: 5, name: "blue", red: 0, green: 0, blue: 255),
    NativeColor(code: 6, name: "green", red: 0, green: 255, blue: 0),
]

public enum DitherAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case floydSteinberg
    case atkinson
    case orderedBayer
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .floydSteinberg: return "Floyd–Steinberg"
        case .atkinson: return "Atkinson"
        case .orderedBayer: return "Bayer 4×4"
        case .none: return "最近色"
        }
    }

    public var subtitle: String {
        switch self {
        case .floydSteinberg: return "细节均衡"
        case .atkinson: return "颗粒更轻"
        case .orderedBayer: return "规则网点"
        case .none: return "纯色块"
        }
    }
}

public enum BitmapError: Error, LocalizedError, Equatable {
    case invalidDimensions
    case invalidByteCount(actual: Int, expected: Int)
    case invalidStrength

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            return "位图尺寸必须为正整数。"
        case let .invalidByteCount(actual, expected):
            return "RGBA 位图有 \(actual) 字节，应为 \(expected) 字节。"
        case .invalidStrength:
            return "抖动强度必须在 0–150% 之间。"
        }
    }
}

public func nearestNativeColor(red: Float, green: Float, blue: Float) -> NativeColor {
    var selected = nativePalette[0]
    var bestDistance = Float.greatestFiniteMagnitude
    for color in nativePalette {
        let dr = red - Float(color.red)
        let dg = green - Float(color.green)
        let db = blue - Float(color.blue)
        let distance = dr * dr + dg * dg + db * db
        if distance < bestDistance {
            bestDistance = distance
            selected = color
        }
    }
    return selected
}

public func ditherRGBA(
    _ rgba: [UInt8],
    width: Int,
    height: Int,
    algorithm: DitherAlgorithm = .floydSteinberg,
    strength: Float = 1
) throws -> [UInt8] {
    guard width > 0, height > 0 else { throw BitmapError.invalidDimensions }
    let pixelCount = width * height
    guard rgba.count == pixelCount * 4 else {
        throw BitmapError.invalidByteCount(actual: rgba.count, expected: pixelCount * 4)
    }
    guard strength.isFinite, (0 ... 1.5).contains(strength) else {
        throw BitmapError.invalidStrength
    }

    var working = [Float](repeating: 0, count: pixelCount * 3)
    for pixel in 0 ..< pixelCount {
        let source = pixel * 4
        let target = pixel * 3
        let alpha = Float(rgba[source + 3]) / 255
        working[target] = Float(rgba[source]) * alpha + 255 * (1 - alpha)
        working[target + 1] = Float(rgba[source + 1]) * alpha + 255 * (1 - alpha)
        working[target + 2] = Float(rgba[source + 2]) * alpha + 255 * (1 - alpha)
    }

    let bayer: [Float] = [
        0, 8, 2, 10,
        12, 4, 14, 6,
        3, 11, 1, 9,
        15, 7, 13, 5,
    ]
    var codes = [UInt8](repeating: 0, count: pixelCount)

    @inline(__always)
    func clamped(_ value: Float) -> Float { min(255, max(0, value)) }

    @inline(__always)
    func addError(
        _ x: Int,
        _ y: Int,
        _ red: Float,
        _ green: Float,
        _ blue: Float,
        _ weight: Float,
        to values: inout [Float]
    ) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        let offset = (y * width + x) * 3
        values[offset] += red * weight
        values[offset + 1] += green * weight
        values[offset + 2] += blue * weight
    }

    for y in 0 ..< height {
        for x in 0 ..< width {
            let pixel = y * width + x
            let offset = pixel * 3
            let orderedOffset: Float
            if algorithm == .orderedBayer {
                orderedOffset = ((bayer[(y % 4) * 4 + x % 4] + 0.5) / 16 - 0.5) * 96 * strength
            } else {
                orderedOffset = 0
            }

            let red = clamped(working[offset] + orderedOffset)
            let green = clamped(working[offset + 1] + orderedOffset)
            let blue = clamped(working[offset + 2] + orderedOffset)
            let selected = nearestNativeColor(red: red, green: green, blue: blue)
            codes[pixel] = selected.code

            guard algorithm != .none, algorithm != .orderedBayer, strength > 0 else { continue }
            let errorRed = red - Float(selected.red)
            let errorGreen = green - Float(selected.green)
            let errorBlue = blue - Float(selected.blue)
            if algorithm == .atkinson {
                let weight = strength / 8
                addError(x + 1, y, errorRed, errorGreen, errorBlue, weight, to: &working)
                addError(x + 2, y, errorRed, errorGreen, errorBlue, weight, to: &working)
                addError(x - 1, y + 1, errorRed, errorGreen, errorBlue, weight, to: &working)
                addError(x, y + 1, errorRed, errorGreen, errorBlue, weight, to: &working)
                addError(x + 1, y + 1, errorRed, errorGreen, errorBlue, weight, to: &working)
                addError(x, y + 2, errorRed, errorGreen, errorBlue, weight, to: &working)
            } else {
                addError(x + 1, y, errorRed, errorGreen, errorBlue, 7 / 16 * strength, to: &working)
                addError(x - 1, y + 1, errorRed, errorGreen, errorBlue, 3 / 16 * strength, to: &working)
                addError(x, y + 1, errorRed, errorGreen, errorBlue, 5 / 16 * strength, to: &working)
                addError(x + 1, y + 1, errorRed, errorGreen, errorBlue, 1 / 16 * strength, to: &working)
            }
        }
    }
    return codes
}

