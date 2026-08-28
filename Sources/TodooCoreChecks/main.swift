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
    try check(CardPhysicalSize.thicknessMillimeters == 3, "physical card thickness")
    try check(CardPhysicalSize.cornerRadiusMillimeters == 5.5, "physical card corner radius")
    try check(CardPhysicalSize.displaySideInsetMillimeters == 5, "physical display side inset")
    try check(CardPhysicalSize.displayTopInsetMillimeters == 5.5, "physical display top inset")
    try check(abs(CardPhysicalSize.aspectRatio - 124.0 / 195.0) < 0.000_001, "physical card aspect ratio")
    try check(
        abs(CardPhysicalSize.thicknessToWidthRatio - 3.0 / 62.0) < 0.000_001,
        "physical card thickness ratio"
    )
    try check(
        abs(CardPhysicalSize.cornerRadiusToWidthRatio - 11.0 / 124.0) < 0.000_001,
        "physical card corner radius ratio"
    )
    try check(
        abs(CardPhysicalSize.displaySideInsetToWidthRatio - 5.0 / 62.0) < 0.000_001,
        "physical display side inset ratio"
    )
    try check(
        abs(CardPhysicalSize.displayTopInsetToHeightRatio - 11.0 / 195.0) < 0.000_001,
        "physical display top inset ratio"
    )
    try check(abs(CardDisplay.aspectRatio - 2.0 / 3.0) < 0.000_001, "display aspect ratio")

    let advertisement = try parseTodooAdvertisement(Data([0x53, 0x50, 0x4C, 0x13, 0x8C, 0x00, 0x13]))
    try check(advertisement.manufacturerID == 0x5053, "manufacturer parser")
    try check(advertisement.screenType == 0x134C, "screen type parser")
    try check(advertisement.isCompatible && advertisement.requiresEncryptedGATT, "security flags")
    try check(advertisement.pairingWindowOpen, "pairing window flag")
    try check(advertisement.turboLink, "turbo link flag")

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

    let level3Raw = (0 ..< CardDisplay.rawByteCount).map {
        UInt8(truncatingIfNeeded: $0 * 17 + ($0 / 97) * 29)
    }
    let level3Payload = try T3PayloadBuilder.quickLZLevel3(level3Raw)
    let level3Info = try T3PayloadBuilder.inspectQuickLZ(level3Payload)
    try check(level3Info.decodedBytes == CardDisplay.rawByteCount, "level-3 decoded byte count")
    try check(level3Info.blocks == 103 && level3Info.levels == [3], "level-3 block layout")
    try check(level3Payload.count == 44_304, "level-3 deterministic size")
    let unwrappedLevel3 = try T3PayloadBuilder.unwrapQuickLZ(level3Payload)
    try check(unwrappedLevel3 == Data(level3Raw), "level-3 round trip")
    let level3Digest = SHA256.hash(data: level3Payload).map { String(format: "%02x", $0) }.joined()
    try check(
        level3Digest == "31761fbb26551a0c498ca37522c6aa490e7ca558b47fb4d56af777af9de793cc",
        "level-3 reference SHA-256"
    )

    let payloadSet = T3PayloadSet(
        currentCompressed: Data(repeating: 1, count: 901),
        legacyCompressed: Data(repeating: 2, count: 2_001),
        controllerRaw: Data(repeating: 3, count: 1_200)
    )
    let currentSelection = try T3PayloadBuilder.selectTransferPayload(
        payloadSet,
        firmwareVersion: 0xA6,
        blockPayloadSize: 240
    )
    try check(
        currentSelection.kind == .currentCompressed
            && currentSelection.data.count == 960
            && currentSelection.paddingBytes == 59
            && currentSelection.usesVerifiedWindows,
        "current firmware payload selection"
    )
    let legacySelection = try T3PayloadBuilder.selectTransferPayload(
        payloadSet,
        firmwareVersion: 0x95,
        blockPayloadSize: 240
    )
    try check(
        legacySelection.kind == .legacyCompressed && !legacySelection.usesVerifiedWindows,
        "legacy firmware payload selection"
    )
    let migratedSelection = try T3PayloadBuilder.selectTransferPayload(
        .legacyOnly(Data(repeating: 4, count: 2_001)),
        firmwareVersion: 0xA6,
        blockPayloadSize: 240
    )
    try check(
        migratedSelection.kind == .legacyCompressed
            && migratedSelection.data.count == 2_160
            && migratedSelection.paddingBytes == 159
            && migratedSelection.usesVerifiedWindows,
        "migrated history payload padding"
    )

    let lengthRequest = try encodePayloadLengthRequest(0x01020304)
    try check(lengthRequest == Data([2, 4, 3, 2, 1, 1]), "payload length request")
    let blockSize = try parseControlMessage(Data([1, 184, 0]))
    try check(blockSize.blockPayloadSize == 180 && blockSize.status == 0, "block size reply")
    let ack = try parseControlMessage(Data([5, 0, 0x78, 0x56, 0x34, 0x12]))
    try check(ack.index == 0x12345678, "little-endian ACK index")
    let diagnostics = parseImageAckDiagnostics(Data([
        0x27, 0x01, 0x03, 0x0D, 2, 0, 4, 0, 3, 0, 1, 0,
        0xE0, 0x02, 0, 0, 1, 7, 0xDF, 0x02,
    ]))
    try check(
        diagnostics?.session == 3
            && diagnostics?.requestedBlock == 736
            && diagnostics?.lastReceivedBlock == 735
            && diagnostics?.blockReceived == true,
        "image ACK diagnostics parser"
    )

    let payload = Data((0 ..< 10).map(UInt8.init))
    guard let block = try makeDataBlock(payload: payload, index: 1, blockPayloadSize: 4) else {
        throw CheckFailure.failed("data block creation")
    }
    try check(block.packet == Data([1, 0, 0, 0, 4, 5, 6, 7]), "data block prefix")
    try check(block.percent == 80 && !block.isLast, "data block progress")
    guard let finalBlock = try makeDataBlock(payload: payload, index: 2, blockPayloadSize: 4) else {
        throw CheckFailure.failed("final data block creation")
    }
    try check(
        finalBlock.packet == Data([2, 0, 0, 0, 8, 9])
            && finalBlock.written == 10
            && finalBlock.isLast,
        "final block probe packet"
    )
    let missingBlock = try makeDataBlock(payload: payload, index: 3, blockPayloadSize: 4)
    try check(missingBlock == nil, "out-of-range block")

    try runHealthChecks()
}

private func runHealthChecks() throws {
    let overachieved = ActivityRingMetric(value: 640, goal: 600)
    try check(abs(overachieved.fraction - 1) < 0.000_001, "activity ring stops at one turn")
    try check(overachieved.percent == 107, "activity ring percent")
    try check(overachieved.isComplete, "activity ring completion")
    let goalless = ActivityRingMetric(value: 120, goal: 0)
    try check(goalless.fraction == 0 && goalless.percent == 0, "activity ring without a goal")
    try check(!ActivityRingMetric(value: .nan, goal: 600).value.isNaN, "activity ring rejects NaN")

    // 7 小时睡眠，深度 1 小时 15 分、核心 4 小时、REM 1 小时 45 分、清醒 15 分、醒来 2 次。
    let stagedNight = SleepStageTotals(deep: 4_500, core: 14_400, rem: 6_300, awake: 900)
    try check(stagedNight.hasStageDetail, "staged night has stage detail")
    try check(abs(stagedNight.asleep - 25_200) < 0.001, "staged night asleep total")
    try check(abs(stagedNight.inBed - 26_100) < 0.001, "staged night in-bed total")
    let stagedScore = SleepScoring.score(totals: stagedNight, awakenings: 2)
    try check(stagedScore.usesStageDetail, "staged score uses stages")
    try check(stagedScore.value == 90, "staged sleep score")
    try check(stagedScore.grade == .excellent, "staged sleep grade")

    // 只有 iPhone 记录时拿不到阶段，评分只看时长和连续性。
    let flatNight = SleepStageTotals(unspecified: 21_600)
    try check(!flatNight.hasStageDetail, "flat night has no stage detail")
    let flatScore = SleepScoring.score(totals: flatNight, awakenings: 0)
    try check(!flatScore.usesStageDetail, "flat score skips stages")
    try check(flatScore.value == 81 && flatScore.grade == .good, "flat sleep score")

    let oversleep = SleepScoring.score(totals: SleepStageTotals(unspecified: 39_600), awakenings: 0)
    try check(oversleep.value == 93, "oversleep penalty")
    let brokenNight = SleepScoring.score(
        totals: SleepStageTotals(unspecified: 14_400, awake: 5_400),
        awakenings: 7
    )
    try check(brokenNight.value == 38 && brokenNight.grade == .poor, "broken night score")
    let empty = SleepScoring.score(totals: SleepStageTotals(), awakenings: 0)
    try check(empty.value == 0 && empty.grade == .poor, "no sleep at all")

    try check(SleepScoring.grade(for: 85) == .excellent, "grade boundary 85")
    try check(SleepScoring.grade(for: 84) == .good, "grade boundary 84")
    try check(SleepScoring.grade(for: 70) == .good, "grade boundary 70")
    try check(SleepScoring.grade(for: 69) == .fair, "grade boundary 69")
    try check(SleepScoring.grade(for: 55) == .fair, "grade boundary 55")
    try check(SleepScoring.grade(for: 54) == .poor, "grade boundary 54")

    try check(formatSleepDuration(27_120) == "7 小时 32 分", "sleep duration with minutes")
    try check(formatSleepDuration(7_200) == "2 小时", "whole-hour sleep duration")
    try check(formatSleepDuration(2_700) == "45 分", "sub-hour sleep duration")
    try check(formatSleepDuration(-1) == "0 分", "negative sleep duration")
    try check(formatCompactDuration(4_500) == "1时15分", "compact duration")
    try check(formatCompactDuration(900) == "15分", "compact sub-hour duration")
    try check(formatGroupedNumber(12_486) == "12,486", "grouped thousands")
    try check(formatGroupedNumber(1_000_000) == "1,000,000", "grouped millions")
    try check(formatGroupedNumber(486) == "486", "ungrouped hundreds")
    try check(formatGroupedNumber(0) == "0", "grouped zero")
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
