import Foundation

public enum PayloadError: Error, LocalizedError, Equatable {
    case invalidCodeCount(actual: Int, expected: Int)
    case unsupportedColor(code: UInt8, pixel: Int)
    case rawSizeNotDivisibleBy64(actual: Int)
    case invalidPayloadSize(actual: Int, expected: Int)
    case missingZeroPrefix
    case invalidStoredHeader(block: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidCodeCount(actual, expected):
            return "预览包含 \(actual) 个像素，应为 \(expected) 个。"
        case let .unsupportedColor(code, pixel):
            return "像素 \(pixel) 使用了不支持的颜色代码 \(code)。"
        case let .rawSizeNotDivisibleBy64(actual):
            return "原始位图为 \(actual) 字节，不能按 64 字节分块。"
        case let .invalidPayloadSize(actual, expected):
            return "Payload 为 \(actual) 字节，应为 \(expected) 字节。"
        case .missingZeroPrefix:
            return "Payload 缺少四字节零前缀。"
        case let .invalidStoredHeader(block):
            return "QuickLZ stored 块 \(block) 的头部无效。"
        }
    }
}

public struct PayloadValidation: Equatable, Sendable {
    public let blocks: Int
    public let decodedBytes: Int
    public let payloadBytes: Int
}

public struct BuiltPayload: Equatable, Sendable {
    public let data: Data
    public let validation: PayloadValidation
}

public enum T3PayloadBuilder {
    public static let decodedBlockSize = 64
    public static let storedBlockSize = 67
    public static let expectedPayloadBytes = 4 + (CardDisplay.rawByteCount / decodedBlockSize) * storedBlockSize

    public static func packColorCodes(_ codes: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: (codes.count + 1) / 2)
        for (index, code) in codes.enumerated() {
            guard code <= 0x0F else { throw PayloadError.unsupportedColor(code: code, pixel: index) }
            if index.isMultiple(of: 2) {
                output[index / 2] = code << 4
            } else {
                output[index / 2] |= code
            }
        }
        return output
    }

    public static func rotate180(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        let pixelCount = width * height
        var output = [UInt8](repeating: 0, count: input.count)
        for source in 0 ..< pixelCount {
            setPackedCode(&output, pixelIndex: pixelCount - 1 - source, code: packedCode(input, pixelIndex: source))
        }
        return output
    }

    public static func flipHorizontal(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let source = y * width + x
                let destination = y * width + width - 1 - x
                setPackedCode(&output, pixelIndex: destination, code: packedCode(input, pixelIndex: source))
            }
        }
        return output
    }

    public static func rotateClockwiseMirrored(_ input: [UInt8], width: Int, height: Int) -> [UInt8] {
        let destinationWidth = height
        var output = [UInt8](repeating: 0, count: input.count)
        for destination in 0 ..< width * height {
            let destinationX = destination % destinationWidth
            let destinationY = destination / destinationWidth
            let sourceX = width - 1 - destinationY
            let sourceY = height - 1 - destinationX
            setPackedCode(
                &output,
                pixelIndex: destination,
                code: packedCode(input, pixelIndex: sourceY * width + sourceX)
            )
        }
        return output
    }

    public static func quickLZStored(_ raw: [UInt8]) throws -> Data {
        guard raw.count.isMultiple(of: decodedBlockSize) else {
            throw PayloadError.rawSizeNotDivisibleBy64(actual: raw.count)
        }
        let blockCount = raw.count / decodedBlockSize
        var output = [UInt8](repeating: 0, count: 4 + blockCount * storedBlockSize)
        var outputOffset = 4
        var inputOffset = 0
        while inputOffset < raw.count {
            output[outputOffset] = 0x74
            output[outputOffset + 1] = 0x43
            output[outputOffset + 2] = 0x40
            output.replaceSubrange(
                (outputOffset + 3) ..< (outputOffset + storedBlockSize),
                with: raw[inputOffset ..< (inputOffset + decodedBlockSize)]
            )
            outputOffset += storedBlockSize
            inputOffset += decodedBlockSize
        }
        return Data(output)
    }

    public static func build(from previewCodes: [UInt8]) throws -> BuiltPayload {
        guard previewCodes.count == CardDisplay.pixelCount else {
            throw PayloadError.invalidCodeCount(actual: previewCodes.count, expected: CardDisplay.pixelCount)
        }
        let validCodes = Set(nativePalette.map(\.code))
        for (index, code) in previewCodes.enumerated() where !validCodes.contains(code) {
            throw PayloadError.unsupportedColor(code: code, pixel: index)
        }
        let upright = try packColorCodes(previewCodes)
        let calibrated = flipHorizontal(
            rotate180(upright, width: CardDisplay.width, height: CardDisplay.height),
            width: CardDisplay.width,
            height: CardDisplay.height
        )
        let controllerRaw = rotateClockwiseMirrored(
            calibrated,
            width: CardDisplay.width,
            height: CardDisplay.height
        )
        let payload = try quickLZStored(controllerRaw)
        let validation = try validate(payload)
        return BuiltPayload(data: payload, validation: validation)
    }

    public static func validate(_ payload: Data) throws -> PayloadValidation {
        guard payload.count == expectedPayloadBytes else {
            throw PayloadError.invalidPayloadSize(actual: payload.count, expected: expectedPayloadBytes)
        }
        guard payload.prefix(4).allSatisfy({ $0 == 0 }) else { throw PayloadError.missingZeroPrefix }
        var block = 0
        var offset = 4
        while offset < payload.count {
            guard payload[offset] == 0x74, payload[offset + 1] == 0x43, payload[offset + 2] == 0x40 else {
                throw PayloadError.invalidStoredHeader(block: block)
            }
            block += 1
            offset += storedBlockSize
        }
        return PayloadValidation(blocks: block, decodedBytes: CardDisplay.rawByteCount, payloadBytes: payload.count)
    }

    private static func packedCode(_ bytes: [UInt8], pixelIndex: Int) -> UInt8 {
        let byte = bytes[pixelIndex / 2]
        return pixelIndex.isMultiple(of: 2) ? byte >> 4 : byte & 0x0F
    }

    private static func setPackedCode(_ bytes: inout [UInt8], pixelIndex: Int, code: UInt8) {
        let byteIndex = pixelIndex / 2
        if pixelIndex.isMultiple(of: 2) {
            bytes[byteIndex] = (bytes[byteIndex] & 0x0F) | (code << 4)
        } else {
            bytes[byteIndex] = (bytes[byteIndex] & 0xF0) | (code & 0x0F)
        }
    }
}

