import AppIntents
import Foundation

struct UpdateTodooCardIntent: AppIntent {
  static let title: LocalizedStringResource = "自动更新 TodooCard"
  static let description = IntentDescription(
    "导入一张图片，使用默认显示效果生成卡片内容，并自动发送到上次成功使用的 TodooCard。"
  )
  static let openAppWhenRun = true

  @Parameter(
    title: "图片",
    description: "要显示在 TodooCard 上的图片",
    supportedTypeIdentifiers: ["public.image"]
  )
  var image: IntentFile

  static var parameterSummary: some ParameterSummary {
    Summary("用 TodooCard 自动发送 \(\.$image)")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    try ShortcutInbox.enqueue(imageData: image.data)
    await MainActor.run {
      NotificationCenter.default.post(name: ShortcutInbox.didReceiveRequest, object: nil)
    }
    return .result(dialog: "图片已交给 TodooCard，将自动处理并发送。")
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

struct PendingShortcutRequest: Codable, Sendable {
  let stagedImageFileName: String
}

enum ShortcutInbox {
  static let didReceiveRequest = Notification.Name("TodooCardShortcutInboxDidReceiveRequest")
  static let maximumImageBytes = 100_000_000

  private static let requestFileName = "pending-request.json"

  static func enqueue(imageData: Data) throws {
    guard !imageData.isEmpty else { throw ShortcutInboxError.emptyImage }
    guard imageData.count <= maximumImageBytes else { throw ShortcutInboxError.imageTooLarge }

    let manager = FileManager.default
    let directory = try inboxDirectory(using: manager)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    removePreviouslyStagedImage(in: directory, using: manager)

    let stagedFileName = UUID().uuidString
    let stagedURL = directory.appendingPathComponent(stagedFileName, isDirectory: false)
    do {
      try imageData.write(to: stagedURL, options: [.atomic, .completeFileProtection])
      let request = PendingShortcutRequest(stagedImageFileName: stagedFileName)
      let encoded = try JSONEncoder().encode(request)
      try encoded.write(
        to: directory.appendingPathComponent(requestFileName, isDirectory: false),
        options: [.atomic, .completeFileProtection]
      )
    } catch {
      try? manager.removeItem(at: stagedURL)
      throw error
    }
  }

  static func takeRequest() throws -> PendingShortcutRequest? {
    let manager = FileManager.default
    let directory = try inboxDirectory(using: manager)
    let requestURL = directory.appendingPathComponent(requestFileName, isDirectory: false)
    guard manager.fileExists(atPath: requestURL.path) else { return nil }

    let data = try Data(contentsOf: requestURL)
    try manager.removeItem(at: requestURL)
    do {
      return try JSONDecoder().decode(PendingShortcutRequest.self, from: data)
    } catch {
      throw ShortcutInboxError.invalidRequest
    }
  }

  static func loadAndRemoveImage(for request: PendingShortcutRequest) throws -> Data {
    guard UUID(uuidString: request.stagedImageFileName) != nil else {
      throw ShortcutInboxError.invalidRequest
    }
    let manager = FileManager.default
    let directory = try inboxDirectory(using: manager)
    let imageURL = directory.appendingPathComponent(request.stagedImageFileName, isDirectory: false)
    defer { try? manager.removeItem(at: imageURL) }
    return try Data(contentsOf: imageURL)
  }

  private static func inboxDirectory(using manager: FileManager) throws -> URL {
    guard let applicationSupport = manager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      throw ShortcutInboxError.storageUnavailable
    }
    return applicationSupport
      .appendingPathComponent("TodooCard", isDirectory: true)
      .appendingPathComponent("ShortcutInbox", isDirectory: true)
  }

  private static func removePreviouslyStagedImage(in directory: URL, using manager: FileManager) {
    let requestURL = directory.appendingPathComponent(requestFileName, isDirectory: false)
    defer { try? manager.removeItem(at: requestURL) }
    guard let data = try? Data(contentsOf: requestURL),
          let request = try? JSONDecoder().decode(PendingShortcutRequest.self, from: data),
          UUID(uuidString: request.stagedImageFileName) != nil else { return }
    try? manager.removeItem(
      at: directory.appendingPathComponent(request.stagedImageFileName, isDirectory: false)
    )
  }
}

enum ShortcutInboxError: LocalizedError {
  case emptyImage
  case imageTooLarge
  case invalidRequest
  case storageUnavailable

  var errorDescription: String? {
    switch self {
    case .emptyImage:
      return "快捷指令没有提供图片内容。"
    case .imageTooLarge:
      return "图片超过 100 MB 安全限制。"
    case .invalidRequest:
      return "快捷指令传入的图片请求已损坏，请重新运行。"
    case .storageUnavailable:
      return "无法访问 TodooCard 的快捷指令暂存目录。"
    }
  }
}
