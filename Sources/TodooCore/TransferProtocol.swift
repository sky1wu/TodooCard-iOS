import Foundation

public enum TransferCommand {
    public static let requestBlockSize: UInt8 = 1
    public static let requestPayloadLength: UInt8 = 2
    public static let requestStart: UInt8 = 3
    public static let dataAcknowledgement: UInt8 = 5
}

public enum TransferStatus {
    public static let success: UInt8 = 0
    public static let malformedOrOutOfOrder: UInt8 = 1
    public static let transferEnd: UInt8 = 8
    public static let flashWriteFailure: UInt8 = 9
    public static let flashReadbackFailure: UInt8 = 10
}

public struct ImageAckDiagnostics: Equatable, Sendable {
    public let session: UInt8
    public let flags: UInt8
    public let generatedCount: UInt16
    public let notifyAttemptCount: UInt16
    public let notifyAcceptedCount: UInt16
    public let notifyRejectedCount: UInt16
    public let requestedBlock: UInt32
    public let previousBlockStatus: UInt8
    public let lastNotifyResult: UInt8
    public let lastReceivedBlock: UInt16

    public var isActive: Bool { flags & 0x01 != 0 }
    public var notificationPending: Bool { flags & 0x02 != 0 }
    public var blockReceived: Bool { flags & 0x04 != 0 }
    public var lastNotificationAccepted: Bool { flags & 0x08 != 0 }

    public var logDescription: String {
        String(
            format: "session=%u active=%@ pending=%@ blockReceived=%@ lastAccepted=%@ "
                + "generated=%u attempts=%u accepted=%u rejected=%u requestedBlock=%u "
                + "previousStatus=0x%02X lastNotifyResult=0x%02X lastReceivedBlock=%u",
            session,
            isActive ? "yes" : "no",
            notificationPending ? "yes" : "no",
            blockReceived ? "yes" : "no",
            lastNotificationAccepted ? "yes" : "no",
            generatedCount,
            notifyAttemptCount,
            notifyAcceptedCount,
            notifyRejectedCount,
            requestedBlock,
            previousBlockStatus,
            lastNotifyResult,
            lastReceivedBlock
        )
    }
}

public func parseImageAckDiagnostics(_ data: Data) -> ImageAckDiagnostics? {
    guard data.count >= 20, data[0] == 0x27, data[1] == 0x01 else { return nil }
    func uint16(_ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }
    let requested = UInt32(data[12])
        | UInt32(data[13]) << 8
        | UInt32(data[14]) << 16
        | UInt32(data[15]) << 24
    return ImageAckDiagnostics(
        session: data[2],
        flags: data[3],
        generatedCount: uint16(4),
        notifyAttemptCount: uint16(6),
        notifyAcceptedCount: uint16(8),
        notifyRejectedCount: uint16(10),
        requestedBlock: requested,
        previousBlockStatus: data[16],
        lastNotifyResult: data[17],
        lastReceivedBlock: uint16(18)
    )
}

public struct ControlMessage: Equatable, Sendable {
    public let command: UInt8
    public let status: UInt8?
    public let advertisedBlockSize: Int?
    public let blockPayloadSize: Int?
    public let index: UInt32?
    public let bytes: Data
}

public struct DataBlock: Equatable, Sendable {
    public let packet: Data
    public let index: UInt32
    public let offset: Int
    public let length: Int
    public let written: Int
    public let percent: Int
    public let isLast: Bool
}

public enum TransferProtocolError: Error, LocalizedError, Equatable {
    case invalidPayloadLength
    case emptyControlMessage
    case invalidBlockSize
    case invalidBlockIndex

    public var errorDescription: String? {
        switch self {
        case .invalidPayloadLength: return "Payload 长度必须能用 UInt32 表示。"
        case .emptyControlMessage: return "控制通知为空。"
        case .invalidBlockSize: return "数据块大小必须大于零。"
        case .invalidBlockIndex: return "数据块索引超出范围。"
        }
    }
}

public func encodePayloadLengthRequest(
    _ payloadLength: Int,
    compressed: Bool = true,
    allowDeviceButton: Bool = false
) throws -> Data {
    guard payloadLength > 0, payloadLength <= Int(UInt32.max) else {
        throw TransferProtocolError.invalidPayloadLength
    }
    let length = UInt32(payloadLength)
    var flags: UInt8 = compressed ? 0x01 : 0x03
    if allowDeviceButton { flags |= 0x10 }
    return Data([
        TransferCommand.requestPayloadLength,
        UInt8(truncatingIfNeeded: length),
        UInt8(truncatingIfNeeded: length >> 8),
        UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 24),
        flags,
    ])
}

public func parseControlMessage(_ data: Data) throws -> ControlMessage {
    guard let command = data.first else { throw TransferProtocolError.emptyControlMessage }
    var status: UInt8?
    var advertised: Int?
    var payloadSize: Int?
    var index: UInt32?

    switch command {
    case TransferCommand.requestBlockSize:
        if data.count >= 2 {
            advertised = Int(data[1])
            payloadSize = Int(data[1]) - 4
        }
        if data.count >= 3 { status = data[2] }
    case TransferCommand.requestPayloadLength:
        if data.count >= 2 { status = data[1] }
    case TransferCommand.dataAcknowledgement:
        if data.count >= 2 { status = data[1] }
        if data.count >= 6 {
            index = UInt32(data[2])
                | (UInt32(data[3]) << 8)
                | (UInt32(data[4]) << 16)
                | (UInt32(data[5]) << 24)
        }
    default:
        break
    }
    return ControlMessage(
        command: command,
        status: status,
        advertisedBlockSize: advertised,
        blockPayloadSize: payloadSize,
        index: index,
        bytes: data
    )
}

public func makeDataBlock(payload: Data, index: UInt32, blockPayloadSize: Int) throws -> DataBlock? {
    guard blockPayloadSize > 0 else { throw TransferProtocolError.invalidBlockSize }
    let offset64 = UInt64(index) * UInt64(blockPayloadSize)
    guard offset64 <= UInt64(Int.max) else { throw TransferProtocolError.invalidBlockIndex }
    let offset = Int(offset64)
    guard offset < payload.count else { return nil }
    let length = min(blockPayloadSize, payload.count - offset)
    var packet = Data([
        UInt8(truncatingIfNeeded: index),
        UInt8(truncatingIfNeeded: index >> 8),
        UInt8(truncatingIfNeeded: index >> 16),
        UInt8(truncatingIfNeeded: index >> 24),
    ])
    packet.append(payload.subdata(in: offset ..< offset + length))
    let written = offset + length
    return DataBlock(
        packet: packet,
        index: index,
        offset: offset,
        length: length,
        written: written,
        percent: Int(Double(written) / Double(payload.count) * 100),
        isLast: written >= payload.count
    )
}
