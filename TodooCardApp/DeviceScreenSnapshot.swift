import UIKit

/// 记录最近一次成功发送的画面，也就是卡片此刻正在显示的内容。
/// 存在 App Group 容器里，分享扩展与快捷指令发出的图片主 App 也能读到；
/// 免费 Apple Account 重签名后拿不到 App Group，会退回各自沙盒，功能降级但不失效。
enum DeviceScreenSnapshot {
    private static let fileName = "device-screen.png"

    static func save(_ image: UIImage) {
        guard let url = fileURL, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> UIImage? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static var fileURL: URL? {
        container?.appendingPathComponent(fileName)
    }

    private static var container: URL? {
        TodooAppGroup.container
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}
