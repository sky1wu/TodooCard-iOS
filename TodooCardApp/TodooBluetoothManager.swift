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

/// App Group 的标识与共享存储。主 App、分享扩展和画面快照都要读它，
/// 所以不挂在 @MainActor 上，任何线程都能直接取。
enum TodooAppGroup {
    static let identifier: String = {
        guard let configured = Bundle.main.object(
            forInfoDictionaryKey: "TodooAppGroupIdentifier"
        ) as? String, !configured.isEmpty, !configured.contains("$(") else {
            return "group.com.todoocard.sender"
        }
        return configured
    }()

    static let preferences = UserDefaults(suiteName: identifier) ?? .standard

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

@MainActor
final class TodooBluetoothManager: NSObject, ObservableObject {
    static let shared = TodooBluetoothManager()

    @Published private(set) var devices: [DiscoveredCard] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isPreparingTransfer = false
    @Published private(set) var isSending = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "未连接"
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var logs: [String] = []
    @Published var errorMessage: String?

    var isBusy: Bool { isPreparingTransfer || isSending }
    var hasCurrentDevice: Bool { currentDeviceIdentifier != nil }
    var currentDeviceIdentifier: UUID? {
        activePeripheral?.identifier ?? persistedCurrentDeviceIdentifier
    }
    var rememberedAutomationDeviceName: String? {
        guard let identifier = preferredDeviceIdentifier else { return nil }
        return deviceAlias(for: identifier)
            ?? Self.preferences.string(forKey: Self.preferredDeviceNameKey)
            ?? "TodooCard"
    }

    private enum Phase: Equatable {
        case idle
        case waitingBlockSize
        case waitingPayloadLength
        case waitingStart
        case sendingData
        case waitingFinal
    }

    private struct PendingControlWrite {
        let transferID: UUID
        let phase: Phase
        let data: Data
        let timeoutMessage: String
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
    private var automaticSendPayload: Data?
    private var isFindingCurrentDevice = false
    private var pendingControlWrite: PendingControlWrite?
    private var phase = Phase.idle

    private var batteryReadComplete = false
    private var transferCharacteristicsReady = false
    private var controlNotificationsReady = false
    private var handshakeScheduled = false
    private var secureCacheRefreshScheduled = false
    private var controlRetriedWithoutResponse = false
    private var shouldMaintainConnection = false
    private var reconnectAttempts = 0
    private var transferConnectionRecoveryAttempts = 0
    private var reconnectingForTransfer = false
    private var lastGATTActivityAt: Date?

    private let reusableConnectionIdleLimit: TimeInterval = 10 * 60

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
    private var controlFallbackTask: Task<Void, Never>?
    private var serviceRefreshTask: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var automaticTransferTimeoutTask: Task<Void, Never>?
    private var automaticTransferContinuation: CheckedContinuation<Void, Error>?
    private var transferID = UUID()

    private static let preferredDeviceIdentifierKey = "TodooCard.preferredDeviceIdentifier"
    private static let preferredDeviceNameKey = "TodooCard.preferredDeviceName"
    private static let currentDeviceIdentifierKey = "TodooCard.currentDeviceIdentifier"
    private static let currentDeviceNameKey = "TodooCard.currentDeviceName"
    private static let deviceAliasesKey = "TodooCard.deviceAliases"
    private static let centralRestoreIdentifier = "com.todoocard.sender.central"
    private static var automaticTransferOwner: ObjectIdentifier?
    private static let preferences = TodooAppGroup.preferences
    private static let isAppExtension = Bundle.main.bundleURL.pathExtension == "appex"
    private static let sharedPreferenceKeys = [
        preferredDeviceIdentifierKey,
        preferredDeviceNameKey,
        currentDeviceIdentifierKey,
        currentDeviceNameKey,
        deviceAliasesKey,
    ]

    private var preferredDeviceIdentifier: UUID? {
        guard let value = Self.preferences.string(forKey: Self.preferredDeviceIdentifierKey)
        else { return nil }
        return UUID(uuidString: value)
    }

    private var persistedCurrentDeviceIdentifier: UUID? {
        guard let value = Self.preferences.string(forKey: Self.currentDeviceIdentifierKey)
        else { return nil }
        return UUID(uuidString: value)
    }

    override init() {
        super.init()
        Self.migrateLegacyPreferencesIfNeeded()
        if let identifier = persistedCurrentDeviceIdentifier {
            shouldMaintainConnection = true
            connectedDeviceName = resolvedDeviceName(
                for: identifier,
                fallback: Self.preferences.string(forKey: Self.currentDeviceNameKey)
            )
        }
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: Self.isAppExtension
                ? nil
                : [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
    }

    private static func migrateLegacyPreferencesIfNeeded() {
        guard !isAppExtension else { return }
        for key in sharedPreferenceKeys where preferences.object(forKey: key) == nil {
            guard let legacyValue = UserDefaults.standard.object(forKey: key) else { continue }
            preferences.set(legacyValue, forKey: key)
        }
    }

    func beginDiscovery() {
        automaticSendPayload = nil
        isFindingCurrentDevice = false
        isPreparingTransfer = false
        startDiscovery()
    }

    private func sendAutomatically(_ payload: Data) {
        errorMessage = nil
        guard !payload.isEmpty else {
            fail("不能发送空 Payload。")
            return
        }
        guard !isBusy else {
            errorMessage = "TodooCard 正在执行另一项操作，请稍后重新发送。"
            return
        }
        if isConnected {
            send(payload)
            return
        }
        guard preferredDeviceIdentifier != nil else {
            fail("尚未设置自动化设备。请先在 App 中手动选择卡片并成功发送一次。")
            return
        }

        stopDiscovery()
        automaticSendPayload = payload
        isPreparingTransfer = true
        switch central.state {
        case .poweredOn:
            resumeAutomaticSend()
        case .unknown, .resetting:
            statusText = "正在等待蓝牙就绪…"
            appendLog("自动发送图片已就绪；等待 CoreBluetooth 初始化。")
        case .poweredOff:
            fail("请先在系统设置中打开蓝牙。")
        case .unauthorized:
            fail("请允许 TodooCard 使用蓝牙。")
        case .unsupported:
            fail("此设备不支持蓝牙。")
        @unknown default:
            fail("无法初始化蓝牙。")
        }
    }

    func sendAutomaticallyAndWait(_ payload: Data) async throws {
        guard automaticTransferContinuation == nil, !isBusy,
              Self.automaticTransferOwner == nil else {
            throw AutomaticUpdateError.transferInProgress
        }
        Self.automaticTransferOwner = ObjectIdentifier(self)
        defer {
            if Self.automaticTransferOwner == ObjectIdentifier(self) {
                Self.automaticTransferOwner = nil
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            automaticTransferContinuation = continuation
            automaticTransferTimeoutTask?.cancel()
            automaticTransferTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                guard !Task.isCancelled, let self,
                      self.automaticTransferContinuation != nil else { return }
                self.fail("后台自动发送超过 3 分钟，已停止等待。")
            }
            sendAutomatically(payload)
        }
    }

    private func resumeAutomaticSend() {
        guard central.state == .poweredOn,
              let payload = automaticSendPayload,
              let identifier = preferredDeviceIdentifier else { return }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            automaticSendPayload = nil
            appendLog("从系统缓存恢复已记住的自动化设备，直接连接。")
            connectAndSend(peripheral: peripheral, payload: payload)
        } else {
            appendLog("系统缓存中没有已记住的设备，回退到蓝牙扫描。")
            startDiscovery()
        }
    }

    private func startDiscovery() {
        errorMessage = nil
        guard central.state == .poweredOn else {
            fail("请先在系统设置中打开蓝牙，并允许 TodooCard 使用蓝牙。")
            return
        }
        devices = []
        peripherals = [:]
        advertisements = [:]
        isScanning = true
        if !isConnected { statusText = "正在查找 TodooCard…" }
        appendLog("开始扫描厂商 0x5053、屏幕 0x134C。")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.automaticSendPayload != nil {
                self.automaticSendPayload = nil
                self.fail("没有找到上次成功使用的 TodooCard。请确认卡片已开机并靠近 iPhone。")
                return
            }
            if self.isFindingCurrentDevice {
                self.isFindingCurrentDevice = false
                self.pendingPayload = nil
                self.isPreparingTransfer = false
                self.statusText = "未找到 \(self.connectedDeviceName ?? "当前设备")"
                self.errorMessage = "没有找到当前设备。请确认卡片已开机并靠近 iPhone，或更改连接设备。"
                self.appendLog("扫描结束，未找到当前设备。")
                return
            }
            if self.devices.isEmpty {
                if !self.isConnected { self.statusText = "没有找到兼容设备" }
                self.appendLog("扫描结束，未发现兼容广播。")
            } else if !self.isConnected {
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
        connectAndSend(peripheral: peripheral, payload: payload)
    }

    func connect(deviceID: UUID) {
        guard let peripheral = peripherals[deviceID], let advertisement = advertisements[deviceID] else {
            fail("选中的设备已离开扫描范围，请重新扫描。")
            return
        }
        guard !advertisement.pairingWindowOpen else {
            fail("设备广播显示 pairing=open。请先在系统蓝牙设置中完成绑定，等待配对窗口关闭后再试。")
            return
        }
        connect(peripheral: peripheral, payload: nil)
    }

    private func connectAndSend(peripheral: CBPeripheral, payload: Data) {
        connect(peripheral: peripheral, payload: payload)
    }

    private func connect(peripheral: CBPeripheral, payload: Data?) {
        stopDiscovery()
        if let activePeripheral,
           activePeripheral.identifier != peripheral.identifier {
            appendLog(
                "切换设备：\(activePeripheral.identifier.uuidString) -> \(peripheral.identifier.uuidString)"
            )
            shouldMaintainConnection = false
            central.cancelPeripheralConnection(activePeripheral)
            clearConnection()
        }

        pendingPayload = payload
        progress = 0
        errorMessage = nil
        isPreparingTransfer = payload != nil
        shouldMaintainConnection = true
        reconnectAttempts = 0
        transferConnectionRecoveryAttempts = 0
        reconnectingForTransfer = false
        activePeripheral = peripheral
        peripheral.delegate = self
        persistCurrentDevice(
            identifier: peripheral.identifier,
            name: resolvedDeviceName(for: peripheral.identifier, fallback: peripheral.name)
        )

        if peripheral.state == .connected, isConnected {
            isConnecting = !isConnected
            startTransferIfReady()
            return
        }

        reconnectTask?.cancel()
        resetConnectionDiscovery()
        isConnecting = true
        statusText = "正在连接 \(connectedDeviceName ?? "TodooCard")…"
        appendLog("连接 -> \(peripheral.identifier.uuidString)")
        switch peripheral.state {
        case .connected:
            peripheral.discoverServices(nil)
        case .connecting:
            appendLog("CoreBluetooth 已在连接当前设备；发送任务已排队。")
        case .disconnecting:
            appendLog("等待当前设备断开完成后自动恢复连接。")
        case .disconnected:
            central.connect(peripheral, options: nil)
        @unknown default:
            central.connect(peripheral, options: nil)
        }
    }

    @discardableResult
    func sendToCurrentDevice(_ payload: Data) -> Bool {
        guard let identifier = currentDeviceIdentifier else { return false }
        if isConnected,
           let activePeripheral,
           activePeripheral.identifier == identifier,
           activePeripheral.state == .connected {
            send(payload)
            return true
        }
        if let activePeripheral, activePeripheral.identifier == identifier {
            connectAndSend(peripheral: activePeripheral, payload: payload)
            return true
        }
        guard central.state == .poweredOn else {
            fail("请先在系统设置中打开蓝牙，并允许 TodooCard 使用蓝牙。")
            return true
        }
        if let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first {
            appendLog("恢复当前设备并继续发送。")
            connectAndSend(peripheral: peripheral, payload: payload)
            return true
        }
        pendingPayload = payload
        isPreparingTransfer = true
        isFindingCurrentDevice = true
        appendLog("系统缓存中没有当前设备；扫描并自动恢复当前设备。")
        startDiscovery()
        statusText = "正在查找 \(connectedDeviceName ?? "当前设备")…"
        return true
    }

    func send(_ payload: Data) {
        guard isConnected, activePeripheral?.state == .connected else {
            fail("设备连接已断开，请重新连接。")
            return
        }
        pendingPayload = payload
        progress = 0
        isPreparingTransfer = true
        transferConnectionRecoveryAttempts = 0
        reconnectingForTransfer = false
        if let lastGATTActivityAt {
            let idleSeconds = Date().timeIntervalSince(lastGATTActivityAt)
            if idleSeconds >= reusableConnectionIdleLimit,
               refreshConnectionForPendingTransfer(
                reason: "连接已空闲 \(Int(idleSeconds)) 秒，发送前刷新 GATT 链路。",
                countsAsRecovery: false
               ) {
                return
            }
        }
        startTransferIfReady()
    }

    func disconnect() {
        shouldMaintainConnection = false
        automaticSendPayload = nil
        reconnectAttempts = 0
        stopDiscovery()
        windowTask?.cancel()
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()
        serviceRefreshTask?.cancel()
        handshakeTask?.cancel()
        reconnectTask?.cancel()
        if let activePeripheral {
            central.cancelPeripheralConnection(activePeripheral)
        }
        clearConnection()
        clearPersistedCurrentDevice()
        statusText = "已断开连接"
        finishAutomaticTransfer(
            .failure(AutomaticUpdateError.transferFailed("后台自动发送已取消。"))
        )
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
        secureCacheRefreshScheduled = false
        controlRetriedWithoutResponse = false
        pendingControlWrite = nil
        handshakeTask?.cancel()
        batteryLevel = nil
        lastGATTActivityAt = nil
        phase = .idle
        isConnected = false
    }

    private func clearConnection() {
        controlFallbackTask?.cancel()
        serviceRefreshTask?.cancel()
        handshakeTask?.cancel()
        reconnectTask?.cancel()
        resetConnectionDiscovery()
        activePeripheral = nil
        isConnected = false
        isConnecting = false
        isPreparingTransfer = false
        isSending = false
        reconnectingForTransfer = false
        transferConnectionRecoveryAttempts = 0
        isFindingCurrentDevice = false
        pendingPayload = nil
    }

    private func startTransferIfReady() {
        guard pendingPayload != nil else {
            if isConnected {
                isConnecting = false
                statusText = "已连接到 \(connectedDeviceName ?? "TodooCard")"
            }
            return
        }
        isPreparingTransfer = true
        guard batteryReadComplete, transferCharacteristicsReady, controlNotificationsReady else {
            statusText = "正在验证安全连接…"
            return
        }
        guard !isSending, !handshakeScheduled else { return }
        handshakeScheduled = true
        statusText = "正在准备传输…"
        let settleNanoseconds: UInt64 = 400_000_000
        appendLog("电量读取和控制通知均已就绪；等待 400 ms 稳定通知链路。")
        handshakeTask?.cancel()
        handshakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: settleNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.handshakeTask = nil
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
        isConnecting = false
        isPreparingTransfer = false
        reconnectingForTransfer = false
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
        guard characteristic.properties.contains(.writeWithoutResponse)
                || characteristic.properties.contains(.write) else {
            fail("控制特征不支持写入。")
            return
        }

        let pending = PendingControlWrite(
            transferID: transferID,
            phase: phase,
            data: data,
            timeoutMessage: timeoutMessage
        )
        pendingControlWrite = pending
        controlRetriedWithoutResponse = false
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()

        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write)
            ? .withResponse
            : .withoutResponse
        armControlResponseDeadline(pending, initialType: type)
        armControlFallback(pending)
        let label = type == .withResponse ? "withResponse" : "withoutResponse"
        appendLog("控制 -> \(data.hexString) (\(label))")
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    private func armControlResponseDeadline(
        _ pending: PendingControlWrite,
        initialType: CBCharacteristicWriteType
    ) {
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.matches(pending) else { return }
            if initialType == .withResponse,
               !self.controlRetriedWithoutResponse,
               let peripheral = self.activePeripheral,
               let characteristic = self.controlCharacteristic,
               characteristic.properties.contains(.writeWithoutResponse) {
                self.controlRetriedWithoutResponse = true
                self.appendLog("控制回复 5 秒未到；按原始发送器流程改用 withoutResponse。")
                peripheral.writeValue(pending.data, for: characteristic, type: .withoutResponse)
                self.armControlResponseDeadline(pending, initialType: .withoutResponse)
                return
            }
            if self.refreshConnectionForPendingTransfer(
                reason: "控制握手无响应，自动重建连接后重试。",
                countsAsRecovery: true
            ) {
                return
            }
            self.fail(pending.timeoutMessage)
        }
    }

    private func armControlFallback(_ pending: PendingControlWrite) {
        controlFallbackTask?.cancel()
        guard controlCharacteristic?.properties.contains(.writeWithoutResponse) == true else { return }
        controlFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.matches(pending),
                  !self.controlRetriedWithoutResponse,
                  let peripheral = self.activePeripheral,
                  let characteristic = self.controlCharacteristic else { return }
            self.controlRetriedWithoutResponse = true
            self.appendLog("控制通知 600 ms 未到；按原始发送器流程以 withoutResponse 重发。")
            peripheral.writeValue(pending.data, for: characteristic, type: .withoutResponse)
        }
    }

    private func matches(_ pending: PendingControlWrite) -> Bool {
        isSending && transferID == pending.transferID && phase == pending.phase
            && pendingControlWrite?.transferID == pending.transferID
            && pendingControlWrite?.phase == pending.phase
    }

    private func finishControlExchange() {
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()
        pendingControlWrite = nil
        controlRetriedWithoutResponse = false
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
            finishControlExchange()
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
            finishControlExchange()
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
            finishControlExchange()
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
        controlFallbackTask?.cancel()
        pendingControlWrite = nil
        phase = .idle
        isPreparingTransfer = false
        isSending = false
        reconnectingForTransfer = false
        transferConnectionRecoveryAttempts = 0
        progress = 1
        pendingPayload = nil
        statusText = "发送成功，连接已保持"
        rememberActiveDevice()
        appendLog("收到最终 ACK \(finalAck)；写入 \(dataWrites) 块，重传 \(retransmittedBlocks) 块。")
        finishAutomaticTransfer(.success(()))
    }

    private func rememberActiveDevice() {
        guard let peripheral = activePeripheral else { return }
        let changed = preferredDeviceIdentifier != peripheral.identifier
        Self.preferences.set(
            peripheral.identifier.uuidString,
            forKey: Self.preferredDeviceIdentifierKey
        )
        Self.preferences.set(
            connectedDeviceName ?? peripheral.name ?? "TodooCard",
            forKey: Self.preferredDeviceNameKey
        )
        if changed { appendLog("已将当前设备设为后续分享与自动化发送的默认设备。") }
    }

    func renameCurrentDevice(to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = String(trimmedName.prefix(24))
        guard !normalizedName.isEmpty, let identifier = currentDeviceIdentifier else { return }

        var aliases = deviceAliases
        aliases[identifier.uuidString] = normalizedName
        Self.preferences.set(aliases, forKey: Self.deviceAliasesKey)
        Self.preferences.set(normalizedName, forKey: Self.currentDeviceNameKey)
        if preferredDeviceIdentifier == identifier {
            Self.preferences.set(normalizedName, forKey: Self.preferredDeviceNameKey)
        }
        connectedDeviceName = normalizedName
        if let index = devices.firstIndex(where: { $0.id == identifier }) {
            let device = devices[index]
            devices[index] = DiscoveredCard(
                id: device.id,
                name: normalizedName,
                rssi: device.rssi,
                firmwareVersion: device.firmwareVersion,
                pairingWindowOpen: device.pairingWindowOpen,
                rawAdvertisement: device.rawAdvertisement
            )
        }
        if isConnected, !isBusy {
            statusText = "已连接到 \(normalizedName)"
        }
        appendLog("当前设备已在本机重命名为“\(normalizedName)”。")
    }

    private var deviceAliases: [String: String] {
        Self.preferences.dictionary(forKey: Self.deviceAliasesKey) as? [String: String] ?? [:]
    }

    private func deviceAlias(for identifier: UUID) -> String? {
        deviceAliases[identifier.uuidString]
    }

    private func resolvedDeviceName(for identifier: UUID, fallback: String?) -> String {
        deviceAlias(for: identifier) ?? fallback ?? "TodooCard"
    }

    private func persistCurrentDevice(identifier: UUID, name: String) {
        Self.preferences.set(
            identifier.uuidString,
            forKey: Self.currentDeviceIdentifierKey
        )
        Self.preferences.set(name, forKey: Self.currentDeviceNameKey)
        connectedDeviceName = name
    }

    private func clearPersistedCurrentDevice() {
        Self.preferences.removeObject(forKey: Self.currentDeviceIdentifierKey)
        Self.preferences.removeObject(forKey: Self.currentDeviceNameKey)
        connectedDeviceName = nil
    }

    private func fail(_ message: String) {
        let unreadyPeripheral = isConnecting && !isConnected ? activePeripheral : nil
        var peripheralToRetry: CBPeripheral?
        windowTask?.cancel()
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()
        serviceRefreshTask?.cancel()
        handshakeTask?.cancel()
        pendingControlWrite = nil
        automaticSendPayload = nil
        isFindingCurrentDevice = false
        pendingPayload = nil
        phase = .idle
        isSending = false
        isConnecting = false
        isPreparingTransfer = false
        reconnectingForTransfer = false
        transferConnectionRecoveryAttempts = 0
        handshakeScheduled = false
        if let unreadyPeripheral {
            let wasEstablishedDevice = preferredDeviceIdentifier == unreadyPeripheral.identifier
                && persistedCurrentDeviceIdentifier == unreadyPeripheral.identifier
            if wasEstablishedDevice, shouldMaintainConnection {
                resetConnectionDiscovery()
                appendLog("当前设备会话初始化失败；保留设备并等待自动重连。")
                central.cancelPeripheralConnection(unreadyPeripheral)
                peripheralToRetry = unreadyPeripheral
            } else {
                shouldMaintainConnection = false
                central.cancelPeripheralConnection(unreadyPeripheral)
                clearConnection()
            }
        }
        statusText = "操作失败"
        errorMessage = message
        appendLog("错误：\(message)")
        if let peripheralToRetry {
            scheduleReconnect(to: peripheralToRetry, delayNanoseconds: 1_200_000_000)
        }
        finishAutomaticTransfer(.failure(AutomaticUpdateError.transferFailed(message)))
    }

    private func finishAutomaticTransfer(_ result: Result<Void, Error>) {
        automaticTransferTimeoutTask?.cancel()
        automaticTransferTimeoutTask = nil
        if Self.automaticTransferOwner == ObjectIdentifier(self) {
            Self.automaticTransferOwner = nil
        }
        guard let continuation = automaticTransferContinuation else { return }
        automaticTransferContinuation = nil
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        logs.append("[\(formatter.string(from: Date()))] \(message)")
        if logs.count > 240 { logs.removeFirst(logs.count - 240) }
    }

    @discardableResult
    private func refreshConnectionForPendingTransfer(
        reason: String,
        countsAsRecovery: Bool
    ) -> Bool {
        guard pendingPayload != nil,
              shouldMaintainConnection,
              central.state == .poweredOn,
              let peripheral = activePeripheral,
              peripheral.state == .connected else { return false }
        if countsAsRecovery {
            guard phase == .waitingBlockSize
                    || phase == .waitingPayloadLength
                    || phase == .waitingStart else { return false }
            guard transferConnectionRecoveryAttempts < 1 else { return false }
            transferConnectionRecoveryAttempts += 1
        }

        windowTask?.cancel()
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()
        serviceRefreshTask?.cancel()
        handshakeTask?.cancel()
        reconnectTask?.cancel()
        pendingControlWrite = nil
        isSending = false
        isPreparingTransfer = true
        reconnectingForTransfer = true
        reconnectAttempts = 0
        resetConnectionDiscovery()
        isConnecting = true
        statusText = "正在恢复连接…"
        appendLog(reason)
        appendLog("保留待发送图片；连接恢复后将自动继续。")
        central.cancelPeripheralConnection(peripheral)
        return true
    }

    private func scheduleReconnect(to peripheral: CBPeripheral, delayNanoseconds: UInt64 = 800_000_000) {
        guard shouldMaintainConnection, central.state == .poweredOn else { return }

        reconnectTask?.cancel()
        reconnectAttempts = min(reconnectAttempts + 1, 1_000)
        let attempt = reconnectAttempts
        let backoffMultiplier = 1 << min(max(0, attempt - 1), 5)
        let backoffNanoseconds = UInt64(backoffMultiplier) * 800_000_000
        let effectiveDelay = min(30_000_000_000, max(delayNanoseconds, backoffNanoseconds))
        isConnecting = true
        isConnected = false
        statusText = "正在恢复连接…"
        appendLog("将在 \(Double(effectiveDelay) / 1_000_000_000) 秒后恢复连接（第 \(attempt) 次）。")
        reconnectTask = Task { [weak self, weak peripheral] in
            try? await Task.sleep(nanoseconds: effectiveDelay)
            guard !Task.isCancelled, let self, let peripheral,
                  self.shouldMaintainConnection,
                  self.central.state == .poweredOn,
                  self.activePeripheral?.identifier == peripheral.identifier else { return }
            self.appendLog("恢复连接 -> \(peripheral.identifier.uuidString)")
            self.central.connect(peripheral, options: nil)
        }
    }
}

extension TodooBluetoothManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            appendLog("蓝牙已就绪。")
            if automaticSendPayload != nil, !isScanning {
                resumeAutomaticSend()
                return
            }
            if shouldMaintainConnection,
               activePeripheral == nil,
               let identifier = persistedCurrentDeviceIdentifier,
               let peripheral = central.retrievePeripherals(withIdentifiers: [identifier]).first {
                appendLog("App 恢复当前设备 -> \(identifier.uuidString)")
                connect(peripheral: peripheral, payload: nil)
                return
            }
            if shouldMaintainConnection,
               let activePeripheral,
               activePeripheral.state == .connected,
               !isConnected {
                resetConnectionDiscovery()
                isConnecting = true
                appendLog("恢复已存在的 CoreBluetooth 链路；重新验证 GATT 会话。")
                activePeripheral.discoverServices(nil)
                return
            }
            if shouldMaintainConnection, let activePeripheral,
               activePeripheral.state == .disconnected {
                scheduleReconnect(to: activePeripheral, delayNanoseconds: 0)
            }
        case .poweredOff:
            if automaticTransferContinuation != nil {
                fail("蓝牙已关闭，无法在后台更新卡片。")
                return
            }
            statusText = "蓝牙已关闭"
            stopDiscovery()
            isConnected = false
            isConnecting = false
        case .unauthorized:
            if automaticTransferContinuation != nil {
                fail("请允许 TodooCard 使用蓝牙。")
                return
            }
            statusText = "没有蓝牙权限"
        case .unsupported:
            if automaticTransferContinuation != nil {
                fail("此设备不支持蓝牙。")
                return
            }
            statusText = "此设备不支持蓝牙"
        case .resetting:
            if automaticSendPayload != nil {
                stopDiscovery()
                statusText = "正在等待蓝牙恢复…"
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let identifier = persistedCurrentDeviceIdentifier,
              let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let peripheral = peripherals.first(where: { $0.identifier == identifier }) else { return }
        activePeripheral = peripheral
        peripheral.delegate = self
        shouldMaintainConnection = true
        isConnecting = true
        connectedDeviceName = resolvedDeviceName(
            for: identifier,
            fallback: Self.preferences.string(forKey: Self.currentDeviceNameKey) ?? peripheral.name
        )
        statusText = "正在恢复与 \(connectedDeviceName ?? "TodooCard") 的连接…"
        appendLog("CoreBluetooth 已恢复当前设备会话。")
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
            name: resolvedDeviceName(for: peripheral.identifier, fallback: name),
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
        if let payload = automaticSendPayload,
           peripheral.identifier == preferredDeviceIdentifier {
            automaticSendPayload = nil
            appendLog("找到已记住的自动化设备，开始连接并发送。")
            connectAndSend(deviceID: peripheral.identifier, payload: payload)
        } else if isFindingCurrentDevice,
                  peripheral.identifier == currentDeviceIdentifier,
                  let payload = pendingPayload {
            isFindingCurrentDevice = false
            appendLog("找到当前设备，继续连接并发送。")
            connectAndSend(deviceID: peripheral.identifier, payload: payload)
        } else if automaticSendPayload != nil {
            statusText = "正在查找已记住的卡片…"
        } else if isFindingCurrentDevice {
            statusText = "正在查找 \(connectedDeviceName ?? "当前设备")…"
        } else if !isConnected {
            statusText = "发现 \(devices.count) 台兼容设备"
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        reconnectTask?.cancel()
        reconnectAttempts = 0
        resetConnectionDiscovery()
        isConnecting = true
        persistCurrentDevice(
            identifier: peripheral.identifier,
            name: resolvedDeviceName(for: peripheral.identifier, fallback: peripheral.name)
        )
        statusText = "正在验证安全连接…"
        appendLog("已连接；先发现加密 Battery 服务。")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        if shouldMaintainConnection, central.state == .poweredOn {
            appendLog("连接失败：\(error?.localizedDescription ?? "未知错误")；准备重试。")
            scheduleReconnect(to: peripheral, delayNanoseconds: 1_200_000_000)
            return
        }
        clearConnection()
        fail("连接失败：\(error?.localizedDescription ?? "未知错误")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        let wasSending = isSending
        let wasRecoveringTransfer = reconnectingForTransfer
        windowTask?.cancel()
        deadlineTask?.cancel()
        controlFallbackTask?.cancel()
        serviceRefreshTask?.cancel()
        handshakeTask?.cancel()
        resetConnectionDiscovery()
        isSending = false
        if wasSending {
            pendingPayload = nil
            isPreparingTransfer = false
        }
        appendLog("设备已断开：\(error?.localizedDescription ?? "正常断开")")
        if wasSending { errorMessage = "传输过程中蓝牙连接断开。" }
        if wasSending {
            finishAutomaticTransfer(
                .failure(AutomaticUpdateError.transferFailed("传输过程中蓝牙连接断开。"))
            )
        }
        if wasRecoveringTransfer {
            appendLog("正在为待发送图片恢复有效的 GATT 会话。")
        }
        if shouldMaintainConnection, central.state == .poweredOn {
            scheduleReconnect(to: peripheral)
        } else {
            clearConnection()
            statusText = "连接已断开"
        }
    }
}

extension TodooBluetoothManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail("发现服务失败：\(error.localizedDescription)"); return }
        guard let services = peripheral.services else { fail("设备没有返回 GATT 服务。"); return }
        appendLog("GATT 服务：\(services.map { $0.uuid.uuidString }.joined(separator: ", "))。")

        if !batteryReadComplete {
            guard let battery = services.first(where: {
                $0.uuid == CBUUID(string: TodooBluetoothConstants.batteryService)
            }) else {
                fail("未发现加密 Battery 服务，无法验证系统绑定。")
                return
            }
            appendLog("第一阶段仅验证加密 Battery；暂不缓存传输特征。")
            peripheral.discoverCharacteristics(
                [CBUUID(string: TodooBluetoothConstants.batteryLevel)],
                for: battery
            )
            return
        }

        guard let profile = TodooBluetoothConstants.transferProfiles.first(where: { profile in
            services.contains { $0.uuid == CBUUID(string: profile.service) }
        }), let transfer = services.first(where: { $0.uuid == CBUUID(string: profile.service) }) else {
            fail("未发现 FEF0 或 FDF0 传输服务。")
            return
        }
        selectedProfile = profile
        appendLog("安全缓存刷新完成；采用 \(profile.label) 传输配置。")
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
        appendLog(
            "控制特征属性：notify=\(control.properties.contains(.notify))，"
                + "indicate=\(control.properties.contains(.indicate))，"
                + "write=\(control.properties.contains(.write))，"
                + "writeWithoutResponse=\(control.properties.contains(.writeWithoutResponse))。"
        )
        appendLog(
            "链路写入上限：withResponse="
                + "\(peripheral.maximumWriteValueLength(for: .withResponse))，withoutResponse="
                + "\(peripheral.maximumWriteValueLength(for: .withoutResponse))。"
        )
        peripheral.setNotifyValue(true, for: control)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail("订阅控制通知失败：\(error.localizedDescription)"); return }
        guard characteristic.uuid == controlCharacteristic?.uuid, characteristic.isNotifying else { return }
        controlNotificationsReady = true
        isConnected = true
        isConnecting = false
        lastGATTActivityAt = Date()
        appendLog("控制通知已订阅。")
        rememberActiveDevice()
        startTransferIfReady()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == batteryCharacteristic?.uuid {
            if let error { fail("加密 Battery Level 读取失败：\(error.localizedDescription)"); return }
            guard let value = characteristic.value?.first else { fail("Battery Level 回复为空。"); return }
            batteryLevel = Int(value)
            batteryReadComplete = true
            lastGATTActivityAt = Date()
            appendLog("安全连接验证成功，电量 \(value)% 。")
            guard !secureCacheRefreshScheduled else { return }
            secureCacheRefreshScheduled = true
            selectedProfile = nil
            controlCharacteristic = nil
            dataCharacteristic = nil
            transferCharacteristicsReady = false
            controlNotificationsReady = false
            statusText = "正在刷新安全服务…"
            appendLog("等待 1800 ms，让 Service Changed 与加密 GATT 缓存刷新。")
            serviceRefreshTask?.cancel()
            serviceRefreshTask = Task { [weak self, weak peripheral] in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                guard !Task.isCancelled, let self, let peripheral,
                      self.activePeripheral?.identifier == peripheral.identifier,
                      peripheral.state == .connected else { return }
                self.secureCacheRefreshScheduled = false
                self.appendLog("安全缓存等待完成；重新发现全部服务与传输特征。")
                peripheral.discoverServices(nil)
            }
            return
        }
        guard characteristic.uuid == controlCharacteristic?.uuid else { return }
        if let error {
            if refreshConnectionForPendingTransfer(
                reason: "控制通知错误：\(error.localizedDescription)；自动重建连接。",
                countsAsRecovery: true
            ) {
                return
            }
            fail("控制通知错误：\(error.localizedDescription)")
            return
        }
        guard let value = characteristic.value else { return }
        lastGATTActivityAt = Date()
        handleControl(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == controlCharacteristic?.uuid else { return }
        if let error {
            if refreshConnectionForPendingTransfer(
                reason: "控制 ATT 写入失败：\(error.localizedDescription)；自动重建连接。",
                countsAsRecovery: true
            ) {
                return
            }
            fail("写入 \(characteristic.uuid.uuidString) 失败：\(error.localizedDescription)")
            return
        }
        lastGATTActivityAt = Date()
        appendLog("控制 ATT 写入已确认。")
    }
}
