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
    return .result()
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
