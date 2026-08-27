import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
#if canImport(TodooCore)
import TodooCore
#endif

private enum EditorPanel: String, CaseIterable, Identifiable {
    case framing
    case color

    var id: String { rawValue }
    var title: String { self == .framing ? "构图" : "色彩" }
}

struct ContentView: View {
    @StateObject private var editor = EditorModel()
    @StateObject private var bluetooth = TodooBluetoothManager()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedPanel = EditorPanel.framing
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showDevicePicker = false
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            Group {
                if editor.sourceImage == nil {
                    emptyState
                } else {
                    editorWorkspace
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("TodooCard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    importMenu
                    Button { showDiagnostics = true } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("诊断信息")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if editor.sourceImage != nil {
                    sendBar
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    await MainActor.run { editor.loadImage(data: data) }
                } catch {
                    await MainActor.run {
                        editor.errorMessage = "读取照片失败：\(error.localizedDescription)"
                    }
                }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                editor.loadImage(data: try Data(contentsOf: url))
            } catch {
                editor.errorMessage = "读取文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showDevicePicker, onDismiss: bluetooth.stopDiscovery) {
            DevicePicker(bluetooth: bluetooth) { device in
                guard let payload = editor.payload else { return }
                showDevicePicker = false
                bluetooth.connectAndSend(deviceID: device.id, payload: payload)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(editor: editor, bluetooth: bluetooth)
        }
        .alert("提示", isPresented: errorBinding) {
            Button("好") {
                editor.errorMessage = nil
                bluetooth.errorMessage = nil
            }
        } message: {
            Text(editor.errorMessage ?? bluetooth.errorMessage ?? "未知错误")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 58, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
                .padding(.bottom, 22)

            Text("为卡片选择一张图片")
                .font(.title2.weight(.semibold))
            Text("图片只在这台 iPhone 上处理，不会上传")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 7)

            Button {
                showPhotoPicker = true
            } label: {
                Label("选择照片", systemImage: "photo.on.rectangle")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 26)

            Menu {
                Button { showFileImporter = true } label: {
                    Label("从文件选择", systemImage: "folder")
                }
                Button(action: pasteImage) {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                }
            } label: {
                Text("其他导入方式")
                    .font(.subheadline)
            }
            .padding(.top, 14)
            Spacer()
            Text("支持 PNG、JPEG、HEIF 和 WebP")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 32)
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            PreviewCanvas(editor: editor)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)

            Divider()
            editorControls
        }
    }

    private var editorControls: some View {
        VStack(spacing: 14) {
            Picker("编辑工具", selection: $selectedPanel) {
                ForEach(EditorPanel.allCases) { panel in
                    Text(panel.title).tag(panel)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch selectedPanel {
                case .framing:
                    framingControls
                case .color:
                    colorControls
                }
            }
            .frame(minHeight: 86, alignment: .top)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.regularMaterial)
    }

    private var framingControls: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                Button { editor.rotateClockwise() } label: {
                    Label("向右旋转", systemImage: "rotate.right")
                }
                .buttonStyle(.bordered)

                Button { editor.resetFraming() } label: {
                    Label("还原", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

                Spacer()
                Text("\(editor.rotation)°")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { editor.zoom }, set: editor.setZoom),
                    in: 1 ... 4,
                    step: 0.01
                )
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Text(String(format: "%.2f×", editor.zoom))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private var colorControls: some View {
        VStack(spacing: 12) {
            Picker(
                "量化方式",
                selection: Binding(get: { editor.algorithm }, set: editor.setAlgorithm)
            ) {
                ForEach(DitherAlgorithm.allCases) { algorithm in
                    Text(shortTitle(for: algorithm)).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.algorithm.title)
                        .font(.subheadline.weight(.medium))
                    Text(editor.algorithm.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if editor.algorithm != .none {
                    Text("\(Int(editor.strength * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if editor.algorithm != .none {
                Slider(
                    value: Binding(
                        get: { Double(editor.strength) },
                        set: { editor.setStrength(Float($0)) }
                    ),
                    in: 0 ... 1.5,
                    step: 0.05
                )
            }
        }
    }

    private var sendBar: some View {
        VStack(spacing: 9) {
            if bluetooth.isSending {
                ProgressView(value: bluetooth.progress)
            }

            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Button(action: primaryAction) {
                    HStack(spacing: 6) {
                        if bluetooth.isSending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: bluetooth.isConnected ? "arrow.up" : "antenna.radiowaves.left.and.right")
                        }
                        Text(primaryButtonLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!editor.canSend || bluetooth.isSending)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 9)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var importMenu: some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label("照片", systemImage: "photo.on.rectangle")
            }
            Button { showFileImporter = true } label: {
                Label("文件", systemImage: "folder")
            }
            Button(action: pasteImage) {
                Label("粘贴", systemImage: "doc.on.clipboard")
            }
        } label: {
            Image(systemName: editor.sourceImage == nil ? "plus" : "photo.badge.plus")
        }
        .accessibilityLabel(editor.sourceImage == nil ? "导入图片" : "更换图片")
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { editor.errorMessage != nil || bluetooth.errorMessage != nil },
            set: { value in
                if !value {
                    editor.errorMessage = nil
                    bluetooth.errorMessage = nil
                }
            }
        )
    }

    private var primaryButtonLabel: String {
        if bluetooth.isSending { return "发送中" }
        return bluetooth.isConnected ? "发送" : "连接"
    }

    private var statusTitle: String {
        if editor.isProcessing { return "正在处理图片" }
        return bluetooth.statusText
    }

    private var statusDetail: String {
        if editor.isProcessing { return "生成六色预览与 Payload" }
        if let payload = editor.payload {
            return "\(payload.count.formatted()) 字节 · 528 × 792"
        }
        return "等待图片处理完成"
    }

    private var statusSymbol: String {
        if editor.isProcessing { return "wand.and.stars" }
        if bluetooth.statusText == "卡片屏幕刷新成功" { return "checkmark.circle.fill" }
        if bluetooth.isConnected { return "link.circle.fill" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if bluetooth.statusText == "卡片屏幕刷新成功" { return .green }
        return .blue
    }

    private func primaryAction() {
        guard let payload = editor.payload else { return }
        if bluetooth.isConnected {
            bluetooth.send(payload)
        } else {
            showDevicePicker = true
            bluetooth.beginDiscovery()
        }
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() else {
            editor.errorMessage = "剪贴板里没有可用的图片。"
            return
        }
        editor.loadImage(data: data)
    }

    private func shortTitle(for algorithm: DitherAlgorithm) -> String {
        switch algorithm {
        case .floydSteinberg: return "均衡"
        case .atkinson: return "柔和"
        case .orderedBayer: return "网点"
        case .none: return "纯色"
        }
    }
}

private struct PreviewCanvas: View {
    @ObservedObject var editor: EditorModel
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var pinchScale = 1.0

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * 2 / 3)
            let height = width * 3 / 2

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))

                ZStack {
                    Color.white
                    if let image = editor.previewImage ?? editor.sourceImage {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(editor.previewImage == nil ? .high : .none)
                            .scaledToFit()
                            .scaleEffect(pinchScale)
                            .offset(dragOffset)
                    }

                    if editor.isProcessing {
                        VStack {
                            HStack {
                                Spacer()
                                Label("处理中", systemImage: "wand.and.stars")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(10)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .padding(10)
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in state = value.translation }
                    .onEnded {
                        editor.applyDrag(
                            $0.translation,
                            in: CGSize(width: width - 20, height: height - 20)
                        )
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in state = value }
                    .onEnded { editor.setZoom(editor.zoom * $0) }
            )
            .accessibilityLabel("六色图片预览")
            .accessibilityHint("拖动调整位置，双指缩放")
        }
        .frame(minHeight: 220, idealHeight: 500)
    }
}

private struct DiagnosticsView: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var bluetooth: TodooBluetoothManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("图片") {
                    LabeledContent("输出尺寸", value: "528 × 792")
                    LabeledContent("Payload", value: editor.payload.map { "\($0.count.formatted()) 字节" } ?? "—")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SHA-256")
                        Text(editor.payloadSHA256)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section("设备") {
                    LabeledContent("厂商 / 屏幕", value: "0x5053 / 0x134C")
                    LabeledContent("连接", value: bluetooth.connectedDeviceName ?? "未连接")
                    LabeledContent("电量", value: bluetooth.batteryLevel.map { "\($0)%" } ?? "—")
                }

                Section("日志") {
                    if bluetooth.logs.isEmpty {
                        Text("暂无日志").foregroundStyle(.secondary)
                    } else {
                        Text(bluetooth.logs.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("诊断信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("复制") {
                        UIPasteboard.general.string = bluetooth.logs.joined(separator: "\n")
                    }
                    .disabled(bluetooth.logs.isEmpty)
                }
            }
        }
    }
}

private struct DevicePicker: View {
    @ObservedObject var bluetooth: TodooBluetoothManager
    let onSelect: (DiscoveredCard) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if bluetooth.devices.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            if bluetooth.isScanning { ProgressView() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bluetooth.isScanning ? "正在查找附近设备" : "没有找到兼容设备")
                                Text("请让 TodooCard 保持开机并靠近 iPhone")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section("附近设备") {
                        ForEach(bluetooth.devices) { device in
                            Button { onSelect(device) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                        .font(.title2)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).foregroundStyle(.primary)
                                        Text("固件 0x\(String(format: "%02X", device.firmwareVersion)) · RSSI \(device.rssi)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if device.pairingWindowOpen {
                                            Text("请先完成系统配对")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .disabled(device.pairingWindowOpen)
                        }
                    }
                }
            }
            .navigationTitle("选择 TodooCard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重新扫描") { bluetooth.beginDiscovery() }
                }
            }
        }
    }
}
