import AppIntents
import Foundation
import UIKit

struct UpdateTodooCardIntent: AppIntent {
  static let title: LocalizedStringResource = "自动更新 TodooCard"
  static let description = IntentDescription(
    "在后台导入一张图片，使用默认显示效果生成卡片内容，并自动发送到上次成功使用的 TodooCard。"
  )
  static let openAppWhenRun = false

  @Parameter(
    title: "图片",
    description: "要显示在 TodooCard 上的图片",
    supportedTypeIdentifiers: ["public.image"]
  )
  var image: IntentFile

  @Parameter(title: "旋转", default: .degrees0)
  var rotation: ShortcutRotation

  @Parameter(
    title: "缩放百分比",
    description: "100–400；图片按比例铺满后继续放大",
    default: 100,
    controlStyle: .field,
    inclusiveRange: (100, 400)
  )
  var zoomPercent: Int

  @Parameter(
    title: "水平焦点",
    description: "0 为最左，50 为居中，100 为最右",
    default: 50,
    controlStyle: .field,
    inclusiveRange: (0, 100)
  )
  var focusXPercent: Int

  @Parameter(
    title: "垂直焦点",
    description: "0 为最上，50 为居中，100 为最下",
    default: 50,
    controlStyle: .field,
    inclusiveRange: (0, 100)
  )
  var focusYPercent: Int

  @Parameter(title: "显示效果", default: .floydSteinberg)
  var algorithm: ShortcutDitherAlgorithm

  @Parameter(
    title: "抖动强度",
    description: "0–150%，默认 100%",
    default: 100,
    controlStyle: .field,
    inclusiveRange: (0, 150)
  )
  var strengthPercent: Int

  @Parameter(
    title: "亮度补偿",
    description: "-100%–100%，默认 0%",
    default: 0,
    controlStyle: .field,
    inclusiveRange: (-100, 100)
  )
  var brightnessPercent: Int

  static var parameterSummary: some ParameterSummary {
    Summary("用 TodooCard 自动发送 \(\.$image)") {
      \.$rotation
      \.$zoomPercent
      \.$focusXPercent
      \.$focusYPercent
      \.$algorithm
      \.$strengthPercent
      \.$brightnessPercent
    }
  }

  func perform() async throws -> some IntentResult {
    let imageData = image.data
    let configuration = AutomaticImageConfiguration(
      rotation: rotation.degrees,
      focusX: Double(focusXPercent),
      focusY: Double(focusYPercent),
      zoom: Double(zoomPercent) / 100,
      algorithm: algorithm.coreValue,
      strength: Float(strengthPercent) / 100,
      brightnessCompensation: Float(brightnessPercent) / 100
    )
    let processed = try await Task.detached(priority: .userInitiated) {
      try AutomaticImageProcessor.process(imageData, configuration: configuration)
    }.value

    let bluetooth = await TodooBluetoothManager.shared
    try await bluetooth.sendAutomaticallyAndWait(processed.payload)
    DeviceScreenSnapshot.save(processed.preview)
    RecentSendStore.record(
      sourceData: imageData,
      configuration: configuration,
      preview: processed.preview,
      payload: processed.payload
    )
    return .result()
  }
}

struct SendBingDailyWallpaperIntent: AppIntent {
  static let title: LocalizedStringResource = "发送 Bing 每日壁纸"
  static let description = IntentDescription(
    "获取 Bing 今日的 1080 × 1920 竖屏壁纸，生成卡片内容并自动发送到上次成功使用的 TodooCard。"
  )
  static let openAppWhenRun = false

  @Parameter(title: "显示效果", default: .floydSteinberg)
  var algorithm: ShortcutDitherAlgorithm

  @Parameter(
    title: "抖动强度",
    description: "0–150%，默认 100%",
    default: 100,
    controlStyle: .field,
    inclusiveRange: (0, 150)
  )
  var strengthPercent: Int

  @Parameter(
    title: "亮度补偿",
    description: "-100%–100%，默认 0%",
    default: 0,
    controlStyle: .field,
    inclusiveRange: (-100, 100)
  )
  var brightnessPercent: Int

  static var parameterSummary: some ParameterSummary {
    Summary("获取并发送 Bing 每日壁纸") {
      \.$algorithm
      \.$strengthPercent
      \.$brightnessPercent
    }
  }

  func perform() async throws -> some IntentResult {
    let wallpaper = try await BingDailyWallpaperClient.fetchToday()
    let configuration = AutomaticImageConfiguration(
      rotation: 0,
      focusX: 50,
      focusY: 50,
      zoom: 1,
      algorithm: algorithm.coreValue,
      strength: Float(strengthPercent) / 100,
      brightnessCompensation: Float(brightnessPercent) / 100
    )
    let processed = try await Task.detached(priority: .userInitiated) {
      try AutomaticImageProcessor.process(
        wallpaper.data,
        configuration: configuration
      )
    }.value

    let bluetooth = await TodooBluetoothManager.shared
    try await bluetooth.sendAutomaticallyAndWait(processed.payload)
    DeviceScreenSnapshot.save(processed.preview)
    RecentSendStore.record(
      sourceData: wallpaper.data,
      configuration: configuration,
      preview: processed.preview,
      payload: processed.payload
    )
    return .result()
  }
}

struct SendHealthSummaryIntent: AppIntent {
  static let title: LocalizedStringResource = "发送今日健康摘要"
  static let description = IntentDescription(
    "读取「健康」中今天的活动圆环、睡眠、步数与静息心率，排版成一张卡片并自动发送到上次成功使用的 TodooCard。"
  )
  static let openAppWhenRun = false

  @Parameter(title: "显示效果", default: ShortcutDitherAlgorithm.none)
  var algorithm: ShortcutDitherAlgorithm

  @Parameter(
    title: "亮度补偿",
    description: "-100%–100%，默认 0%",
    default: 0,
    controlStyle: .field,
    inclusiveRange: (-100, 100)
  )
  var brightnessPercent: Int

  static var parameterSummary: some ParameterSummary {
    Summary("生成并发送今日健康摘要") {
      \.$algorithm
      \.$brightnessPercent
    }
  }

  func perform() async throws -> some IntentResult {
    // 后台运行时弹不出授权窗口；已经在 App 里授权过就直接读，没授权过让下面的读取报错，
    // 由错误信息提示用户先打开一次 App。
    try? await HealthSummaryReader.requestAuthorization()
    let snapshot = try await HealthSummaryReader.fetchToday()
    let cardData = try HealthCardRenderer.renderPNG(snapshot)
    let configuration = AutomaticImageConfiguration(
      rotation: 0,
      focusX: 50,
      focusY: 50,
      zoom: 1,
      algorithm: algorithm.coreValue,
      // 纯色排版不需要抖动，强度固定 100% 只是让最近色量化按原样走。
      strength: 1,
      brightnessCompensation: Float(brightnessPercent) / 100
    )
    let processed = try await Task.detached(priority: .userInitiated) {
      try AutomaticImageProcessor.process(cardData, configuration: configuration)
    }.value

    let bluetooth = await TodooBluetoothManager.shared
    try await bluetooth.sendAutomaticallyAndWait(processed.payload)
    DeviceScreenSnapshot.save(processed.preview)
    RecentSendStore.record(
      sourceData: cardData,
      configuration: configuration,
      preview: processed.preview,
      payload: processed.payload
    )
    return .result()
  }
}

/// 免费 Apple Account 用 SideStore 重签名后拿不到 HealthKit 权限，App 自己读不了健康数据。
/// 这个动作把取数交给「快捷指令」App——它自己有权限——这里只负责排版和发送，
/// 全程不碰 HealthKit API，因此不需要那项权限。
struct SendHealthSummaryFromShortcutIntent: AppIntent {
  static let title: LocalizedStringResource = "发送健康摘要（数据由快捷指令提供）"
  static let description = IntentDescription(
    "用快捷指令「查找健康样本」取到的数值排版成健康摘要卡片并发送。适合无法授予 TodooCard 健康权限的安装方式；填几项就画几项。"
  )
  static let openAppWhenRun = false

  @Parameter(title: "活动能量（千卡）", controlStyle: .field)
  var moveKilocalories: Double?

  @Parameter(title: "活动目标（千卡）", controlStyle: .field)
  var moveGoal: Double?

  @Parameter(title: "锻炼时间（分钟）", controlStyle: .field)
  var exerciseMinutes: Double?

  @Parameter(title: "锻炼目标（分钟）", controlStyle: .field)
  var exerciseGoal: Double?

  @Parameter(title: "站立小时数", description: "站立目标固定为 12 小时", controlStyle: .field)
  var standHours: Double?

  @Parameter(title: "步数", controlStyle: .field)
  var steps: Double?

  @Parameter(title: "静息心率（次/分）", controlStyle: .field)
  var restingHeartRate: Double?

  @Parameter(title: "睡眠时长（分钟）", controlStyle: .field)
  var sleepMinutes: Double?

  @Parameter(title: "清醒时长（分钟）", controlStyle: .field)
  var awakeMinutes: Double?

  static var parameterSummary: some ParameterSummary {
    Summary("把健康数据排版成卡片并发送") {
      \.$moveKilocalories
      \.$moveGoal
      \.$exerciseMinutes
      \.$exerciseGoal
      \.$standHours
      \.$steps
      \.$restingHeartRate
      \.$sleepMinutes
      \.$awakeMinutes
    }
  }

  func perform() async throws -> some IntentResult {
    let snapshot = makeSnapshot()
    guard snapshot.hasAnyData else { throw HealthSummaryError.noShortcutInput }
    let cardData = try HealthCardRenderer.renderPNG(snapshot)
    let configuration = AutomaticImageConfiguration(
      rotation: 0,
      focusX: 50,
      focusY: 50,
      zoom: 1,
      algorithm: DitherAlgorithm.none,
      strength: 1,
      brightnessCompensation: 0
    )
    let processed = try await Task.detached(priority: .userInitiated) {
      try AutomaticImageProcessor.process(cardData, configuration: configuration)
    }.value

    let bluetooth = await TodooBluetoothManager.shared
    try await bluetooth.sendAutomaticallyAndWait(processed.payload)
    DeviceScreenSnapshot.save(processed.preview)
    RecentSendStore.record(
      sourceData: cardData,
      configuration: configuration,
      preview: processed.preview,
      payload: processed.payload
    )
    return .result()
  }

  private func makeSnapshot() -> HealthSummarySnapshot {
    HealthSummarySnapshot(
      generatedAt: Date(),
      move: ring(moveKilocalories, goal: moveGoal),
      exercise: ring(exerciseMinutes, goal: exerciseGoal),
      // 站立目标在「健身记录」里固定为 12 小时，用户改不了，不必再占一个参数。
      stand: ring(standHours, goal: 12),
      usesMoveTime: false,
      steps: steps,
      distanceMeters: nil,
      flights: nil,
      restingHeartRate: restingHeartRate,
      sleep: makeSleep()
    )
  }

  private func ring(_ value: Double?, goal: Double?) -> ActivityRingMetric? {
    guard let value else { return nil }
    return ActivityRingMetric(value: value, goal: goal ?? 0)
  }

  /// 在快捷指令里把睡眠按阶段聚合几乎做不出来，所以只收总时长和清醒时长，
  /// 评分自然走「没有分段」那条分支，卡片也会写明这一点。
  private func makeSleep() -> SleepSummary? {
    guard let sleepMinutes, sleepMinutes > 0 else { return nil }
    let totals = SleepStageTotals(
      unspecified: sleepMinutes * 60,
      awake: max(0, awakeMinutes ?? 0) * 60
    )
    return SleepSummary(
      start: nil,
      end: nil,
      totals: totals,
      awakenings: 0,
      score: SleepScoring.score(totals: totals, awakenings: 0)
    )
  }
}

struct TodooCardShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: UpdateTodooCardIntent(),
      phrases: [
        "用 \(.applicationName) 更新卡片",
        "让 \(.applicationName) 显示图片",
      ],
      shortTitle: "自动更新卡片",
      systemImageName: "photo"
    )
    AppShortcut(
      intent: SendBingDailyWallpaperIntent(),
      phrases: [
        "用 \(.applicationName) 发送 Bing 每日壁纸",
        "用 \(.applicationName) 更新每日壁纸",
      ],
      shortTitle: "发送 Bing 每日壁纸",
      systemImageName: "globe.asia.australia.fill"
    )
    AppShortcut(
      intent: SendHealthSummaryIntent(),
      phrases: [
        "用 \(.applicationName) 发送今日健康摘要",
        "让 \(.applicationName) 显示健康数据",
      ],
      shortTitle: "发送今日健康摘要",
      systemImageName: "heart.text.square.fill"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .blue }
}

enum ShortcutRotation: String, AppEnum {
  case degrees0
  case degrees90
  case degrees180
  case degrees270

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "旋转"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .degrees0: "不旋转",
    .degrees90: "顺时针 90°",
    .degrees180: "旋转 180°",
    .degrees270: "顺时针 270°",
  ]

  var degrees: Int {
    switch self {
    case .degrees0: return 0
    case .degrees90: return 90
    case .degrees180: return 180
    case .degrees270: return 270
    }
  }
}

enum ShortcutDitherAlgorithm: String, AppEnum {
  case floydSteinberg
  case atkinson
  case orderedBayer
  case none

  static let typeDisplayRepresentation: TypeDisplayRepresentation = "显示效果"
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .floydSteinberg: "均衡（Floyd–Steinberg）",
    .atkinson: "柔和（Atkinson）",
    .orderedBayer: "网点（Bayer 4×4）",
    .none: "纯色（最近色）",
  ]

  var coreValue: DitherAlgorithm {
    switch self {
    case .floydSteinberg: return .floydSteinberg
    case .atkinson: return .atkinson
    case .orderedBayer: return .orderedBayer
    case .none: return .none
    }
  }
}
