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
            ScrollView {
                VStack(spacing: 18) {
                    PreviewCanvas(editor: editor)

                    imageSourceButtons

                    if editor.sourceImage != nil {
                        framingCard
                        colorCard
                    }

                    sendCard
                    diagnosticsCard
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("TodooCard")
            .navigationBarTitleDisplayMode(.large)
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
                    await MainActor.run { editor.errorMessage = "读取照片失败：\(error.localizedDescription)" }
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
        .alert("提示", isPresented: errorBinding) {
            Button("好") {
                editor.errorMessage = nil
                bluetooth.errorMessage = nil
            }
        } message: {
            Text(editor.errorMessage ?? bluetooth.errorMessage ?? "未知错误")
        }
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

    private var imageSourceButtons: some View {
        HStack(spacing: 10) {
            sourceButton("照片", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
            sourceButton("文件", systemImage: "folder") { showFileImporter = true }
            sourceButton("粘贴", systemImage: "doc.on.clipboard") {
                guard let image = UIPasteboard.general.image,
                      let data = image.pngData() else {
                    editor.errorMessage = "剪贴板里没有可用的图片。"
                    return
                }
                editor.loadImage(data: data)
            }
        }
    }

    private func sourceButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var framingCard: some View {
        VStack(spacing: 16) {
            HStack {
                Label("画面", systemImage: "crop")
                    .font(.headline)
                Spacer()
                Button {
                    editor.rotateClockwise()
                } label: {
                    Label("旋转", systemImage: "rotate.right")
                }
                .buttonStyle(.borderless)
                Button("还原") { editor.resetFraming() }
                    .buttonStyle(.borderless)
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
        .cardStyle()
    }

    private var colorCard: some View {
        VStack(spacing: 14) {
            HStack {
                Label("六色成像", systemImage: "circle.hexagongrid.fill")
                    .font(.headline)
                Spacer()
                Picker("算法", selection: Binding(get: { editor.algorithm }, set: editor.setAlgorithm)) {
                    ForEach(DitherAlgorithm.allCases) { algorithm in
                        Text(algorithm.title).tag(algorithm)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Text(editor.algorithm.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if editor.algorithm != .none {
                    Text("强度 \(Int(editor.strength * 100))%")
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
        .cardStyle()
    }

    private var sendCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: statusSymbol)
                    .foregroundStyle(statusColor)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bluetooth.statusText)
                        .font(.subheadline.weight(.semibold))
                    if editor.isProcessing {
                        Text("正在生成实际六色 Payload")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let payload = editor.payload {
                        Text("\(payload.count.formatted()) 字节 · 528 × 792")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("选择图片后即可连接卡片")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if editor.isProcessing { ProgressView() }
            }

            if bluetooth.isSending {
                ProgressView(value: bluetooth.progress)
                    .tint(.blue)
            }

            Button(action: primaryAction) {
                HStack {
                    if bluetooth.isSending { ProgressView().tint(.white) }
                    Image(systemName: bluetooth.isConnected ? "arrow.up.circle.fill" : "dot.radiowaves.left.and.right")
                    Text(bluetooth.primaryButtonTitle)
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(editor.canSend && !bluetooth.isSending ? Color.blue : Color.gray, in: RoundedRectangle(cornerRadius: 15))
            .disabled(!editor.canSend || bluetooth.isSending)
        }
        .cardStyle()
    }

    private var diagnosticsCard: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 10) {
                diagnosticRow("厂商 / 屏幕", "0x5053 / 0x134C")
                diagnosticRow("电量", bluetooth.batteryLevel.map { "\($0)%" } ?? "—")
                diagnosticRow("Payload SHA-256", editor.payloadSHA256)
                if !bluetooth.logs.isEmpty {
                    Divider()
                    Text(bluetooth.logs.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 12)
        } label: {
            Label("诊断信息", systemImage: "stethoscope")
                .font(.headline)
        }
        .cardStyle()
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
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

    private var statusSymbol: String {
        if bluetooth.statusText == "卡片屏幕刷新成功" { return "checkmark.circle.fill" }
        if bluetooth.isConnected { return "link.circle.fill" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        bluetooth.statusText == "卡片屏幕刷新成功" ? .green : .blue
    }
}

private struct PreviewCanvas: View {
    @ObservedObject var editor: EditorModel
    @GestureState private var dragOffset = CGSize.zero
    @GestureState private var pinchScale = 1.0

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white
                if let image = editor.previewImage ?? editor.sourceImage {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(editor.previewImage == nil ? .high : .none)
                        .scaledToFit()
                        .scaleEffect(pinchScale)
                        .offset(dragOffset)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 38, weight: .light))
                        Text("选择一张图片")
                            .font(.headline)
                        Text("图片只在本机处理，不会上传")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if editor.isProcessing, editor.previewImage != nil {
                    VStack {
                        HStack {
                            Spacer()
                            ProgressView()
                                .padding(10)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in state = value.translation }
                    .onEnded { editor.applyDrag($0.translation, in: proxy.size) }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in state = value }
                    .onEnded { editor.setZoom(editor.zoom * $0) }
            )
        }
        .aspectRatio(CGFloat(CardDisplay.width) / CGFloat(CardDisplay.height), contentMode: .fit)
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 18, y: 7)
        .padding(.top, 4)
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
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(bluetooth.isScanning ? "正在查找附近的 TodooCard…" : "没有找到兼容设备")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(bluetooth.devices) { device in
                        Button { onSelect(device) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                                    .font(.title2)
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
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .disabled(device.pairingWindowOpen)
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

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
