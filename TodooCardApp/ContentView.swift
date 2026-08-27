import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit
#if canImport(TodooCore)
import TodooCore
#endif

struct ContentView: View {
    @StateObject private var editor = EditorModel()
    @StateObject private var bluetooth = TodooBluetoothManager()
    @State private var selectedPhoto: PhotosPickerItem?
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
        ZStack(alignment: .bottom) {
            PreviewCanvas(editor: editor)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 74)

            editingToolbar
                .padding(.bottom, 16)
        }
    }

    private var editingToolbar: some View {
        HStack(spacing: 4) {
            Button { editor.rotateClockwise() } label: {
                Image(systemName: "rotate.right")
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("向右旋转")

            Divider()
                .frame(height: 22)

            Menu {
                Picker(
                    "显示效果",
                    selection: Binding(get: { editor.algorithm }, set: editor.setAlgorithm)
                ) {
                    ForEach(DitherAlgorithm.allCases) { algorithm in
                        Label(shortTitle(for: algorithm), systemImage: algorithmSymbol(for: algorithm))
                            .tag(algorithm)
                    }
                }
            } label: {
                Label(shortTitle(for: editor.algorithm), systemImage: "camera.filters")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 8)
                    .frame(height: 38)
            }

            if editor.hasFramingChanges {
                Divider()
                    .frame(height: 22)
                Button { editor.resetFraming() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 38, height: 38)
                }
                .accessibilityLabel("还原构图")
                .transition(.opacity.combined(with: .scale))
            }
        }
        .foregroundStyle(.primary)
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.18), value: editor.hasFramingChanges)
    }

    private var sendBar: some View {
        VStack(spacing: 10) {
            if bluetooth.isSending {
                ProgressView(value: bluetooth.progress)
                Text(bluetooth.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    if editor.isProcessing || bluetooth.isSending {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: bluetooth.isConnected ? "arrow.up" : "antenna.radiowaves.left.and.right")
                    }
                    Text(primaryButtonLabel)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!editor.canSend || bluetooth.isSending)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
        if editor.isProcessing { return "正在准备图片" }
        return bluetooth.isConnected ? "发送到 TodooCard" : "连接并发送"
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

    private func algorithmSymbol(for algorithm: DitherAlgorithm) -> String {
        switch algorithm {
        case .floydSteinberg: return "circle.lefthalf.filled"
        case .atkinson: return "circle.dotted"
        case .orderedBayer: return "circle.grid.3x3.fill"
        case .none: return "square.fill"
        }
    }
}

private struct PreviewCanvas: View {
    @ObservedObject var editor: EditorModel
    @GestureState private var gesture = CropGestureState()

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * 2 / 3)
            let height = width * 3 / 2
            let canvasSize = CGSize(width: width, height: height)
            let interactiveZoom = min(4, max(1, editor.zoom * Double(gesture.magnification)))

            ZStack {
                Color.white

                if let source = editor.sourceImage, gesture.isActive || editor.isProcessing {
                    SourceCropPreview(
                        image: source,
                        rotation: editor.rotation,
                        focusX: editor.focusX,
                        focusY: editor.focusY,
                        zoom: interactiveZoom,
                        translation: gesture.translation
                    )
                } else if let preview = editor.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                }

                if editor.isProcessing && !gesture.isActive {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            .contentShape(Rectangle())
            .gesture(cropGesture(in: canvasSize))
            .accessibilityLabel("六色图片预览")
            .accessibilityHint("拖动调整位置，双指缩放")
            .accessibilityValue(String(format: "缩放 %.1f 倍", editor.zoom))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: editor.setZoom(editor.zoom * 1.25)
                case .decrement: editor.setZoom(editor.zoom / 1.25)
                @unknown default: break
                }
            }
            .accessibilityAction(named: "还原构图") {
                editor.resetFraming()
            }
        }
        .frame(minHeight: 220, idealHeight: 500)
    }

    private func cropGesture(in viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .simultaneously(with: MagnificationGesture())
            .updating($gesture) { value, state, _ in
                state.isActive = true
                state.translation = value.first?.translation ?? .zero
                state.magnification = value.second ?? 1
            }
            .onEnded { value in
                editor.applyGesture(
                    translation: value.first?.translation ?? .zero,
                    magnification: Double(value.second ?? 1),
                    in: viewport
                )
            }
    }
}

private struct CropGestureState {
    var isActive = false
    var translation = CGSize.zero
    var magnification: CGFloat = 1
}

private struct SourceCropPreview: View {
    let image: UIImage
    let rotation: Int
    let focusX: Double
    let focusY: Double
    let zoom: Double
    let translation: CGSize

    var body: some View {
        GeometryReader { proxy in
            if let layout = try? computeCoverLayout(
                sourceWidth: image.size.width,
                sourceHeight: image.size.height,
                targetWidth: proxy.size.width,
                targetHeight: proxy.size.height,
                rotation: rotation,
                focusX: focusX,
                focusY: focusY,
                zoom: zoom
            ) {
                let cropX = min(layout.overflowX, max(0, layout.cropX - Double(translation.width)))
                let cropY = min(layout.overflowY, max(0, layout.cropY - Double(translation.height)))

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.drawWidth, height: layout.drawHeight)
                    .rotationEffect(.degrees(Double(rotation)))
                    .position(
                        x: -cropX + layout.rotatedDrawWidth / 2,
                        y: -cropY + layout.rotatedDrawHeight / 2
                    )
            }
        }
        .clipped()
        .allowsHitTesting(false)
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
