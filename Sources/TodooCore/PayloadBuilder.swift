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

public struct QuickLZPayloadInfo: Equatable, Sendable {
    public let payloadBytes: Int
    public let decodedBytes: Int
    public let blocks: Int
    public let compressedBlocks: Int
    public let storedBlocks: Int
    public let levels: Set<Int>
}

/// 同一张控制器位图的三种线格式。旧固件只认 64 字节 stored 流；v157+
/// 可以在 2 KB level-3 流与 RAW 位图之间选择传输块数更少的一个。
public struct T3PayloadSet: Equatable, Sendable {
    public let currentCompressed: Data?
    public let legacyCompressed: Data
    public let controllerRaw: Data?

    public init(currentCompressed: Data?, legacyCompressed: Data, controllerRaw: Data?) {
        self.currentCompressed = currentCompressed
        self.legacyCompressed = legacyCompressed
        self.controllerRaw = controllerRaw
    }

    public static func legacyOnly(_ data: Data) -> T3PayloadSet {
        T3PayloadSet(currentCompressed: nil, legacyCompressed: data, controllerRaw: nil)
    }

    /// 尚未选定设备时，界面展示新版压缩流的大小和摘要；迁移记录则回退到旧流。
    public var representativeData: Data { currentCompressed ?? legacyCompressed }
    public var count: Int { representativeData.count }
    public var isEmpty: Bool { legacyCompressed.isEmpty && currentCompressed?.isEmpty != false }
}

public enum T3TransferPayloadKind: Equatable, Sendable {
    case currentCompressed
    case legacyCompressed
    case controllerRaw
}

public struct SelectedT3TransferPayload: Equatable, Sendable {
    public let data: Data
    public let kind: T3TransferPayloadKind
    public let compressed: Bool
    public let usesVerifiedWindows: Bool
    public let paddingBytes: Int
}

public enum T3PayloadBuilder {
    public static let decodedBlockSize = 64
    public static let storedBlockSize = 67
    public static let currentBlockSize = 2_048
    public static let expectedPayloadBytes = 4 + (CardDisplay.rawByteCount / decodedBlockSize) * storedBlockSize
    private static let level3HashValues = 4_096
    private static let level3Pointers = 16

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

    public static func quickLZLevel3(_ raw: [UInt8]) throws -> Data {
        guard raw.count == CardDisplay.rawByteCount else {
            throw PayloadError.invalidPayloadSize(actual: raw.count, expected: CardDisplay.rawByteCount)
        }
        var output = Data(repeating: 0, count: 4)
        for offset in stride(from: 0, to: raw.count, by: currentBlockSize) {
            let end = min(raw.count, offset + currentBlockSize)
            output.append(encodeLevel3Block(Array(raw[offset ..< end])))
        }
        let decoded = try unwrapQuickLZ(output)
        guard decoded == Data(raw) else { throw PayloadError.invalidStoredHeader(block: -1) }
        return output
    }

    public static func build(from previewCodes: [UInt8]) throws -> BuiltPayload {
        let set = try buildPayloadSet(from: previewCodes)
        let validation = try validate(set.legacyCompressed)
        return BuiltPayload(data: set.legacyCompressed, validation: validation)
    }

    public static func buildPayloadSet(from previewCodes: [UInt8]) throws -> T3PayloadSet {
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
        let legacy = try quickLZStored(controllerRaw)
        _ = try validate(legacy)
        let current = try quickLZLevel3(controllerRaw)
        return T3PayloadSet(
            currentCompressed: current,
            legacyCompressed: legacy,
            controllerRaw: Data(controllerRaw)
        )
    }

    public static func selectTransferPayload(
        _ payloads: T3PayloadSet,
        firmwareVersion: UInt8?,
        blockPayloadSize: Int,
        verifiedFirmwareMinimum: UInt8 = 0x9D
    ) throws -> SelectedT3TransferPayload {
        guard blockPayloadSize > 0 else { throw TransferProtocolError.invalidBlockSize }
        guard let firmwareVersion, firmwareVersion >= verifiedFirmwareMinimum else {
            return SelectedT3TransferPayload(
                data: payloads.legacyCompressed,
                kind: .legacyCompressed,
                compressed: true,
                usesVerifiedWindows: false,
                paddingBytes: 0
            )
        }

        if let current = payloads.currentCompressed, let raw = payloads.controllerRaw {
            let compressedWireBytes = roundedUp(current.count, toMultipleOf: blockPayloadSize)
            let rawWireBytes = roundedUp(raw.count, toMultipleOf: blockPayloadSize)
            if compressedWireBytes < rawWireBytes {
                let padding = compressedWireBytes - current.count
                var padded = current
                if padding > 0 { padded.append(Data(repeating: 0, count: padding)) }
                return SelectedT3TransferPayload(
                    data: padded,
                    kind: .currentCompressed,
                    compressed: true,
                    usesVerifiedWindows: true,
                    paddingBytes: padding
                )
            }
            return SelectedT3TransferPayload(
                data: raw,
                kind: .controllerRaw,
                compressed: false,
                usesVerifiedWindows: true,
                paddingBytes: 0
            )
        }

        // 旧版本保存的最近记录只有 legacy payload。新版固件仍能解码它，但传输层必须
        // 使用新版耐久检查点，并与其他压缩流一样按协商块大小补齐。
        let wireBytes = roundedUp(payloads.legacyCompressed.count, toMultipleOf: blockPayloadSize)
        let padding = wireBytes - payloads.legacyCompressed.count
        var padded = payloads.legacyCompressed
        if padding > 0 { padded.append(Data(repeating: 0, count: padding)) }
        return SelectedT3TransferPayload(
            data: padded,
            kind: .legacyCompressed,
            compressed: true,
            usesVerifiedWindows: true,
            paddingBytes: padding
        )
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

    public static func inspectQuickLZ(_ payload: Data) throws -> QuickLZPayloadInfo {
        guard payload.count >= 4, payload.prefix(4).allSatisfy({ $0 == 0 }) else {
            throw PayloadError.missingZeroPrefix
        }
        var offset = 4
        var decodedBytes = 0
        var compressedBlocks = 0
        var storedBlocks = 0
        var levels = Set<Int>()
        while offset < payload.count {
            guard offset + 3 <= payload.count else {
                throw PayloadError.invalidStoredHeader(block: compressedBlocks + storedBlocks)
            }
            let header = payload[offset]
            let headerSize = header & 0x02 != 0 ? 9 : 3
            guard offset + headerSize <= payload.count else {
                throw PayloadError.invalidStoredHeader(block: compressedBlocks + storedBlocks)
            }
            let sizeBytes = headerSize == 9 ? 4 : 1
            let compressedSize = readLittleEndian(payload, offset: offset + 1, count: sizeBytes)
            let decodedOffset = headerSize == 9 ? offset + 5 : offset + 2
            let decodedSize = readLittleEndian(payload, offset: decodedOffset, count: sizeBytes)
            let level = Int((header >> 2) & 0x03)
            guard header & 0x40 != 0,
                  level == 1 || level == 3,
                  compressedSize >= headerSize,
                  decodedSize > 0, decodedSize <= currentBlockSize,
                  offset + compressedSize <= payload.count else {
                throw PayloadError.invalidStoredHeader(block: compressedBlocks + storedBlocks)
            }
            levels.insert(level)
            if header & 1 != 0 { compressedBlocks += 1 } else { storedBlocks += 1 }
            decodedBytes += decodedSize
            offset += compressedSize
        }
        guard offset == payload.count else {
            throw PayloadError.invalidPayloadSize(actual: offset, expected: payload.count)
        }
        return QuickLZPayloadInfo(
            payloadBytes: payload.count,
            decodedBytes: decodedBytes,
            blocks: compressedBlocks + storedBlocks,
            compressedBlocks: compressedBlocks,
            storedBlocks: storedBlocks,
            levels: levels
        )
    }

    public static func unwrapQuickLZ(_ payload: Data) throws -> Data {
        let info = try inspectQuickLZ(payload)
        var output = Data()
        output.reserveCapacity(info.decodedBytes)
        var offset = 4
        var blockIndex = 0
        while offset < payload.count {
            let header = payload[offset]
            let headerSize = header & 0x02 != 0 ? 9 : 3
            let sizeBytes = headerSize == 9 ? 4 : 1
            let compressedSize = readLittleEndian(payload, offset: offset + 1, count: sizeBytes)
            let decodedOffset = headerSize == 9 ? offset + 5 : offset + 2
            let decodedSize = readLittleEndian(payload, offset: decodedOffset, count: sizeBytes)
            let block = payload.subdata(in: offset ..< offset + compressedSize)
            if header & 1 == 0 {
                let decoded = block.dropFirst(headerSize)
                guard decoded.count == decodedSize else {
                    throw PayloadError.invalidStoredHeader(block: blockIndex)
                }
                output.append(contentsOf: decoded)
            } else if ((header >> 2) & 0x03) == 3 {
                output.append(try decodeLevel3Block(block, headerSize: headerSize, decodedSize: decodedSize))
            } else {
                throw PayloadError.invalidStoredHeader(block: blockIndex)
            }
            offset += compressedSize
            blockIndex += 1
        }
        guard output.count == info.decodedBytes else {
            throw PayloadError.invalidPayloadSize(actual: output.count, expected: info.decodedBytes)
        }
        return output
    }

    private static func encodeLevel3Block(_ source: [UInt8]) -> Data {
        precondition(!source.isEmpty && source.count <= currentBlockSize)
        var core = [UInt8](repeating: 0, count: source.count + 400)
        var hashOffsets = [Int](repeating: -1, count: level3HashValues * level3Pointers)
        var hashCounters = [Int](repeating: 0, count: level3HashValues)
        let lastByte = source.count - 1
        let lastMatchStart = lastByte - 10
        var sourceOffset = 0
        var controlWordOffset = 0
        var targetOffset = 4
        var controlWord: UInt32 = 0x8000_0000

        func flushControlWord() {
            writeLittleEndian(&core, offset: controlWordOffset, value: UInt64((controlWord >> 1) | 0x8000_0000), count: 4)
        }

        while sourceOffset <= lastMatchStart {
            if controlWord & 1 != 0 {
                flushControlWord()
                controlWordOffset = targetOffset
                targetOffset += 4
                controlWord = 0x8000_0000
            }

            let fetch = readLittleEndian(source, offset: sourceOffset, count: 3)
            let hash = level3Hash(fetch)
            let maximumMatchLength = min(258, source.count - 4 - sourceOffset)
            let hashBase = hash * level3Pointers
            let hashCount = hashCounters[hash]
            var previousOffset = -1
            var matchLength = 0
            for candidateIndex in 0 ..< min(hashCount, level3Pointers) {
                let candidateOffset = hashOffsets[hashBase + candidateIndex]
                let distance = sourceOffset - candidateOffset
                guard candidateOffset >= 0, distance >= 3, distance <= 131_071,
                      source[candidateOffset] == source[sourceOffset],
                      source[candidateOffset + 1] == source[sourceOffset + 1],
                      source[candidateOffset + 2] == source[sourceOffset + 2] else { continue }
                var candidateLength = 3
                while candidateLength < maximumMatchLength,
                      source[candidateOffset + candidateLength] == source[sourceOffset + candidateLength] {
                    candidateLength += 1
                }
                if candidateLength > matchLength {
                    matchLength = candidateLength
                    previousOffset = candidateOffset
                }
            }

            hashOffsets[hashBase + (hashCount & (level3Pointers - 1))] = sourceOffset
            hashCounters[hash] = (hashCount + 1) & 0xFFFF

            if matchLength >= 3 {
                let matchOffset = sourceOffset - previousOffset
                controlWord = (controlWord >> 1) | 0x8000_0000
                if matchLength > 1 {
                    for index in 1 ..< matchLength where sourceOffset + index <= lastMatchStart {
                        let innerOffset = sourceOffset + index
                        let innerHash = level3Hash(readLittleEndian(source, offset: innerOffset, count: 3))
                        let innerCount = hashCounters[innerHash]
                        hashOffsets[innerHash * level3Pointers + (innerCount & (level3Pointers - 1))] = innerOffset
                        hashCounters[innerHash] = (innerCount + 1) & 0xFFFF
                    }
                }
                sourceOffset += matchLength
                if matchLength == 3, matchOffset <= 63 {
                    core[targetOffset] = UInt8(matchOffset << 2)
                    targetOffset += 1
                } else if matchLength == 3, matchOffset <= 16_383 {
                    writeLittleEndian(&core, offset: targetOffset, value: UInt64((matchOffset << 2) | 1), count: 2)
                    targetOffset += 2
                } else if matchLength <= 18, matchOffset <= 1_023 {
                    let value = ((matchLength - 3) << 2) | (matchOffset << 6) | 2
                    writeLittleEndian(&core, offset: targetOffset, value: UInt64(value), count: 2)
                    targetOffset += 2
                } else if matchLength <= 33 {
                    let value = ((matchLength - 2) << 2) | (matchOffset << 7) | 3
                    writeLittleEndian(&core, offset: targetOffset, value: UInt64(value), count: 3)
                    targetOffset += 3
                } else {
                    let value = ((matchLength - 3) << 7) | (matchOffset << 15) | 3
                    writeLittleEndian(&core, offset: targetOffset, value: UInt64(value), count: 4)
                    targetOffset += 4
                }
            } else {
                core[targetOffset] = source[sourceOffset]
                targetOffset += 1
                sourceOffset += 1
                controlWord >>= 1
            }
        }

        while sourceOffset <= lastByte {
            if controlWord & 1 != 0 {
                flushControlWord()
                controlWordOffset = targetOffset
                targetOffset += 4
                controlWord = 0x8000_0000
            }
            core[targetOffset] = source[sourceOffset]
            targetOffset += 1
            sourceOffset += 1
            controlWord >>= 1
        }
        while controlWord & 1 == 0 { controlWord >>= 1 }
        flushControlWord()

        let coreLength = max(targetOffset, 9)
        let headerSize = source.count < 216 ? 3 : 9
        let compressedSize = headerSize + coreLength
        if compressedSize >= headerSize + source.count {
            var stored = [UInt8](repeating: 0, count: headerSize + source.count)
            stored[0] = 0x7C | (headerSize == 9 ? 0x02 : 0)
            writeQuickLZHeader(&stored, headerSize: headerSize, encodedSize: stored.count, decodedSize: source.count)
            stored.replaceSubrange(headerSize ..< stored.count, with: source)
            return Data(stored)
        }

        var compressed = [UInt8](repeating: 0, count: compressedSize)
        compressed[0] = 0x7D | (headerSize == 9 ? 0x02 : 0)
        writeQuickLZHeader(&compressed, headerSize: headerSize, encodedSize: compressedSize, decodedSize: source.count)
        compressed.replaceSubrange(headerSize ..< compressedSize, with: core[0 ..< coreLength])
        return Data(compressed)
    }

    private static func decodeLevel3Block(_ block: Data, headerSize: Int, decodedSize: Int) throws -> Data {
        let source = [UInt8](block)
        let bitLengths = [4, 0, 1, 0, 2, 0, 1, 0, 3, 0, 1, 0, 2, 0, 1, 0]
        var output = [UInt8](repeating: 0, count: decodedSize)
        var sourceOffset = headerSize
        var targetOffset = 0
        var controlWord: UInt32 = 1

        func require(_ count: Int) throws {
            guard sourceOffset + count <= source.count else {
                throw PayloadError.invalidStoredHeader(block: -1)
            }
        }

        while true {
            if controlWord == 1 {
                try require(4)
                controlWord = UInt32(readLittleEndian(source, offset: sourceOffset, count: 4))
                sourceOffset += 4
            }
            if controlWord & 1 != 0 {
                try require(4)
                let fetch = readLittleEndian(source, offset: sourceOffset, count: 4)
                controlWord >>= 1
                let matchOffset: Int
                let matchLength: Int
                if fetch & 3 == 0 {
                    matchOffset = (fetch & 0xFF) >> 2
                    matchLength = 3
                    sourceOffset += 1
                } else if fetch & 2 == 0 {
                    matchOffset = (fetch & 0xFFFF) >> 2
                    matchLength = 3
                    sourceOffset += 2
                } else if fetch & 1 == 0 {
                    matchOffset = (fetch & 0xFFFF) >> 6
                    matchLength = ((fetch >> 2) & 15) + 3
                    sourceOffset += 2
                } else if fetch & 127 != 3 {
                    matchOffset = (fetch >> 7) & 0x1_FFFF
                    matchLength = ((fetch >> 2) & 0x1F) + 2
                    sourceOffset += 3
                } else {
                    matchOffset = fetch >> 15
                    matchLength = ((fetch >> 7) & 0xFF) + 3
                    sourceOffset += 4
                }
                let previousOffset = targetOffset - matchOffset
                guard matchOffset >= 3, previousOffset >= 0, matchLength > 0,
                      matchLength <= decodedSize - targetOffset - 4 else {
                    throw PayloadError.invalidStoredHeader(block: -1)
                }
                for index in 0 ..< matchLength {
                    output[targetOffset] = output[previousOffset + index]
                    targetOffset += 1
                }
                continue
            }

            if targetOffset < decodedSize - 11 {
                let literalCount = bitLengths[Int(controlWord & 0x0F)]
                guard literalCount > 0 else { throw PayloadError.invalidStoredHeader(block: -1) }
                try require(literalCount)
                for index in 0 ..< literalCount { output[targetOffset + index] = source[sourceOffset + index] }
                sourceOffset += literalCount
                targetOffset += literalCount
                controlWord >>= UInt32(literalCount)
                continue
            }

            while targetOffset < decodedSize {
                if controlWord == 1 {
                    try require(4)
                    sourceOffset += 4
                    controlWord = 0x8000_0000
                }
                try require(1)
                output[targetOffset] = source[sourceOffset]
                targetOffset += 1
                sourceOffset += 1
                controlWord >>= 1
            }
            return Data(output)
        }
    }

    private static func writeQuickLZHeader(
        _ bytes: inout [UInt8], headerSize: Int, encodedSize: Int, decodedSize: Int
    ) {
        if headerSize == 3 {
            bytes[1] = UInt8(encodedSize)
            bytes[2] = UInt8(decodedSize)
        } else {
            writeLittleEndian(&bytes, offset: 1, value: UInt64(encodedSize), count: 4)
            writeLittleEndian(&bytes, offset: 5, value: UInt64(decodedSize), count: 4)
        }
    }

    private static func level3Hash(_ fetch: Int) -> Int {
        ((fetch >> 12) ^ fetch) & (level3HashValues - 1)
    }

    private static func roundedUp(_ value: Int, toMultipleOf divisor: Int) -> Int {
        ((value + divisor - 1) / divisor) * divisor
    }

    private static func readLittleEndian(_ bytes: Data, offset: Int, count: Int) -> Int {
        readLittleEndian([UInt8](bytes), offset: offset, count: count)
    }

    private static func readLittleEndian(_ bytes: [UInt8], offset: Int, count: Int) -> Int {
        var value = 0
        for index in 0 ..< count where offset + index < bytes.count {
            value |= Int(bytes[offset + index]) << (index * 8)
        }
        return value
    }

    private static func writeLittleEndian(
        _ bytes: inout [UInt8], offset: Int, value: UInt64, count: Int
    ) {
        for index in 0 ..< count {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
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
