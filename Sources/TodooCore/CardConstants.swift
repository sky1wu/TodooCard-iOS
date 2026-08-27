import Foundation

public enum CardPhysicalSize {
    public static let widthMillimeters = 62.0
    public static let heightMillimeters = 97.5
    public static let cornerRadiusMillimeters = 5.5
    public static let aspectRatio = widthMillimeters / heightMillimeters
    public static let cornerRadiusToWidthRatio = cornerRadiusMillimeters / widthMillimeters
}

public enum CardDisplay {
    public static let width = 528
    public static let height = 792
    public static let aspectRatio = Double(width) / Double(height)
    public static let pixelCount = width * height
    public static let rawByteCount = pixelCount / 2
}

public enum TodooBluetoothConstants {
    public static let manufacturerID: UInt16 = 0x5053
    public static let screenType: UInt16 = 0x134C
    public static let secureFirmwareMinimum: UInt8 = 0x8C

    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
    public static let transferProfiles = [
        TransferProfile(service: "FEF0", control: "FEF1", data: "FEF2"),
        TransferProfile(service: "FDF0", control: "FDF1", data: "FDF2"),
    ]
}

public struct TransferProfile: Equatable, Sendable {
    public let service: String
    public let control: String
    public let data: String

    public init(service: String, control: String, data: String) {
        self.service = service
        self.control = control
        self.data = data
    }

    public var label: String { "\(service) / \(control) / \(data)" }
}

public struct TodooAdvertisement: Equatable, Sendable {
    public let manufacturerID: UInt16
    public let screenType: UInt16
    public let capabilityFlags: UInt8
    public let firmwareVersion: UInt8
    public let requiresEncryptedGATT: Bool
    public let pairingWindowOpen: Bool
    public let otaRecoveryMode: Bool
    public let isCompatible: Bool
    public let rawHex: String
}

public enum AdvertisementError: Error, LocalizedError, Equatable {
    case tooShort(actual: Int)
    case wrongManufacturer(actual: UInt16)

    public var errorDescription: String? {
        switch self {
        case let .tooShort(actual):
            return "厂商广播只有 \(actual) 字节，至少需要 7 字节。"
        case let .wrongManufacturer(actual):
            return String(format: "厂商标识为 0x%04X，不是 TodooCard。", actual)
        }
    }
}

/// CoreBluetooth 的 manufacturer data 包含开头两字节的 Company Identifier。
public func parseTodooAdvertisement(_ data: Data) throws -> TodooAdvertisement {
    guard data.count >= 7 else { throw AdvertisementError.tooShort(actual: data.count) }
    let manufacturer = UInt16(data[0]) | (UInt16(data[1]) << 8)
    guard manufacturer == TodooBluetoothConstants.manufacturerID else {
        throw AdvertisementError.wrongManufacturer(actual: manufacturer)
    }

    let screen = UInt16(data[2]) | (UInt16(data[6]) << 8)
    let flags = data[3]
    let firmware = data[4]
    let requiresEncryption = screen == TodooBluetoothConstants.screenType
        && firmware >= TodooBluetoothConstants.secureFirmwareMinimum
        && flags & 0x01 != 0

    return TodooAdvertisement(
        manufacturerID: manufacturer,
        screenType: screen,
        capabilityFlags: flags,
        firmwareVersion: firmware,
        requiresEncryptedGATT: requiresEncryption,
        pairingWindowOpen: requiresEncryption && flags & 0x02 != 0,
        otaRecoveryMode: flags & 0x08 != 0,
        isCompatible: screen == TodooBluetoothConstants.screenType,
        rawHex: data.hexString
    )
}

public extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
