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

  static var parameterSummary: some ParameterSummary {
    Summary("用 TodooCard 自动发送 \(\.$image)")
  }

  func perform() async throws -> some IntentResult {
    let imageData = image.data
    let payload = try await Task.detached(priority: .userInitiated) {
      try AutomaticImageProcessor.makePayload(from: imageData)
    }.value

    let bluetooth = await TodooBluetoothManager.shared
    try await bluetooth.sendAutomaticallyAndWait(payload)
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
  }

  static var shortcutTileColor: ShortcutTileColor { .blue }
}

private enum AutomaticImageProcessor {
  static let maximumImageBytes = 100_000_000
  static let maximumImagePixels = 50_000_000

  static func makePayload(from data: Data) throws -> Data {
    guard !data.isEmpty else { throw AutomaticUpdateError.emptyImage }
    guard data.count <= maximumImageBytes else { throw AutomaticUpdateError.imageTooLarge }
    guard let decoded = UIImage(data: data) else { throw AutomaticUpdateError.invalidImage }

    let pixelWidth = decoded.cgImage?.width ?? Int(decoded.size.width * decoded.scale)
    let pixelHeight = decoded.cgImage?.height ?? Int(decoded.size.height * decoded.scale)
    let (pixelCount, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
    guard !overflow, pixelCount <= maximumImagePixels else {
      throw AutomaticUpdateError.tooManyPixels
    }

    let request = ImageProcessingRequest(
      image: ImageProcessor.normalized(decoded),
      rotation: 0,
      focusX: 50,
      focusY: 50,
      zoom: 1,
      algorithm: .floydSteinberg,
      strength: 1,
      brightnessCompensation: 0
    )
    return try ImageProcessor.process(request).payload
  }
}

enum AutomaticUpdateError: LocalizedError {
  case emptyImage
  case imageTooLarge
  case invalidImage
  case tooManyPixels
  case transferInProgress
  case transferFailed(String)

  var errorDescription: String? {
    switch self {
    case .emptyImage:
      return "快捷指令没有提供图片内容。"
    case .imageTooLarge:
      return "图片超过 100 MB 安全限制。"
    case .invalidImage:
      return "无法解码图片，请改用 PNG、JPEG、HEIF 或 WebP。"
    case .tooManyPixels:
      return "图片超过 5000 万像素安全限制。"
    case .transferInProgress:
      return "TodooCard 正在执行另一项发送。"
    case .transferFailed(let message):
      return message
    }
  }
}
