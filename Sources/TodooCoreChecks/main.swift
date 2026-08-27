import CryptoKit
import Foundation
import TodooCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case let .failed(message): return message }
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

func runChecks() throws {
    try check(CardPhysicalSize.widthMillimeters == 62, "physical card width")
    try check(CardPhysicalSize.heightMillimeters == 97.5, "physical card height")
    try check(CardPhysicalSize.cornerRadiusMillimeters == 5.5, "physical card corner radius")
    try check(abs(CardPhysicalSize.aspectRatio - 124.0 / 195.0) < 0.000_001, "physical card aspect ratio")
    try check(
        abs(CardPhysicalSize.cornerRadiusToWidthRatio - 11.0 / 124.0) < 0.000_001,
        "physical card corner radius ratio"
    )
    try check(abs(CardDisplay.aspectRatio - 2.0 / 3.0) < 0.000_001, "display aspect ratio")

    let advertisement = try parseTodooAdvertisement(Data([0x53, 0x50, 0x4C, 0x03, 0x8C, 0x00, 0x13]))
    try check(advertisement.manufacturerID == 0x5053, "manufacturer parser")
    try check(advertisement.screenType == 0x134C, "screen type parser")
    try check(advertisement.isCompatible && advertisement.requiresEncryptedGATT, "security flags")
    try check(advertisement.pairingWindowOpen, "pairing window flag")

    let layout = try computeCoverLayout(
        sourceWidth: 1_200,
        sourceHeight: 800,
        rotation: 90,
        focusX: 25,
        focusY: 75,
        zoom: 1.5
    )
    try check(abs(layout.rotatedDrawWidth - 792) < 0.001, "rotated cover width")
    try check(abs(layout.cropX - 66) < 0.001, "horizontal crop")
    try check(abs(layout.cropY - 297) < 0.001, "vertical crop")

    let transparent = try ditherRGBA(
        [255, 0, 0, 0, 250, 10, 5, 255],
        width: 2,
        height: 1,
        algorithm: .none
    )
    try check(transparent == [1, 3], "transparent pixels composite onto white")

    let unadjustedMidtone = try ditherRGBA(
        [64, 64, 64, 255],
        width: 1,
        height: 1,
        algorithm: .none
    )
    let brightenedMidtone = try ditherRGBA(
        [64, 64, 64, 255],
        width: 1,
        height: 1,
        algorithm: .none,
        brightness: 1
    )
    try check(unadjustedMidtone == [0], "unadjusted midtone quantization")
    try check(brightenedMidtone == [1], "brightness compensation lifts midtones")

    let packed = try T3PayloadBuilder.packColorCodes([0, 1, 2, 3])
    try check(packed == [0x01, 0x23], "nibble packing")
    try check(T3PayloadBuilder.rotate180(packed, width: 2, height: 2) == [0x32, 0x10], "180° rotation")
    try check(T3PayloadBuilder.flipHorizontal(packed, width: 2, height: 2) == [0x10, 0x32], "horizontal flip")

    let result = try T3PayloadBuilder.build(from: makeReferenceCodes())
    try check(result.validation.blocks == 3_267, "QuickLZ block count")
    try check(result.validation.decodedBytes == 209_088, "decoded byte count")
    try check(result.validation.payloadBytes == 218_893, "payload byte count")
    let digest = SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
    try check(
        digest == "52c109f0d80d7205c62f4619f2e0621e7df0f3d517507f681f4f05d9e567834d",
        "reference payload SHA-256"
    )

    let lengthRequest = try encodePayloadLengthRequest(0x01020304)
    try check(lengthRequest == Data([2, 4, 3, 2, 1, 1]), "payload length request")
    let blockSize = try parseControlMessage(Data([1, 184, 0]))
    try check(blockSize.blockPayloadSize == 180 && blockSize.status == 0, "block size reply")
    let ack = try parseControlMessage(Data([5, 0, 0x78, 0x56, 0x34, 0x12]))
    try check(ack.index == 0x12345678, "little-endian ACK index")

    let payload = Data((0 ..< 10).map(UInt8.init))
    guard let block = try makeDataBlock(payload: payload, index: 1, blockPayloadSize: 4) else {
        throw CheckFailure.failed("data block creation")
    }
    try check(block.packet == Data([1, 0, 0, 0, 4, 5, 6, 7]), "data block prefix")
    try check(block.percent == 80 && !block.isLast, "data block progress")
    let missingBlock = try makeDataBlock(payload: payload, index: 3, blockPayloadSize: 4)
    try check(missingBlock == nil, "out-of-range block")
}

private func makeReferenceCodes() -> [UInt8] {
    let width = CardDisplay.width
    let height = CardDisplay.height
    var codes = [UInt8](repeating: 1, count: width * height)

    func fill(_ x: Int, _ y: Int, _ rectWidth: Int, _ rectHeight: Int, _ code: UInt8) {
        let left = max(0, x)
        let top = max(0, y)
        let right = min(width, x + rectWidth)
        let bottom = min(height, y + rectHeight)
        guard left < right, top < bottom else { return }
        for row in top ..< bottom {
            codes.replaceSubrange(
                (row * width + left) ..< (row * width + right),
                with: repeatElement(code, count: right - left)
            )
        }
    }

    let glyphs: [Character: [String]] = [
        "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    ]

    func draw(_ text: String, _ x: Int, _ y: Int, _ scale: Int, _ code: UInt8) {
        var cursor = x
        for character in text {
            guard let glyph = glyphs[character] else {
                cursor += 6 * scale
                continue
            }
            for (glyphY, row) in glyph.enumerated() {
                for (glyphX, pixel) in row.enumerated() where pixel == "1" {
                    fill(cursor + glyphX * scale, y + glyphY * scale, scale, scale, code)
                }
            }
            cursor += 6 * scale
        }
    }

    let headerHeight = max(28, Int((Double(height) * 0.16).rounded()))
    let footerHeight = max(28, Int((Double(height) * 0.16).rounded()))
    fill(0, 0, width, headerHeight, 3)
    fill(0, height - footerHeight, width, footerHeight, 5)
    let contentTop = headerHeight + Int((Double(height) * 0.045).rounded())
    let contentBottom = height - footerHeight - Int((Double(height) * 0.045).rounded())
    let contentHeight = contentBottom - contentTop
    for (index, code) in [UInt8(0), 1, 2, 3, 5, 6].enumerated() {
        let left = index * width / 6
        let right = (index + 1) * width / 6
        fill(left, contentTop, right - left, contentHeight, code)
    }
    let border = max(3, Int((Double(width) * 0.012).rounded()))
    fill(0, contentTop - border, width, border, 0)
    fill(0, contentBottom, width, border, 0)
    fill(0, contentTop, border, contentHeight, 0)
    fill(width - border, contentTop, border, contentHeight, 0)

    let topScale = max(2, min(width / 25, headerHeight / 9))
    draw("TOP", (width - 17 * topScale) / 2, topScale, topScale, 1)
    let bottomScale = max(2, min(width / 43, footerHeight / 9))
    draw("BOTTOM", (width - 35 * bottomScale) / 2, height - footerHeight + bottomScale, bottomScale, 1)
    return codes
}

do {
    try runChecks()
    print("TodooCoreChecks: all checks passed")
} catch {
    fputs("TodooCoreChecks failed: \(error)\n", stderr)
    exit(1)
}
