import Combine
import CoreBluetooth
import Foundation
#if canImport(TodooCore)
import TodooCore
#endif

struct DiscoveredCard: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let firmwareVersion: UInt8
    let pairingWindowOpen: Bool
    let rawAdvertisement: String
}

@MainActor
final class TodooBluetoothManager: NSObject, ObservableObject {
    @Published private(set) var devices: [DiscoveredCard] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isSending = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "未连接"
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var logs: [String] = []
    @Published var errorMessage: String?

    private enum Phase {
        case idle
        case waitingBlockSize
        case waitingPayloadLength
        case waitingStart
        case sendingData
        case waitingFinal
    }

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var advertisements: [UUID: TodooAdvertisement] = [:]
    private var activePeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var dataCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var selectedProfile: TransferProfile?
    private var pendingPayload: Data?
    private var phase = Phase.idle

    private var batteryReadComplete = false
    private var transferCharacteristicsReady = false
    private var controlNotificationsReady = false
    private var handshakeScheduled = false

    private var blockPayloadSize = 0
    private var totalBlocks = 0
    private var nextBlockIndex = 0
    private var highestSentExclusive = 0
    private var highestAcknowledgedIndex = 0
    private var repeatedAcknowledgementCount = 0
    private var checkpointTimeouts = 0
    private var dataWrites = 0
    private var retransmittedBlocks = 0

    private var scanTask: Task<Void, Never>?
    private var windowTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var transferID = UUID()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var primaryButtonTitle: String {
        if isSending { return "正在发送 \(Int(progress * 100))%" }
        if isConnected { return "发送到 \(connectedDeviceName ?? "TodooCard")" }
        return "连接并发送"
    }

    func beginDiscovery() {
        errorMessage = nil
        guard central.state == .poweredOn else {
            fail("请先在系统设置中打开蓝牙，并允许 TodooCard 使用蓝牙。")
            return
        }
        devices = []
        peripherals = [:]
        advertisements = [:]
        isScanning = true
        statusText = "正在查找 TodooCard…"
        appendLog("开始扫描厂商 0x5053、屏幕 0x134C。")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.devices.isEmpty {
                self.statusText = "没有找到兼容设备"
                self.appendLog("扫描结束，未发现兼容广播。")
            } else {
                self.statusText = "请选择设备"
            }
        }
    }

    func stopDiscovery() {
        central.stopScan()
        scanTask?.cancel()
        isScanning = false
    }

    func connectAndSend(deviceID: UUID, payload: Data) {
        guard let peripheral = peripherals[deviceID], let advertisement = advertisements[deviceID] else {
            fail("选中的设备已离开扫描范围，请重新扫描。")
            return
        }
        guard !advertisement.pairingWindowOpen else {
            fail("设备广播显示 pairing=open。请先在系统蓝牙设置中完成绑定，等待配对窗口关闭后再试。")
            return
        }
        stopDiscovery()
        pendingPayload = payload
        errorMessage = nil

        if peripheral.state == .connected, activePeripheral?.identifier == peripheral.identifier {
            startTransferIfReady()
            return
        }

        resetConnectionDiscovery()
        activePeripheral = peripheral
        peripheral.delegate = self
        statusText = "正在连接 \(peripheral.name ?? "TodooCard")…"
        appendLog("连接 -> \(peripheral.identifier.uuidString)")
        central.connect(peripheral, options: nil)
    }

    func send(_ payload: Data) {
        guard isConnected, activePeripheral?.state == .connected else {
            fail("设备连接已断开，请重新连接。")
            return
        }
        pendingPayload = payload
        startTransferIfReady()
    }

    func disconnect() {
        windowTask?.cancel()
        deadlineTask?.cancel()
        if let activePeripheral {
            central.cancelPeripheralConnection(activePeripheral)
        }
        clearConnection()
        statusText = "已断开连接"
    }

    private func resetConnectionDiscovery() {
        controlCharacteristic = nil
        dataCharacteristic = nil
        batteryCharacteristic = nil
        selectedProfile = nil
        batteryReadComplete = false
        transferCharacteristicsReady = false
        controlNotificationsReady = false
        handshakeScheduled = false
        batteryLevel = nil
        phase = .idle
    }

    private func clearConnection() {
        resetConnectionDiscovery()
        activePeripheral = nil
        isConnected = false
        isSending = false
        connectedDeviceName = nil
        pendingPayload = nil
    }

    private func startTransferIfReady() {
        guard pendingPayload != nil else { return }
        guard batteryReadComplete, transferCharacteristicsReady, controlNotificationsReady else {
            statusText = "正在验证安全连接…"
            return
        }
        guard !isSending, !handshakeScheduled else { return }
        handshakeScheduled = true
        statusText = "正在准备传输…"
        appendLog("电量读取和控制通知均已就绪；等待 400 ms 稳定通知链路。")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.handshakeScheduled = false
            self.beginHandshake()
        }
    }

    private func beginHandshake() {
        guard let payload = pendingPayload, !payload.isEmpty else {
            fail("不能发送空 Payload。")
            return
        }
        transferID = UUID()
        isSending = true
        progress = 0
        phase = .waitingBlockSize
        blockPayloadSize = 0
        totalBlocks = 0
        nextBlockIndex = 0
        highestSentExclusive = 0
        highestAcknowledgedIndex = 0
        repeatedAcknowledgementCount = 0
        checkpointTimeouts = 0
        dataWrites = 0
        retransmittedBlocks = 0
        statusText = "正在协商数据块…"
        sendControl(
            Data([TransferCommand.requestBlockSize]),
            timeoutMessage: "等待设备回复块大小超时。"
        )
    }

    private func sendControl(_ data: Data, timeoutMessage: String) {
        guard let peripheral = activePeripheral, let characteristic = controlCharacteristic else {
            fail("控制特征尚未就绪。")
            return
        }
        if characteristic.properties.contains(.write) {
            appendLog("控制 -> \(data.hexString) (withResponse)")
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            if characteristic.properties.contains(.writeWithoutResponse) {
                armControlFallback(data, timeoutMessage: timeoutMessage)
            } else {
                armDeadline(seconds: 5, message: timeoutMessage)
            }
        } else if characteristic.properties.contains(.writeWithoutResponse) {
            appendLog("控制 -> \(data.hexString) (withoutResponse)")
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            armDeadline(seconds: 5, message: timeoutMessage)
        } else {
            fail("控制特征不支持写入。")
        }
    }

    private func armControlFallback(_ data: Data, timeoutMessage: String) {
        let identifier = transferID
        let expectedPhase = phase
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.transferID == identifier,
                  self.isSending, self.phase == expectedPhase,
                  let peripheral = self.activePeripheral,
                  let characteristic = self.controlCharacteristic else { return }
            self.appendLog("控制通知 600 ms 未到，改用 withoutResponse 重发。")
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            self.armDeadline(seconds: 5, message: timeoutMessage)
        }
    }

    private func handleControl(_ data: Data) {
        let message: ControlMessage
        do {
            message = try parseControlMessage(data)
        } catch {
            appendLog("忽略无法解析的控制通知：\(error.localizedDescription)")
            return
        }
        appendLog("控制 <- \(data.hexString)")

        if message.command == TransferCommand.dataAcknowledgement,
           message.status == TransferStatus.transferEnd {
            completeTransfer(finalAck: data.hexString)
            return
        }

        switch phase {
        case .waitingBlockSize where message.command == TransferCommand.requestBlockSize:
            deadlineTask?.cancel()
            guard message.status == TransferStatus.success,
                  let payloadSize = message.blockPayloadSize,
                  payloadSize > 0 else {
                fail("设备拒绝块大小请求：\(data.hexString)")
                return
            }
            guard let peripheral = activePeripheral else { return }
            let maximum = peripheral.maximumWriteValueLength(for: .withoutResponse)
            guard payloadSize + 4 <= maximum else {
                fail("设备要求的 \(payloadSize + 4) 字节数据块超过 iOS 链路上限 \(maximum) 字节。")
                return
            }
            blockPayloadSize = payloadSize
            guard let payload = pendingPayload,
                  let request = try? encodePayloadLengthRequest(payload.count) else {
                fail("无法编码 Payload 长度。")
                return
            }
            phase = .waitingPayloadLength
            statusText = "正在提交图片大小…"
            sendControl(request, timeoutMessage: "等待设备确认 Payload 长度超时。")

        case .waitingPayloadLength where message.command == TransferCommand.requestPayloadLength:
            deadlineTask?.cancel()
            guard message.status == TransferStatus.success else {
                fail("设备拒绝 Payload 长度：\(data.hexString)")
                return
            }
            phase = .waitingStart
            statusText = "正在启动传输…"
            sendControl(
                Data([TransferCommand.requestStart]),
                timeoutMessage: "等待设备开始传输超时。"
            )

        case .waitingStart where message.command == TransferCommand.dataAcknowledgement:
            deadlineTask?.cancel()
            guard message.status == TransferStatus.success, let index = message.index,
                  let payload = pendingPayload else {
                fail("设备拒绝开始传输：\(data.hexString)")
                return
            }
            totalBlocks = Int(ceil(Double(payload.count) / Double(blockPayloadSize)))
            guard Int(index) <= totalBlocks else {
                fail("设备请求从块 \(index) 开始，但图片只有 \(totalBlocks) 块。")
                return
            }
            nextBlockIndex = Int(index)
            highestSentExclusive = Int(index)
            highestAcknowledgedIndex = Int(index)
            phase = .sendingData
            statusText = "正在发送图片…"
            appendLog("从块 \(index)/\(max(0, totalBlocks - 1)) 开始，5 块窗口、32 块最大未确认量。")
            pumpWindow()

        case .sendingData, .waitingFinal:
            guard message.command == TransferCommand.dataAcknowledgement else { return }
            handleDataAcknowledgement(message)

        default:
            appendLog("当前阶段忽略控制通知：\(data.hexString)")
        }
    }

    private func pumpWindow() {
        guard isSending, phase == .sendingData, let payload = pendingPayload,
              let peripheral = activePeripheral, let dataCharacteristic else { return }
        windowTask?.cancel()
        deadlineTask?.cancel()
        let identifier = transferID
        let start = nextBlockIndex
        let creditEnd = min(totalBlocks, highestAcknowledgedIndex + 32)
        let end = min(totalBlocks, min(start + 5, creditEnd))
        guard start < end else {
            armCheckpointDeadline()
            return
        }

        windowTask = Task { [weak self] in
            guard let self else { return }
            for index in start ..< end {
                guard !Task.isCancelled, self.transferID == identifier else { return }
                var readinessChecks = 0
                while !peripheral.canSendWriteWithoutResponse {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    guard !Task.isCancelled else { return }
                    readinessChecks += 1
                    if readinessChecks >= 1_000 {
                        self.fail("等待数据特征写入额度超时。")
                        return
                    }
                }
                do {
                    guard let block = try makeDataBlock(
                        payload: payload,
                        index: UInt32(index),
                        blockPayloadSize: self.blockPayloadSize
                    ) else { throw TransferProtocolError.invalidBlockIndex }
                    peripheral.writeValue(block.packet, for: dataCharacteristic, type: .withoutResponse)
                    self.dataWrites += 1
                    if index < self.highestSentExclusive { self.retransmittedBlocks += 1 }
                    self.highestSentExclusive = max(self.highestSentExclusive, index + 1)
                    self.progress = max(self.progress, Double(block.written) / Double(payload.count))
                    if index + 1 < end { try? await Task.sleep(nanoseconds: 4_000_000) }
                } catch {
                    self.fail(error.localizedDescription)
                    return
                }
            }
            guard !Task.isCancelled, self.transferID == identifier else { return }
            self.nextBlockIndex = end
            if end >= self.totalBlocks {
                self.phase = .waitingFinal
                self.statusText = "等待卡片刷新…"
                self.appendLog("全部数据块已写入；等待最终 05 08 ACK。")
                self.armDeadline(seconds: 90, message: "等待卡片最终刷新确认超时。")
            } else if end >= creditEnd {
                self.armCheckpointDeadline()
            } else {
                self.deadlineTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard !Task.isCancelled, let self, self.transferID == identifier else { return }
                    self.pumpWindow()
                }
            }
        }
    }

    private func handleDataAcknowledgement(_ message: ControlMessage) {
        guard message.status == TransferStatus.success, let rawIndex = message.index else {
            fail("设备返回了无效的数据确认：\(message.bytes.hexString)")
            return
        }
        let index = Int(rawIndex)
        guard index <= totalBlocks, index <= highestSentExclusive else {
            fail("设备确认索引 \(index) 超出已发送范围。")
            return
        }
        if index < highestAcknowledgedIndex {
            appendLog("忽略陈旧 ACK \(index)，当前确认索引为 \(highestAcknowledgedIndex)。")
            return
        }

        deadlineTask?.cancel()
        windowTask?.cancel()
        if index > highestAcknowledgedIndex {
            highestAcknowledgedIndex = index
            repeatedAcknowledgementCount = 0
            checkpointTimeouts = 0
        } else {
            repeatedAcknowledgementCount += 1
            guard repeatedAcknowledgementCount <= 8 else {
                fail("设备连续停在确认索引 \(index)，已停止以避免无限重传。")
                return
            }
        }
        progress = max(progress, Double(index) / Double(max(1, totalBlocks)))
        appendLog("累计 ACK：设备需要的首个未确认块为 \(index)。")
        phase = .sendingData
        nextBlockIndex = index < highestSentExclusive ? index : max(nextBlockIndex, index)
        pumpWindow()
    }

    private func armCheckpointDeadline() {
        let identifier = transferID
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.transferID == identifier, self.isSending else { return }
            self.checkpointTimeouts += 1
            guard self.checkpointTimeouts <= 3 else {
                self.fail("设备连续 4 次未回复累计 ACK，已停止重传。")
                return
            }
            self.appendLog("累计 ACK 超时（\(self.checkpointTimeouts)/3），从块 \(self.highestAcknowledgedIndex) 重传。")
            self.phase = .sendingData
            self.nextBlockIndex = self.highestAcknowledgedIndex
            self.pumpWindow()
        }
    }

    private func armDeadline(seconds: UInt64, message: String) {
        let identifier = transferID
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.transferID == identifier, self.isSending else { return }
            self.fail(message)
        }
    }

    private func completeTransfer(finalAck: String) {
        guard isSending else { return }
        windowTask?.cancel()
        deadlineTask?.cancel()
        phase = .idle
        isSending = false
        progress = 1
        pendingPayload = nil
        statusText = "卡片屏幕刷新成功"
        appendLog("收到最终 ACK \(finalAck)；写入 \(dataWrites) 块，重传 \(retransmittedBlocks) 块。")
    }

    private func fail(_ message: String) {
        windowTask?.cancel()
        deadlineTask?.cancel()
        phase = .idle
        isSending = false
        handshakeScheduled = false
        statusText = "操作失败"
        errorMessage = message
        appendLog("错误：\(message)")
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 240 { logs.removeFirst(logs.count - 240) }
    }
}

extension TodooBluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("蓝牙已就绪。")
        case .poweredOff:
            statusText = "蓝牙已关闭"
            stopDiscovery()
        case .unauthorized:
            statusText = "没有蓝牙权限"
        case .unsupported:
            statusText = "此设备不支持蓝牙"
        default:
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let advertisement = try? parseTodooAdvertisement(data),
              advertisement.isCompatible else { return }
        peripherals[peripheral.identifier] = peripheral
        advertisements[peripheral.identifier] = advertisement
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "TodooCard"
        let card = DiscoveredCard(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            firmwareVersion: advertisement.firmwareVersion,
            pairingWindowOpen: advertisement.pairingWindowOpen,
            rawAdvertisement: advertisement.rawHex
        )
        if let index = devices.firstIndex(where: { $0.id == card.id }) {
            devices[index] = card
        } else {
            devices.append(card)
            appendLog("发现 \(name)，RSSI \(RSSI)，固件 0x\(String(format: "%02X", advertisement.firmwareVersion))。")
        }
        devices.sort { $0.rssi > $1.rssi }
        statusText = "发现 \(devices.count) 台兼容设备"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        connectedDeviceName = peripheral.name ?? "TodooCard"
        statusText = "正在验证安全连接…"
        appendLog("已连接；发现 Battery、FEF0/FDF0 服务。")
        let serviceUUIDs = [CBUUID(string: TodooBluetoothConstants.batteryService)]
            + TodooBluetoothConstants.transferProfiles.map { CBUUID(string: $0.service) }
        peripheral.discoverServices(serviceUUIDs)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        clearConnection()
        fail("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        let wasSending = isSending
        clearConnection()
        statusText = "连接已断开"
        appendLog("设备已断开：\(error?.localizedDescription ?? "正常断开")")
        if wasSending { errorMessage = "传输过程中蓝牙连接断开。" }
    }
}

extension TodooBluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("发现服务失败：\(error.localizedDescription)"); return }
        guard let services = peripheral.services else { fail("设备没有返回 GATT 服务。"); return }
        guard let battery = services.first(where: { $0.uuid == CBUUID(string: TodooBluetoothConstants.batteryService) }) else {
            fail("未发现加密 Battery 服务，无法验证系统绑定。")
            return
        }
        guard let profile = TodooBluetoothConstants.transferProfiles.first(where: { profile in
            services.contains { $0.uuid == CBUUID(string: profile.service) }
        }), let transfer = services.first(where: { $0.uuid == CBUUID(string: profile.service) }) else {
            fail("未发现 FEF0 或 FDF0 传输服务。")
            return
        }
        selectedProfile = profile
        appendLog("采用 \(profile.label) 传输配置。")
        peripheral.discoverCharacteristics([CBUUID(string: TodooBluetoothConstants.batteryLevel)], for: battery)
        peripheral.discoverCharacteristics(
            [CBUUID(string: profile.control), CBUUID(string: profile.data)],
            for: transfer
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail("发现特征失败：\(error.localizedDescription)"); return }
        let characteristics = service.characteristics ?? []
        if service.uuid == CBUUID(string: TodooBluetoothConstants.batteryService) {
            guard let battery = characteristics.first(where: {
                $0.uuid == CBUUID(string: TodooBluetoothConstants.batteryLevel)
            }) else { fail("未发现 Battery Level 特征。"); return }
            batteryCharacteristic = battery
            appendLog("读取加密 Battery Level，以触发或验证系统绑定。")
            peripheral.readValue(for: battery)
            return
        }

        guard let profile = selectedProfile else { return }
        let controlUUID = CBUUID(string: profile.control)
        let dataUUID = CBUUID(string: profile.data)
        guard let control = characteristics.first(where: { $0.uuid == controlUUID }),
              let data = characteristics.first(where: { $0.uuid == dataUUID }) else {
            fail("传输服务缺少控制或数据特征。")
            return
        }
        guard control.properties.contains(.notify) || control.properties.contains(.indicate) else {
            fail("控制特征不支持 notify/indicate。")
            return
        }
        guard data.properties.contains(.writeWithoutResponse) else {
            fail("数据特征不支持 writeWithoutResponse。")
            return
        }
        controlCharacteristic = control
        dataCharacteristic = data
        transferCharacteristicsReady = true
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("订阅控制通知失败：\(error.localizedDescription)"); return }
        guard characteristic.uuid == controlCharacteristic?.uuid, characteristic.isNotifying else { return }
        controlNotificationsReady = true
        appendLog("控制通知已订阅。")
        startTransferIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == batteryCharacteristic?.uuid {
            if let error { fail("加密 Battery Level 读取失败：\(error.localizedDescription)"); return }
            guard let value = characteristic.value?.first else { fail("Battery Level 回复为空。"); return }
            batteryLevel = Int(value)
            batteryReadComplete = true
            appendLog("安全连接验证成功，电量 \(value)% 。")
            startTransferIfReady()
            return
        }
        guard characteristic.uuid == controlCharacteristic?.uuid else { return }
        if let error { fail("控制通知错误：\(error.localizedDescription)"); return }
        guard let value = characteristic.value else { return }
        handleControl(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        if characteristic.uuid == controlCharacteristic?.uuid,
           characteristic.properties.contains(.writeWithoutResponse) {
            appendLog("控制 withResponse 写入未确认，将使用备用写入：\(error.localizedDescription)")
            return
        }
        fail("写入 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
    }
}
