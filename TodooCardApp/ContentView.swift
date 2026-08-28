import CoreMotion
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if canImport(TodooCore)
  import TodooCore
#endif

private enum DevicePickerPurpose {
  case connectAndSend
  case changeConnection
}

struct ContentView: View {
  @StateObject private var editor = EditorModel()
  @StateObject private var bluetooth = TodooBluetoothManager.shared
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  @State private var selectedPhoto: PhotosPickerItem?
  @State private var showPhotoPicker = false
  @State private var showFileImporter = false
  @State private var showDevicePicker = false
  @State private var showDiagnostics = false
  @State private var showRenameDevice = false
  @State private var deviceNameDraft = ""
  @State private var devicePickerPurpose = DevicePickerPurpose.connectAndSend
  @State private var isImporting = false
  @State private var importStatusText = "正在读取图片"

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
            renameDevice: beginRenamingDevice,
            changeDevice: { presentDevicePicker(for: .changeConnection) },
            disconnect: bluetooth.disconnect
          )
        }
      }
    }
    .tint(AppTheme.accent)
    .overlay {
      if isImporting { ImportProgressOverlay(message: importStatusText) }
    }
    .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
    .onChange(of: selectedPhoto) { item in
      guard let item else { return }
      importStatusText = "正在读取照片"
      isImporting = true
      Task { await loadPhoto(item) }
    }
    .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
      importStatusText = "正在读取文件"
      isImporting = true
      Task { await importFile(result) }
    }
    .sheet(isPresented: $showDevicePicker, onDismiss: bluetooth.stopDiscovery) {
      DevicePicker(bluetooth: bluetooth) { device in
        showDevicePicker = false
        switch devicePickerPurpose {
        case .connectAndSend:
          guard let payload = editor.payload else { return }
          bluetooth.connectAndSend(deviceID: device.id, payload: payload)
        case .changeConnection:
          bluetooth.connect(deviceID: device.id)
        }
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
    .alert("重命名设备", isPresented: $showRenameDevice) {
      TextField("设备名称", text: $deviceNameDraft)
      Button("取消", role: .cancel) {}
      Button("保存") {
        bluetooth.renameCurrentDevice(to: deviceNameDraft)
      }
      .disabled(deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("最多 24 个字符；名称仅保存在此 iPhone，不会修改设备固件或系统蓝牙名称。")
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
          editor.clearImage()
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
        HomeDeviceShowcase(bluetooth: bluetooth)
          .frame(height: horizontalSizeClass == .regular ? 330 : 252)

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

          Button(action: beginBingImport) {
            Label("获取 Bing 每日壁纸", systemImage: "globe.asia.australia.fill")
              .font(.subheadline.weight(.semibold))
              .frame(maxWidth: .infinity)
              .frame(minHeight: 48)
          }
          .buttonStyle(OutlinedActionButtonStyle())
          .accessibilityHint("下载今天的竖屏壁纸并打开卡片预览")
        }

        DeviceConnectionCallout(
          bluetooth: bluetooth,
          renameDevice: beginRenamingDevice,
          changeDevice: { presentDevicePicker(for: .changeConnection) },
          disconnect: bluetooth.disconnect
        )

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
      Button(action: beginBingImport) {
        Label("Bing 每日壁纸", systemImage: "globe.asia.australia.fill")
      }
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
    if bluetooth.sendToCurrentDevice(payload) { return }
    presentDevicePicker(for: .connectAndSend)
  }

  private func presentDevicePicker(for purpose: DevicePickerPurpose) {
    devicePickerPurpose = purpose
    bluetooth.beginDiscovery()
    if bluetooth.errorMessage == nil { showDevicePicker = true }
  }

  private func beginRenamingDevice() {
    deviceNameDraft = bluetooth.connectedDeviceName ?? "TodooCard"
    showRenameDevice = true
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

  private func beginBingImport() {
    importStatusText = "正在获取 Bing 每日壁纸"
    isImporting = true
    Task { await loadBingWallpaper() }
  }

  @MainActor
  private func loadBingWallpaper() async {
    defer { isImporting = false }
    do {
      let wallpaper = try await BingDailyWallpaperClient.fetchToday()
      editor.loadImage(data: wallpaper.data)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    } catch {
      editor.errorMessage = "获取 Bing 每日壁纸失败：\(error.localizedDescription)"
    }
  }

}

// MARK: - Home

private struct ImportProgressOverlay: View {
  let message: String

  var body: some View {
    ZStack {
      Color.black.opacity(0.08)
        .ignoresSafeArea()
        .contentShape(Rectangle())

      HStack(spacing: 12) {
        ProgressView()
        Text(message)
          .font(.subheadline.weight(.semibold))
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 16)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .shadow(color: AppTheme.shadow, radius: 18, y: 8)
    }
    .transition(.opacity)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(message)
  }
}

private struct HomeDeviceShowcase: View {
  @ObservedObject var bluetooth: TodooBluetoothManager
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var tilt = DeviceTiltMotion()

  /// 静止时也保留一点角度，让厚度与光影始终可见。
  private static let restingPitch = 5.5
  private static let restingYaw = -15.0

  var body: some View {
    GeometryReader { proxy in
      let cardAspectRatio = CGFloat(CardPhysicalSize.aspectRatio)
      let cardHeight = min(proxy.size.height * 0.82, proxy.size.width * 0.46 / cardAspectRatio)
      let cardWidth = cardHeight * cardAspectRatio
      let pitch = Self.restingPitch + tilt.pitch
      let yaw = Self.restingYaw + tilt.yaw
      let normal = CardPose.surfaceNormal(pitch: pitch, yaw: yaw)

      ZStack {
        RoundedRectangle(cornerRadius: 34, style: .continuous)
          .fill(AppTheme.warmPanel)

        Circle()
          .fill(AppTheme.eInkRed.opacity(0.1))
          .frame(width: proxy.size.height * 0.72)
          .offset(
            x: -proxy.size.width * 0.36 - normal.width * 18,
            y: -proxy.size.height * 0.28 - normal.height * 18
          )

        Circle()
          .fill(AppTheme.accent.opacity(0.1))
          .frame(width: proxy.size.height * 0.58)
          .offset(
            x: proxy.size.width * 0.38 - normal.width * 26,
            y: proxy.size.height * 0.34 - normal.height * 26
          )

        Ellipse()
          .fill(AppTheme.shadow.opacity(0.5))
          .frame(width: cardWidth * 1.06, height: cardHeight * 0.13)
          .blur(radius: 16)
          .offset(x: normal.width * 26, y: cardHeight * 0.53 - normal.height * 10)

        DeviceCard3D(
          size: CGSize(width: cardWidth, height: cardHeight),
          pitch: pitch,
          yaw: yaw,
          isDeviceKnown: bluetooth.hasCurrentDevice
        )

        VStack {
          Spacer()
          HStack {
            statusPill
            Spacer()
          }
        }
        .padding(14)
      }
    }
    .onAppear { syncMotion(isForeground: scenePhase == .active) }
    .onDisappear { tilt.stop() }
    .onChange(of: scenePhase) { phase in syncMotion(isForeground: phase == .active) }
    .onChange(of: reduceMotion) { _ in syncMotion(isForeground: scenePhase == .active) }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  private var statusPill: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
      Text(deviceName)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
      Text(statusWord)
        .font(.caption2)
        .foregroundStyle(.secondary)
      if let battery = bluetooth.batteryLevel, bluetooth.isConnected {
        Text("\(battery)%")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
  }

  private var deviceName: String {
    bluetooth.connectedDeviceName ?? "TodooCard"
  }

  private var statusWord: String {
    if bluetooth.isConnecting { return "连接中" }
    if bluetooth.isConnected { return "已连接" }
    if bluetooth.hasCurrentDevice { return "上次连接" }
    return "未连接"
  }

  private var statusColor: Color {
    if bluetooth.isConnected { return AppTheme.success }
    if bluetooth.isConnecting { return AppTheme.accent }
    return .secondary
  }

  private var accessibilityLabel: String {
    let battery = bluetooth.isConnected
      ? bluetooth.batteryLevel.map { "，电量 \($0)%" } ?? ""
      : ""
    return "\(deviceName) 立体预览，\(statusWord)\(battery)"
  }

  private func syncMotion(isForeground: Bool) {
    if isForeground && !reduceMotion {
      tilt.start()
    } else {
      tilt.stop()
    }
  }
}

/// 依据俯仰/偏航角推导卡片在屏幕坐标里的朝向与厚度位移。
/// SwiftUI 的 3D 旋转沿用图层坐标系（x 向右、y 向下、z 指向观察者）：
/// 绕 y 轴的正角度让右侧后退，绕 x 轴的正角度让顶部后退。
private enum CardPose {
  /// 正面法线在屏幕平面上的投影，用于驱动高光与阴影方向。
  static func surfaceNormal(pitch: Double, yaw: Double) -> CGSize {
    let pitchRadians = pitch * .pi / 180
    let yawRadians = yaw * .pi / 180
    return CGSize(
      width: CGFloat(sin(yawRadians)),
      height: CGFloat(-cos(yawRadians) * sin(pitchRadians))
    )
  }

  /// 背面相对正面的位移。除以余弦是为了抵消随后 3D 旋转带来的平面内压缩。
  static func depthOffset(pitch: Double, yaw: Double, depth: CGFloat) -> CGSize {
    let pitchRadians = pitch * .pi / 180
    let yawRadians = yaw * .pi / 180
    return CGSize(
      width: CGFloat(-sin(yawRadians)) * depth / CGFloat(max(0.4, cos(yawRadians))),
      height: CGFloat(sin(pitchRadians)) * depth / CGFloat(max(0.4, cos(pitchRadians)))
    )
  }
}

private struct DeviceCard3D: View {
  let size: CGSize
  let pitch: Double
  let yaw: Double
  let isDeviceKnown: Bool

  /// 3 mm 的真实厚度在这个尺寸下只有 1 pt 左右，略作夸张才能看出体积。
  private let depthExaggeration: CGFloat = 1.9

  var body: some View {
    let cornerRadius = size.width * CGFloat(CardPhysicalSize.cornerRadiusToWidthRatio)
    let thickness = size.width * CGFloat(CardPhysicalSize.thicknessToWidthRatio)
    let normal = CardPose.surfaceNormal(pitch: pitch, yaw: yaw)
    let depthOffset = CardPose.depthOffset(
      pitch: pitch,
      yaw: yaw,
      depth: thickness * depthExaggeration
    )

    ZStack {
      CardExtrusion(
        size: size,
        cornerRadius: cornerRadius,
        depthOffset: depthOffset,
        normal: normal
      )

      frontFace(cornerRadius: cornerRadius, normal: normal)
    }
    .frame(width: size.width, height: size.height)
    .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.42)
    .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.42)
    .shadow(
      color: AppTheme.shadow,
      radius: 22,
      x: normal.width * 16,
      y: 14 - normal.height * 12
    )
  }

  private func frontFace(cornerRadius: CGFloat, normal: CGSize) -> some View {
    let screenSideInset = size.width * CGFloat(CardPhysicalSize.displaySideInsetToWidthRatio)
    let screenTopInset = size.height * CGFloat(CardPhysicalSize.displayTopInsetToHeightRatio)
    let screenWidth = size.width - screenSideInset * 2
    let screenHeight = screenWidth / CGFloat(CardDisplay.aspectRatio)
    let screenCornerRadius = size.width * 0.028
    let lightAnchor = UnitPoint(
      x: min(1, max(0, 0.5 - Double(normal.width))),
      y: min(1, max(0, 0.3 - Double(normal.height)))
    )
    let shadowAnchor = UnitPoint(x: 1 - lightAnchor.x, y: 1 - lightAnchor.y)

    return ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(AppTheme.deviceShell)
        .overlay {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(
              LinearGradient(
                colors: [
                  Color.white.opacity(0.9),
                  Color.white.opacity(0.3),
                  Color.black.opacity(0.16),
                ],
                startPoint: lightAnchor,
                endPoint: shadowAnchor
              ),
              lineWidth: 1
            )
        }

      DeviceMatteTexture(cornerRadius: cornerRadius)

      ZStack {
        ScreenArtwork()
          .opacity(isDeviceKnown ? 1 : 0.35)
        if !isDeviceKnown {
          AppTheme.paper.opacity(0.55)
        }
        ScreenGlare(cornerRadius: screenCornerRadius, normal: normal)
      }
      .frame(width: screenWidth, height: screenHeight)
      .clipShape(RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
          .stroke(Color.black.opacity(0.15), lineWidth: 1)
      }
      .padding(.top, screenTopInset)

      CardSheen(cornerRadius: cornerRadius, normal: normal)
    }
    .frame(width: size.width, height: size.height)
  }
}

/// 把圆角卡片沿厚度方向堆叠若干层，得到没有缝隙、圆角也正确的侧边。
private struct CardExtrusion: View {
  let size: CGSize
  let cornerRadius: CGFloat
  let depthOffset: CGSize
  let normal: CGSize

  private let layerCount = 12

  var body: some View {
    let lightBoost = -Double(normal.width) * 0.06 - Double(normal.height) * 0.06

    ZStack {
      ForEach(0..<layerCount, id: \.self) { index in
        // index 0 是最深的一层，先绘制，随后逐层压在它上面。
        let depth = CGFloat(layerCount - index) / CGFloat(layerCount)
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(AppTheme.deviceEdgeTone(0.80 - Double(depth) * 0.34 + lightBoost))
          .frame(width: size.width, height: size.height)
          .offset(x: depthOffset.width * depth, y: depthOffset.height * depth)
      }
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
  }
}

/// 读取陀螺仪姿态，转换成卡片的轻微俯仰/偏航，使卡片看起来固定在空间中。
private final class DeviceTiltMotion: ObservableObject {
  @Published private(set) var pitch = 0.0
  @Published private(set) var yaw = 0.0

  private let manager = CMMotionManager()
  private var referenceAttitude: CMAttitude?
  private var isRunning = false

  private let maximumTilt = 9.0
  private let responsiveness = 0.7
  private let smoothing = 0.12
  private let minimumStep = 0.03

  func start() {
    guard !isRunning, manager.isDeviceMotionAvailable else { return }
    isRunning = true
    referenceAttitude = nil
    manager.deviceMotionUpdateInterval = 1.0 / 60.0
    manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
      guard let self, let motion else { return }
      self.consume(motion.attitude)
    }
  }

  func stop() {
    guard isRunning else { return }
    isRunning = false
    manager.stopDeviceMotionUpdates()
    referenceAttitude = nil
    withAnimation(.easeOut(duration: 0.45)) {
      pitch = 0
      yaw = 0
    }
  }

  private func consume(_ attitude: CMAttitude) {
    guard let relative = attitude.copy() as? CMAttitude else { return }
    guard let referenceAttitude else {
      // 第一帧作为基准，用户无论以什么姿势拿着手机，卡片都从正面开始。
      self.referenceAttitude = relative
      return
    }
    relative.multiply(byInverseOf: referenceAttitude)

    let rollDegrees = relative.roll * 180 / .pi
    let pitchDegrees = relative.pitch * 180 / .pi
    // 卡片跟随手机的姿态一起转，倾斜时像是在从新的角度打量它。
    // 真机实测确认过方向：这两个符号一起决定观感，反过来会变成卡片朝相反方向躲。
    let targetYaw = clamped(rollDegrees * responsiveness)
    let targetPitch = clamped(-pitchDegrees * responsiveness)
    let nextYaw = yaw + (targetYaw - yaw) * smoothing
    let nextPitch = pitch + (targetPitch - pitch) * smoothing

    if abs(nextYaw - yaw) > minimumStep { yaw = nextYaw }
    if abs(nextPitch - pitch) > minimumStep { pitch = nextPitch }
  }

  private func clamped(_ value: Double) -> Double {
    min(maximumTilt, max(-maximumTilt, value))
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

private struct PrivacyNote: View {
  var body: some View {
    Label("图片仅在本机处理", systemImage: "lock.fill")
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .padding(.top, 2)
  }
}

private struct DeviceConnectionCallout: View {
  @ObservedObject var bluetooth: TodooBluetoothManager
  let renameDevice: () -> Void
  let changeDevice: () -> Void
  let disconnect: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(statusColor.opacity(0.14))
        if bluetooth.isConnecting {
          ProgressView()
            .controlSize(.small)
            .tint(statusColor)
        } else {
          Image(systemName: bluetooth.isConnected ? "checkmark" : "bolt.horizontal")
            .font(.caption.bold())
            .foregroundStyle(statusColor)
        }
      }
      .frame(width: 34, height: 34)

      VStack(alignment: .leading, spacing: 2) {
        Text(statusTitle)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        Text(statusSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Spacer()
      if bluetooth.hasCurrentDevice {
        Menu {
          Button(action: renameDevice) {
            Label("重命名设备", systemImage: "pencil")
          }
          Button(action: changeDevice) {
            Label("更改连接设备", systemImage: "arrow.triangle.2.circlepath")
          }
          Button(role: .destructive, action: disconnect) {
            Label("断开连接", systemImage: "xmark.circle")
          }
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 34, height: 34)
            .background(AppTheme.controlFill, in: Circle())
        }
        .accessibilityLabel("设备连接选项")
      } else {
        Button("连接", action: changeDevice)
          .font(.caption.weight(.semibold))
      }
    }
    .padding(14)
    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var statusColor: Color {
    if bluetooth.isConnected { return AppTheme.success }
    if bluetooth.isConnecting { return AppTheme.accent }
    return .secondary
  }

  private var statusTitle: String {
    if bluetooth.hasCurrentDevice {
      return bluetooth.connectedDeviceName ?? "TodooCard"
    }
    return "设备未连接"
  }

  private var statusSubtitle: String {
    if bluetooth.isConnecting { return bluetooth.statusText }
    if bluetooth.isConnected {
      return bluetooth.batteryLevel.map { "已安全连接 · 电量 \($0)%" } ?? "已安全连接"
    }
    if bluetooth.hasCurrentDevice {
      return bluetooth.statusText == "未连接" ? "等待重新连接" : bluetooth.statusText
    }
    if bluetooth.statusText != "未连接" { return bluetooth.statusText }
    return "选择图片后即可连接 TodooCard"
  }
}

// MARK: - Card rendering

private struct DeviceMatteTexture: View {
  let cornerRadius: CGFloat

  var body: some View {
    Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: false) { context, size in
      let spacing = max(3, size.width / 38)
      let grain = max(0.45, size.width / 420)
      let columns = max(1, Int(ceil(size.width / spacing)))
      let rows = max(1, Int(ceil(size.height / spacing)))

      for row in 0 ... rows {
        for column in 0 ... columns {
          let seed = (row * 73_856_093) ^ (column * 19_349_663)
          let jitterX = CGFloat(seed % 101) / 100 - 0.5
          let jitterY = CGFloat((seed / 101) % 103) / 102 - 0.5
          let diameter = grain * (0.72 + CGFloat((seed / 10_403) % 7) * 0.06)
          let origin = CGPoint(
            x: CGFloat(column) * spacing + spacing / 2 + jitterX * spacing * 0.52,
            y: CGFloat(row) * spacing + spacing / 2 + jitterY * spacing * 0.52
          )
          let rect = CGRect(
            x: origin.x - diameter / 2,
            y: origin.y - diameter / 2,
            width: diameter,
            height: diameter
          )
          let color = seed.isMultiple(of: 3)
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.045)
          context.fill(Path(ellipseIn: rect), with: .color(color))
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .blendMode(.softLight)
    .opacity(0.78)
    .allowsHitTesting(false)
  }
}

/// 依据卡片法线放置的柔和高光，倾斜时在外壳上扫过。
private struct CardSheen: View {
  let cornerRadius: CGFloat
  let normal: CGSize

  var body: some View {
    GeometryReader { proxy in
      let center = UnitPoint(
        x: min(1.3, max(-0.3, 0.5 - Double(normal.width) * 1.4)),
        y: min(1.3, max(-0.3, 0.32 - Double(normal.height) * 1.4))
      )
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(
          RadialGradient(
            gradient: Gradient(colors: [
              Color.white.opacity(0.85),
              Color.white.opacity(0.2),
              Color.black.opacity(0.24),
            ]),
            center: center,
            startRadius: 0,
            endRadius: max(proxy.size.width, proxy.size.height) * 0.95
          )
        )
        .blendMode(.softLight)
    }
    .allowsHitTesting(false)
  }
}

/// 屏幕前盖上的一道反光，随倾斜左右移动。
private struct ScreenGlare: View {
  let cornerRadius: CGFloat
  let normal: CGSize

  var body: some View {
    let position = min(0.88, max(0.08, 0.44 - Double(normal.width) * 0.6))

    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(
        LinearGradient(
          gradient: Gradient(stops: [
            .init(color: Color.white.opacity(0), location: 0),
            .init(color: Color.white.opacity(0.34), location: position),
            .init(color: Color.white.opacity(0), location: 1),
          ]),
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .blendMode(.softLight)
      .allowsHitTesting(false)
  }
}

// MARK: - Editor

private struct PreviewCanvas: View {
  @ObservedObject var editor: EditorModel
  @GestureState private var cropState = CropGestureState()

  var body: some View {
    GeometryReader { proxy in
      let cardAspectRatio = CGFloat(CardPhysicalSize.aspectRatio)
      let screenAspectRatio = CGFloat(CardDisplay.aspectRatio)
      let cardHeight = min(proxy.size.height * 0.96, proxy.size.width / cardAspectRatio)
      let cardWidth = cardHeight * cardAspectRatio
      let cardCornerRadius = cardWidth * CGFloat(CardPhysicalSize.cornerRadiusToWidthRatio)
      let screenSideInset = cardWidth * CGFloat(CardPhysicalSize.displaySideInsetToWidthRatio)
      let screenTopInset = cardHeight * CGFloat(CardPhysicalSize.displayTopInsetToHeightRatio)
      let screenWidth = cardWidth - screenSideInset * 2
      let screenHeight = screenWidth / screenAspectRatio
      let screenSize = CGSize(width: screenWidth, height: screenHeight)
      let screenCornerRadius = cardWidth * 0.028
      let interactiveZoom = min(4, max(1, editor.zoom * Double(cropState.magnification)))

      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
          .fill(AppTheme.deviceShell)
          .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
              .stroke(Color.white.opacity(0.72), lineWidth: 1)
          }

        DeviceMatteTexture(cornerRadius: cardCornerRadius)

        ZStack {
          AppTheme.paper

          if let source = editor.sourceImage, cropState.isActive || editor.isProcessing {
            SourceCropPreview(
              image: source,
              rotation: editor.rotation,
              focusX: editor.focusX,
              focusY: editor.focusY,
              zoom: interactiveZoom,
              translation: cropState.translation
            )
          } else if let preview = editor.previewImage {
            Image(uiImage: preview)
              .resizable()
              .interpolation(.high)
              .scaledToFill()
          }

          if editor.isProcessing && !cropState.isActive {
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
        .clipShape(RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
            .stroke(Color.black.opacity(0.17), lineWidth: 1)
        }
        .padding(.top, screenTopInset)
        .contentShape(Rectangle())
        .gesture(cropGesture(in: screenSize))
      }
      .frame(width: cardWidth, height: cardHeight)
      .shadow(color: AppTheme.shadow, radius: 22, y: 12)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("TodooCard 六色屏幕预览")
      .accessibilityHint("在屏幕内拖动调整图片，双指缩放")
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
      .updating($cropState) { value, state, _ in
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

        Text("画面内拖动可定位；在机身边框或空白区域左右滑动可翻转设备。")
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
  let renameDevice: () -> Void
  let changeDevice: () -> Void
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

        if bluetooth.hasCurrentDevice && !bluetooth.isBusy {
          Menu {
            Button(action: renameDevice) {
              Label("重命名设备", systemImage: "pencil")
            }
            Button(action: changeDevice) {
              Label("更改连接设备", systemImage: "arrow.triangle.2.circlepath")
            }
            Button(role: .destructive, action: disconnect) {
              Label("断开连接", systemImage: "xmark.circle")
            }
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
    if bluetooth.isConnecting { return .working }
    return .idle
  }

  private var statusTitle: String {
    if bluetooth.isBusy { return bluetooth.statusText }
    if bluetooth.isConnected { return bluetooth.connectedDeviceName ?? "TodooCard" }
    if bluetooth.hasCurrentDevice { return bluetooth.connectedDeviceName ?? "TodooCard" }
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
    if bluetooth.hasCurrentDevice {
      return bluetooth.isConnecting ? bluetooth.statusText : "发送时将自动连接当前设备"
    }
    return "下一步将查找附近的 TodooCard"
  }

  private var primaryLabel: String {
    if bluetooth.isSending { return "正在发送" }
    if bluetooth.isBusy { return bluetooth.statusText }
    if editor.isProcessing { return "正在准备图片" }
    return bluetooth.hasCurrentDevice ? "发送到当前设备" : "选择设备并发送"
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
          LabeledContent("当前设备", value: bluetooth.connectedDeviceName ?? "未选择")
          LabeledContent("连接", value: connectionDescription)
          LabeledContent("电量", value: bluetooth.batteryLevel.map { "\($0)%" } ?? "—")
          LabeledContent(
            "自动发送设备",
            value: bluetooth.rememberedAutomationDeviceName ?? "未设置（先手动发送一次）"
          )
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

  private var connectionDescription: String {
    if bluetooth.isConnected { return "已连接" }
    if bluetooth.isConnecting { return "正在连接" }
    return "未连接"
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
                DeviceRow(
                  device: device,
                  isCurrent: bluetooth.currentDeviceIdentifier == device.id
                ) { onSelect(device) }
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
  let isCurrent: Bool
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
          } else if isCurrent {
            Label("当前设备", systemImage: "checkmark.circle.fill")
              .font(.caption.weight(.medium))
              .foregroundStyle(AppTheme.success)
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
    .accessibilityHint(device.pairingWindowOpen ? "需要先完成系统配对" : "选择并连接此设备")
  }

  private var signalLabel: String {
    if device.rssi >= -60 { return "信号很好" }
    if device.rssi >= -75 { return "信号良好" }
    return "信号较弱"
  }
}

private struct MiniCardDeviceIcon: View {
  private let width: CGFloat = 39

  var body: some View {
    let height = width / CGFloat(CardPhysicalSize.aspectRatio)
    let cornerRadius = width * CGFloat(CardPhysicalSize.cornerRadiusToWidthRatio)
    let screenSideInset = width * CGFloat(CardPhysicalSize.displaySideInsetToWidthRatio)
    let screenTopInset = height * CGFloat(CardPhysicalSize.displayTopInsetToHeightRatio)
    let screenWidth = width - screenSideInset * 2
    let screenHeight = screenWidth / CGFloat(CardDisplay.aspectRatio)

    ZStack(alignment: .top) {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(AppTheme.deviceShell)

      DeviceMatteTexture(cornerRadius: cornerRadius)

      ScreenArtwork()
        .frame(width: screenWidth, height: screenHeight)
        .clipShape(RoundedRectangle(cornerRadius: 2.2, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 2.2, style: .continuous)
            .stroke(Color.black.opacity(0.18), lineWidth: 0.5)
        }
        .padding(.top, screenTopInset)
    }
    .frame(width: width, height: height)
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
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
  /// 卡片侧边的明暗过渡：0.30 是最深的背面，0.94 是被光打亮的正面棱边。
  static func deviceEdgeTone(_ level: Double) -> Color {
    let value = min(0.94, max(0.30, level))
    return Color(red: value * 0.923, green: value, blue: value * 0.938)
  }
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
