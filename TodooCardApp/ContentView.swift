import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if canImport(TodooCore)
  import TodooCore
#endif

struct ContentView: View {
  @StateObject private var editor = EditorModel()
  @StateObject private var bluetooth = TodooBluetoothManager()
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var selectedPhoto: PhotosPickerItem?
  @State private var showPhotoPicker = false
  @State private var showFileImporter = false
  @State private var showDevicePicker = false
  @State private var showDiagnostics = false
  @State private var showRemoveConfirmation = false
  @State private var isImporting = false

  var body: some View {
    NavigationStack {
      Group {
        if editor.sourceImage == nil {
          welcomeView
        } else {
          editorWorkspace
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(AppTheme.canvas.ignoresSafeArea())
      .navigationTitle(editor.sourceImage == nil ? "TodooCard" : "卡片预览")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { appToolbar }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if editor.sourceImage != nil {
          TransferDock(
            editor: editor,
            bluetooth: bluetooth,
            primaryAction: primaryAction,
            disconnect: bluetooth.disconnect
          )
        }
      }
    }
    .tint(AppTheme.accent)
    .overlay {
      if isImporting { ImportProgressOverlay() }
    }
    .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
    .onChange(of: selectedPhoto) { item in
      guard let item else { return }
      isImporting = true
      Task { await loadPhoto(item) }
    }
    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
      isImporting = true
      Task { await importFile(result) }
    }
    .sheet(isPresented: $showDevicePicker, onDismiss: bluetooth.stopDiscovery) {
      DevicePicker(bluetooth: bluetooth) { device in
        guard let payload = editor.payload else { return }
        showDevicePicker = false
        bluetooth.connectAndSend(deviceID: device.id, payload: payload)
      }
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
    }
    .sheet(isPresented: $showDiagnostics) {
      DiagnosticsView(editor: editor, bluetooth: bluetooth)
    }
    .alert("操作未完成", isPresented: errorBinding) {
      Button("查看诊断") {
        clearErrors()
        DispatchQueue.main.async { showDiagnostics = true }
      }
      Button("知道了", role: .cancel) { clearErrors() }
    } message: {
      Text(editor.errorMessage ?? bluetooth.errorMessage ?? "发生了未知错误。")
    }
    .confirmationDialog(
      "重新开始？",
      isPresented: $showRemoveConfirmation,
      titleVisibility: .visible
    ) {
      Button("移除当前图片", role: .destructive) { editor.clearImage() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("当前构图与显示效果设置将被清除。")
    }
    .onChange(of: bluetooth.statusText) { status in
      guard status.hasPrefix("发送成功") else { return }
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      UIAccessibility.post(notification: .announcement, argument: "图片已成功发送到卡片")
    }
  }

  @ToolbarContentBuilder
  private var appToolbar: some ToolbarContent {
    if editor.sourceImage != nil {
      ToolbarItem(placement: .navigationBarLeading) {
        Button {
          showRemoveConfirmation = true
        } label: {
          Image(systemName: "xmark")
        }
        .disabled(bluetooth.isBusy)
        .accessibilityLabel("关闭当前图片")
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      if editor.sourceImage != nil {
        importMenu.disabled(bluetooth.isBusy)
      }
      Button {
        showDiagnostics = true
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("诊断与设备信息")
    }
  }

  private var welcomeView: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 22) {
        HomeHeroArtwork()
          .frame(height: horizontalSizeClass == .regular ? 330 : 252)
          .accessibilityHidden(true)

        VStack(spacing: 12) {
          Button {
            showPhotoPicker = true
          } label: {
            Label("选择照片", systemImage: "photo.on.rectangle.angled")
              .font(.headline)
              .frame(maxWidth: .infinity)
              .frame(minHeight: 54)
          }
          .buttonStyle(FilledActionButtonStyle())
          .accessibilityHint("打开系统照片选择器")

          HStack(spacing: 12) {
            ImportOptionButton(title: "文件", systemImage: "folder") {
              showFileImporter = true
            }
            ImportOptionButton(title: "粘贴", systemImage: "doc.on.clipboard") {
              pasteImage()
            }
          }
        }

        if bluetooth.isConnected {
          ConnectedCallout(bluetooth: bluetooth, disconnect: bluetooth.disconnect)
        }

        PrivacyNote()
      }
      .frame(maxWidth: 560)
      .padding(.horizontal, 20)
      .padding(.top, 18)
      .padding(.bottom, 32)
      .frame(maxWidth: .infinity)
    }
  }

  private var editorWorkspace: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 16) {
        PreviewCanvas(editor: editor)
          .frame(height: horizontalSizeClass == .regular ? 560 : 414)
          .allowsHitTesting(!bluetooth.isBusy)

        HStack(spacing: 8) {
          Label(editor.algorithm.shortTitle, systemImage: editor.algorithm.systemImage)
          Spacer()
          if editor.isProcessing {
            ProgressView().controlSize(.small)
            Text("正在生成预览")
          } else {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(AppTheme.success)
            Text("528 × 792 · 已就绪")
          }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .animation(.easeInOut(duration: 0.2), value: editor.isProcessing)

        EditorControlPanel(editor: editor)
          .disabled(bluetooth.isBusy)
          .opacity(bluetooth.isBusy ? 0.62 : 1)
      }
      .frame(maxWidth: 680)
      .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 16)
      .padding(.top, 14)
      .padding(.bottom, 18)
      .frame(maxWidth: .infinity)
    }
  }

  private var importMenu: some View {
    Menu {
      Button {
        showPhotoPicker = true
      } label: {
        Label("从照片选择", systemImage: "photo.on.rectangle")
      }
      Button {
        showFileImporter = true
      } label: {
        Label("从文件选择", systemImage: "folder")
      }
      Button(action: pasteImage) {
        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
      }
    } label: {
      Image(systemName: "photo.badge.plus")
    }
    .accessibilityLabel("更换图片")
  }

  private var errorBinding: Binding<Bool> {
    Binding(
      get: { editor.errorMessage != nil || bluetooth.errorMessage != nil },
      set: { value in if !value { clearErrors() } }
    )
  }

  private func clearErrors() {
    editor.errorMessage = nil
    bluetooth.errorMessage = nil
  }

  private func primaryAction() {
    guard let payload = editor.payload else { return }
    if bluetooth.isConnected {
      bluetooth.send(payload)
    } else {
      bluetooth.beginDiscovery()
      if bluetooth.errorMessage == nil { showDevicePicker = true }
    }
  }

  @MainActor
  private func loadPhoto(_ item: PhotosPickerItem) async {
    defer { isImporting = false }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      editor.loadImage(data: data)
      selectedPhoto = nil
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } catch {
      selectedPhoto = nil
      editor.errorMessage = "读取照片失败：\(error.localizedDescription)"
    }
  }

  @MainActor
  private func importFile(_ result: Result<URL, Error>) async {
    defer { isImporting = false }
    do {
      let url = try result.get()
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      let data = try await Task.detached(priority: .userInitiated) {
        try Data(contentsOf: url)
      }.value
      editor.loadImage(data: data)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } catch {
      editor.errorMessage = "读取文件失败：\(error.localizedDescription)"
    }
  }

  private func pasteImage() {
    guard let image = UIPasteboard.general.image, let data = image.pngData() else {
      editor.errorMessage = "剪贴板里没有可用的图片。"
      return
    }
    editor.loadImage(data: data)
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}

// MARK: - Home

private struct ImportProgressOverlay: View {
  var body: some View {
    ZStack {
      Color.black.opacity(0.08)
        .ignoresSafeArea()
        .contentShape(Rectangle())

      HStack(spacing: 12) {
        ProgressView()
        Text("正在读取图片")
          .font(.subheadline.weight(.semibold))
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .shadow(color: AppTheme.shadow, radius: 18, y: 8)
    }
    .transition(.opacity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("正在读取图片")
  }
}

private struct HomeHeroArtwork: View {
  var body: some View {
    GeometryReader { proxy in
      let cardHeight = min(proxy.size.height * 0.86, proxy.size.width * 0.48 / 0.62)
      let cardWidth = cardHeight * 0.62
      let screenWidth = cardWidth * 0.86
      let screenHeight = screenWidth * 1.5

      ZStack {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
          .fill(AppTheme.warmPanel)

        Circle()
          .fill(AppTheme.eInkRed.opacity(0.1))
          .frame(width: proxy.size.height * 0.72)
          .offset(x: -proxy.size.width * 0.36, y: -proxy.size.height * 0.28)

        Circle()
          .fill(AppTheme.accent.opacity(0.1))
          .frame(width: proxy.size.height * 0.58)
          .offset(x: proxy.size.width * 0.38, y: proxy.size.height * 0.34)

        ZStack(alignment: .top) {
          RoundedRectangle(cornerRadius: cardWidth * 0.075, style: .continuous)
            .fill(AppTheme.deviceShell)
            .overlay {
              RoundedRectangle(cornerRadius: cardWidth * 0.075, style: .continuous)
                .stroke(Color.white.opacity(0.72), lineWidth: 1)
            }

          ScreenArtwork()
            .frame(width: screenWidth, height: screenHeight)
            .clipShape(RoundedRectangle(cornerRadius: cardWidth * 0.028, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: cardWidth * 0.028, style: .continuous)
                .stroke(Color.black.opacity(0.15), lineWidth: 1)
            }
            .padding(.top, cardHeight * 0.045)
        }
        .frame(width: cardWidth, height: cardHeight)
        .shadow(color: AppTheme.shadow, radius: 20, y: 12)
        .rotationEffect(.degrees(3.5))
      }
    }
  }
}

private struct ScreenArtwork: View {
  var body: some View {
    Canvas { context, size in
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: -size.width * 0.14,
            y: size.height * 0.06,
            width: size.width * 0.78,
            height: size.width * 0.78
          )),
        with: .color(AppTheme.eInkRed)
      )
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: size.width * 0.5,
            y: -size.height * 0.08,
            width: size.width * 0.7,
            height: size.height * 0.68
          )),
        with: .color(AppTheme.eInkBlue)
      )
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: -size.width * 0.3,
            y: size.height * 0.48,
            width: size.width * 1.02,
            height: size.height * 0.66
          )),
        with: .color(AppTheme.eInkGreen)
      )
      context.fill(
        Path(
          ellipseIn: CGRect(
            x: size.width * 0.57,
            y: size.height * 0.77,
            width: size.width * 0.36,
            height: size.width * 0.36
          )),
        with: .color(AppTheme.eInkYellow)
      )

      let dot = max(1.2, size.width * 0.018)
      for row in 0..<6 {
        for column in 0..<5 where (row + column) % 3 != 0 {
          let rect = CGRect(
            x: size.width * 0.62 + CGFloat(column) * dot * 1.55,
            y: size.height * 0.55 + CGFloat(row) * dot * 1.55,
            width: dot,
            height: dot
          )
          context.fill(Path(ellipseIn: rect), with: .color(AppTheme.eInkBlack.opacity(0.82)))
        }
      }
    }
    .background(AppTheme.paper)
  }
}

private struct ImportOptionButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }
    .buttonStyle(OutlinedActionButtonStyle())
  }
}

private struct PrivacyNote: View {
  var body: some View {
    Label("图片仅在本机处理", systemImage: "lock.fill")
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.top, 2)
  }
}

private struct ConnectedCallout: View {
  @ObservedObject var bluetooth: TodooBluetoothManager
  let disconnect: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(AppTheme.success.opacity(0.14))
        Image(systemName: "checkmark")
          .font(.caption.bold())
          .foregroundStyle(AppTheme.success)
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 2) {
        Text(bluetooth.connectedDeviceName ?? "TodooCard")
          .font(.subheadline.weight(.semibold))
        Text(bluetooth.batteryLevel.map { "已安全连接 · 电量 \($0)%" } ?? "已安全连接")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
      Button("断开", role: .destructive, action: disconnect)
        .font(.caption.weight(.semibold))
    }
    .padding(14)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

// MARK: - Editor

private struct PreviewCanvas: View {
  @ObservedObject var editor: EditorModel
  @GestureState private var gesture = CropGestureState()

  var body: some View {
    GeometryReader { proxy in
      let cardHeight = min(proxy.size.height * 0.96, proxy.size.width / 0.62)
      let cardWidth = cardHeight * 0.62
      let screenWidth = cardWidth * 0.86
      let screenHeight = screenWidth * 1.5
      let screenSize = CGSize(width: screenWidth, height: screenHeight)
      let interactiveZoom = min(4, max(1, editor.zoom * Double(gesture.magnification)))

      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: cardWidth * 0.075, style: .continuous)
          .fill(AppTheme.deviceShell)
          .overlay {
            RoundedRectangle(cornerRadius: cardWidth * 0.075, style: .continuous)
              .stroke(Color.white.opacity(0.72), lineWidth: 1)
          }

        ZStack {
          AppTheme.paper

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
              .interpolation(.high)
              .scaledToFill()
          }

          if editor.isProcessing && !gesture.isActive {
            HStack(spacing: 7) {
              ProgressView().controlSize(.small)
              Text("处理中").font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          }
        }
        .frame(width: screenWidth, height: screenHeight)
        .clipShape(RoundedRectangle(cornerRadius: cardWidth * 0.028, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: cardWidth * 0.028, style: .continuous)
            .stroke(Color.black.opacity(0.17), lineWidth: 1)
        }
        .padding(.top, cardHeight * 0.045)
        .contentShape(Rectangle())
        .gesture(cropGesture(in: screenSize))
      }
      .frame(width: cardWidth, height: cardHeight)
      .shadow(color: AppTheme.shadow, radius: 22, y: 12)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("TodooCard 六色屏幕预览")
      .accessibilityHint("拖动调整位置，双指缩放")
      .accessibilityValue(String(format: "缩放 %.1f 倍", editor.zoom))
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: editor.setZoom(editor.zoom * 1.25)
        case .decrement: editor.setZoom(editor.zoom / 1.25)
        @unknown default: break
        }
      }
      .accessibilityAction(named: "还原构图") { editor.resetFraming() }
    }
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

private struct EditorControlPanel: View {
  @ObservedObject var editor: EditorModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("显示效果", systemImage: "camera.filters")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text(editor.algorithm.guidance)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Picker(
          "显示效果",
          selection: Binding(get: { editor.algorithm }, set: editor.setAlgorithm)
        ) {
          ForEach(DitherAlgorithm.allCases) { algorithm in
            Text(algorithm.shortTitle).tag(algorithm)
          }
        }
        .pickerStyle(.segmented)

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("亮度补偿", systemImage: "sun.max")
              .font(.caption.weight(.semibold))
            Spacer()
            Text(
              editor.brightnessCompensation.formatted(
                .percent.precision(.fractionLength(0)).sign(strategy: .always())
              )
            )
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(AppTheme.accent)
          }

          Slider(
            value: Binding(
              get: { editor.brightnessCompensation },
              set: editor.setBrightnessCompensation
            ),
            in: -1...1,
            step: 0.05
          )
          .tint(AppTheme.accent)
          .accessibilityLabel("卡片亮度补偿")
          .accessibilityValue(
            editor.brightnessCompensation.formatted(
              .percent.precision(.fractionLength(0)).sign(strategy: .always())
            )
          )

          HStack {
            Text("更暗")
            Spacer()
            Text("原始")
            Spacer()
            Text("更亮")
          }
          .font(.caption2)
          .foregroundStyle(.tertiary)

          Text("实体屏偏灰偏暗时向右调高；预览和发送图片会同步更新。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Label("构图", systemImage: "crop")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Text(editor.zoom, format: .number.precision(.fractionLength(1)))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(AppTheme.accent)
          Text("×")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }

        HStack(spacing: 12) {
          EditorActionButton(title: "旋转", systemImage: "rotate.right") {
            editor.rotateClockwise()
          }

          Slider(
            value: Binding(get: { editor.zoom }, set: editor.setZoom),
            in: 1...4
          )
          .tint(AppTheme.accent)
          .accessibilityLabel("缩放")
          .accessibilityValue(String(format: "%.1f 倍", editor.zoom))

          EditorActionButton(
            title: "还原",
            systemImage: "arrow.counterclockwise",
            isEnabled: editor.hasFramingChanges
          ) {
            editor.resetFraming()
          }
        }

        Text("也可以直接拖动画面定位，或用双指缩放。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(18)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(AppTheme.hairline, lineWidth: 0.5)
    }
  }
}

private struct EditorActionButton: View {
  let title: String
  let systemImage: String
  var isEnabled = true
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 4) {
        Image(systemName: systemImage)
          .font(.body.weight(.semibold))
        Text(title)
          .font(.caption2.weight(.medium))
      }
      .frame(width: 52, height: 46)
      .background(AppTheme.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .buttonStyle(.plain)
    .foregroundStyle(isEnabled ? AppTheme.accent : Color.secondary)
    .opacity(isEnabled ? 1 : 0.45)
    .disabled(!isEnabled)
  }
}

private struct TransferDock: View {
  @ObservedObject var editor: EditorModel
  @ObservedObject var bluetooth: TodooBluetoothManager
  let primaryAction: () -> Void
  let disconnect: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        StatusMark(state: connectionState)

        VStack(alignment: .leading, spacing: 2) {
          Text(statusTitle)
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
          Text(statusSubtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        if bluetooth.isConnected && !bluetooth.isBusy {
          Menu {
            Button("断开连接", role: .destructive, action: disconnect)
          } label: {
            Image(systemName: "ellipsis")
              .frame(width: 34, height: 34)
              .background(AppTheme.controlFill, in: Circle())
          }
          .accessibilityLabel("连接选项")
        }
      }

      Button(action: primaryAction) {
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(buttonColor)

          if bluetooth.isSending {
            GeometryReader { proxy in
              Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: proxy.size.width * min(1, max(0, bluetooth.progress)))
            }
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .animation(.linear(duration: 0.16), value: bluetooth.progress)
          }

          HStack(spacing: 10) {
            if bluetooth.isBusy || editor.isProcessing {
              ProgressView().tint(.white)
            } else {
              Image(
                systemName: bluetooth.isConnected
                  ? "arrow.up.circle.fill" : "antenna.radiowaves.left.and.right"
              )
              .font(.body.weight(.semibold))
            }

            Text(primaryLabel)
              .font(.headline)

            Spacer()

            if bluetooth.isSending {
              Text(bluetooth.progress, format: .percent.precision(.fractionLength(0)))
                .font(.subheadline.monospacedDigit().weight(.bold))
            } else if !bluetooth.isBusy && !editor.isProcessing {
              Image(systemName: "chevron.right")
                .font(.caption.bold())
                .opacity(0.82)
            }
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 18)
        }
        .frame(height: 52)
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
      }
      .buttonStyle(PrimaryActionButtonStyle())
      .disabled(!buttonEnabled)
      .accessibilityValue(
        bluetooth.isSending
          ? bluetooth.progress.formatted(.percent.precision(.fractionLength(0)))
          : ""
      )
    }
    .padding(.horizontal, 16)
    .padding(.top, 11)
    .padding(.bottom, 8)
    .background(.ultraThinMaterial)
    .overlay(alignment: .top) { Divider() }
  }

  private var connectionState: StatusMark.State {
    if bluetooth.isBusy { return .working }
    if bluetooth.isConnected { return .connected }
    return .idle
  }

  private var statusTitle: String {
    if bluetooth.isBusy { return bluetooth.statusText }
    if bluetooth.isConnected { return bluetooth.connectedDeviceName ?? "TodooCard" }
    return "准备发送"
  }

  private var statusSubtitle: String {
    if bluetooth.isBusy {
      return bluetooth.isSending ? "请保持卡片靠近 iPhone" : "正在建立安全连接"
    }
    if bluetooth.isConnected {
      if bluetooth.statusText.hasPrefix("发送成功") {
        return bluetooth.batteryLevel.map { "上次发送成功 · 电量 \($0)%" } ?? "上次发送成功"
      }
      return bluetooth.batteryLevel.map { "安全连接 · 电量 \($0)%" } ?? "安全连接已就绪"
    }
    return "下一步将查找附近的 TodooCard"
  }

  private var primaryLabel: String {
    if bluetooth.isSending { return "正在发送" }
    if bluetooth.isBusy { return bluetooth.statusText }
    if editor.isProcessing { return "正在准备图片" }
    return bluetooth.isConnected ? "发送到卡片" : "选择设备并发送"
  }

  private var buttonEnabled: Bool {
    editor.canSend && !bluetooth.isBusy
  }

  private var buttonColor: Color {
    buttonEnabled || bluetooth.isBusy || editor.isProcessing
      ? AppTheme.accentStrong
      : AppTheme.disabledFill
  }
}

private struct StatusMark: View {
  enum State: Equatable { case idle, working, connected }
  let state: State

  var body: some View {
    ZStack {
      Circle().fill(color.opacity(0.14))
      if state == .working {
        ProgressView().controlSize(.small).tint(color)
      } else {
        Image(systemName: state == .connected ? "checkmark" : "bolt.horizontal")
          .font(.caption.bold())
          .foregroundStyle(color)
      }
    }
    .frame(width: 34, height: 34)
    .accessibilityHidden(true)
  }

  private var color: Color {
    switch state {
    case .idle, .working: return AppTheme.accent
    case .connected: return AppTheme.success
    }
  }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
  @ObservedObject var editor: EditorModel
  @ObservedObject var bluetooth: TodooBluetoothManager
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    NavigationStack {
      List {
        Section {
          HStack(spacing: 14) {
            ZStack {
              Circle().fill(statusColor.opacity(0.14))
              Image(systemName: statusSymbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(statusColor)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
              Text(bluetooth.statusText)
                .font(.headline)
              Text("诊断报告不包含原始图片内容")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 4)
        }

        Section("图片") {
          LabeledContent("输出尺寸", value: "528 × 792")
          LabeledContent("显示效果", value: editor.algorithm.shortTitle)
          LabeledContent(
            "亮度补偿",
            value: editor.brightnessCompensation.formatted(
              .percent.precision(.fractionLength(0)).sign(strategy: .always())
            )
          )
          LabeledContent(
            "Payload", value: editor.payload.map { "\($0.count.formatted()) 字节" } ?? "—")
          VStack(alignment: .leading, spacing: 6) {
            Text("SHA-256")
            Text(editor.payloadSHA256)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }

        Section("设备") {
          LabeledContent("连接", value: bluetooth.connectedDeviceName ?? "未连接")
          LabeledContent("电量", value: bluetooth.batteryLevel.map { "\($0)%" } ?? "—")
          LabeledContent("厂商 / 屏幕", value: "0x5053 / 0x134C")
        }

        Section("运行日志") {
          if bluetooth.logs.isEmpty {
            Label("暂无日志", systemImage: "doc.text")
              .foregroundStyle(.secondary)
          } else {
            Text(bluetooth.logs.joined(separator: "\n"))
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("诊断与设备")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("完成") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button(action: copyReport) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
          }
          .accessibilityLabel(copied ? "已复制诊断报告" : "复制诊断报告")
        }
      }
    }
    .tint(AppTheme.accent)
  }

  private var statusColor: Color {
    if bluetooth.errorMessage != nil { return .red }
    if bluetooth.isConnected { return AppTheme.success }
    return AppTheme.accent
  }

  private var statusSymbol: String {
    if bluetooth.errorMessage != nil { return "exclamationmark.triangle.fill" }
    if bluetooth.isConnected { return "checkmark.circle.fill" }
    return "antenna.radiowaves.left.and.right"
  }

  private var report: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    return """
      TodooCard 诊断报告
      App: \(version) (\(build))
      状态: \(bluetooth.statusText)
      图片: 528 × 792 / \(editor.algorithm.shortTitle) / 亮度 \(editor.brightnessCompensation.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())))
      Payload: \(editor.payload.map { "\($0.count) 字节" } ?? "—")
      SHA-256: \(editor.payloadSHA256)
      设备: \(bluetooth.connectedDeviceName ?? "未连接")
      电量: \(bluetooth.batteryLevel.map { "\($0)%" } ?? "—")

      日志:
      \(bluetooth.logs.isEmpty ? "暂无日志" : bluetooth.logs.joined(separator: "\n"))
      """
  }

  private func copyReport() {
    UIPasteboard.general.string = report
    copied = true
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { copied = false }
  }
}

// MARK: - Device discovery

private struct DevicePicker: View {
  @ObservedObject var bluetooth: TodooBluetoothManager
  let onSelect: (DiscoveredCard) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 18) {
          ScanHeader(isScanning: bluetooth.isScanning, deviceCount: bluetooth.devices.count)

          if bluetooth.devices.isEmpty {
            emptyState
          } else {
            VStack(spacing: 10) {
              ForEach(bluetooth.devices) { device in
                DeviceRow(device: device) { onSelect(device) }
              }
            }
          }

          PairingHelpCard()
        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity)
      }
      .background(AppTheme.canvas.ignoresSafeArea())
      .navigationTitle("选择卡片")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            bluetooth.beginDiscovery()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(bluetooth.isScanning)
          .accessibilityLabel("重新扫描")
        }
      }
    }
    .tint(AppTheme.accent)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      ZStack {
        Circle().fill(AppTheme.accent.opacity(0.1))
        if bluetooth.isScanning {
          ProgressView().tint(AppTheme.accent)
        } else {
          Image(systemName: "magnifyingglass")
            .font(.title2)
            .foregroundStyle(AppTheme.accent)
        }
      }
      .frame(width: 56, height: 56)

      Text(bluetooth.isScanning ? "正在查找附近的 TodooCard" : "没有找到兼容设备")
        .font(.headline)
      Text(bluetooth.isScanning ? "通常只需要几秒钟" : "确认卡片已开机并靠近 iPhone，然后重新扫描。")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if !bluetooth.isScanning {
        Button("重新扫描") { bluetooth.beginDiscovery() }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .padding(.top, 4)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 28)
    .padding(.horizontal, 18)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
  }
}

private struct ScanHeader: View {
  let isScanning: Bool
  let deviceCount: Int

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "antenna.radiowaves.left.and.right")
        .foregroundStyle(AppTheme.accent)
      Text(isScanning ? "正在扫描" : deviceCount > 0 ? "发现 \(deviceCount) 台设备" : "扫描已结束")
        .font(.subheadline.weight(.semibold))
      Spacer()
      if isScanning { ProgressView().controlSize(.small) }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
    .background(AppTheme.controlFill, in: Capsule())
  }
}

private struct DeviceRow: View {
  let device: DiscoveredCard
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        MiniCardDeviceIcon()

        VStack(alignment: .leading, spacing: 5) {
          Text(device.name)
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
          HStack(spacing: 6) {
            Label(signalLabel, systemImage: "cellularbars")
            Text("·")
            Text("固件 0x\(String(format: "%02X", device.firmwareVersion))")
          }
          .font(.caption)
          .foregroundStyle(.secondary)

          if device.pairingWindowOpen {
            Label("请先在系统蓝牙中完成配对", systemImage: "exclamationmark.circle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(.orange)
          }
        }

        Spacer(minLength: 8)

        Image(systemName: device.pairingWindowOpen ? "lock.fill" : "chevron.right")
          .font(.caption.weight(.bold))
          .foregroundStyle(device.pairingWindowOpen ? Color.orange : Color.secondary)
      }
      .padding(16)
      .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .stroke(AppTheme.hairline, lineWidth: 0.5)
      }
      .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(device.pairingWindowOpen)
    .opacity(device.pairingWindowOpen ? 0.72 : 1)
    .accessibilityHint(device.pairingWindowOpen ? "需要先完成系统配对" : "连接并发送图片")
  }

  private var signalLabel: String {
    if device.rssi >= -60 { return "信号很好" }
    if device.rssi >= -75 { return "信号良好" }
    return "信号较弱"
  }
}

private struct MiniCardDeviceIcon: View {
  private let width: CGFloat = 39
  private let height: CGFloat = 63

  var body: some View {
    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: 5.5, style: .continuous)
        .fill(AppTheme.deviceShell)

      ScreenArtwork()
        .frame(width: 32, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 2.2, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 2.2, style: .continuous)
            .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        }
        .padding(.top, 4.2)
    }
    .frame(width: width, height: height)
    .overlay {
      RoundedRectangle(cornerRadius: 5.5, style: .continuous)
        .stroke(Color.white.opacity(0.7), lineWidth: 0.7)
    }
    .shadow(color: AppTheme.shadow.opacity(0.55), radius: 5, y: 3)
    .accessibilityHidden(true)
  }
}

private struct PairingHelpCard: View {
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "info.circle.fill")
        .foregroundStyle(AppTheme.accent)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text("首次使用需要系统配对")
          .font(.subheadline.weight(.semibold))
        Text("如果设备显示“需要配对”，请先前往系统设置 › 蓝牙完成绑定，再回到这里重新扫描。")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(
      AppTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

// MARK: - Styling

private enum AppTheme {
  static let accent = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.48, green: 0.67, blue: 0.56, alpha: 1)
        : UIColor(red: 0.23, green: 0.38, blue: 0.32, alpha: 1)
    })
  static let accentStrong = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.24, green: 0.43, blue: 0.34, alpha: 1)
        : UIColor(red: 0.20, green: 0.34, blue: 0.28, alpha: 1)
    })
  static let canvas = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.055, green: 0.06, blue: 0.055, alpha: 1)
        : UIColor(red: 0.965, green: 0.957, blue: 0.94, alpha: 1)
    })
  static let surface = Color(uiColor: .secondarySystemBackground)
  static let controlFill = Color(uiColor: .tertiarySystemFill)
  static let disabledFill = Color(uiColor: .systemGray3)
  static let hairline = Color.primary.opacity(0.09)
  static let shadow = Color.black.opacity(0.14)
  static let success = Color(red: 0.24, green: 0.58, blue: 0.36)
  static let warmPanel = Color(
    uiColor: UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor(red: 0.14, green: 0.13, blue: 0.11, alpha: 1)
        : UIColor(red: 0.91, green: 0.86, blue: 0.78, alpha: 1)
    })
  static let deviceShell = Color(red: 0.84, green: 0.88, blue: 0.84)
  static let paper = Color(red: 0.92, green: 0.91, blue: 0.86)
  static let eInkBlack = Color(red: 0.08, green: 0.08, blue: 0.075)
  static let eInkRed = Color(red: 0.67, green: 0.27, blue: 0.20)
  static let eInkBlue = Color(red: 0.20, green: 0.37, blue: 0.51)
  static let eInkGreen = Color(red: 0.29, green: 0.45, blue: 0.35)
  static let eInkYellow = Color(red: 0.86, green: 0.61, blue: 0.18)
}

private struct FilledActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.white)
      .background(AppTheme.accentStrong, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.9 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct OutlinedActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(.primary)
      .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
          .stroke(AppTheme.hairline, lineWidth: 0.5)
      }
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.75 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .opacity(configuration.isPressed ? 0.92 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

extension DitherAlgorithm {
  fileprivate var shortTitle: String {
    switch self {
    case .floydSteinberg: return "均衡"
    case .atkinson: return "柔和"
    case .orderedBayer: return "网点"
    case .none: return "纯色"
    }
  }

  fileprivate var guidance: String {
    switch self {
    case .floydSteinberg: return "适合大多数照片"
    case .atkinson: return "颗粒更轻"
    case .orderedBayer: return "复古规则网点"
    case .none: return "干净的色块"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .floydSteinberg: return "circle.lefthalf.filled"
    case .atkinson: return "circle.dotted"
    case .orderedBayer: return "circle.grid.3x3.fill"
    case .none: return "square.fill"
    }
  }
}
