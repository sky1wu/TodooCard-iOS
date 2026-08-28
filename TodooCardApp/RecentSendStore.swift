import Combine
import UIKit

/// 主页最近发送列表里的一条记录：缩略图直接展示，重新发送时再按 id 取回 payload。
struct RecentSendItem: Identifiable, Equatable {
    let id: UUID
    let sentAt: Date
    let thumbnail: UIImage
}

/// 最近成功发送到卡片的画面。六色预览、缩略图和 payload 各存一个文件：
/// payload 原样保留，重新发送时不必再解码、抖动一遍，卡片上的画面与当初完全一致。
/// 和 `DeviceScreenSnapshot` 一样放在 App Group 容器里，分享扩展与快捷指令发出的图片
/// 主 App 也能读到；免费 Apple Account 拿不到 App Group 时退回各自沙盒，功能降级但不失效。
///
/// 索引是整份改写的，主 App 与分享扩展同时发送时后写入的一方会覆盖对方的这一条记录；
/// 记录本身不影响发送结果，因此这里不引入文件协调的额外开销。
enum RecentSendStore {
    /// 一条记录约 220 KB，其中绝大部分是 payload；12 条把占用控制在 3 MB 以内。
    static let limit = 12

    private static let directoryName = "recent-sends"
    private static let indexFileName = "index.json"
    private static let thumbnailWidth: CGFloat = 176

    private struct Entry: Codable {
        let id: UUID
        let sentAt: Date
    }

    /// 记下一次成功发送。写盘失败时静默放弃：记录只是便利功能，不该影响发送流程。
    static func record(preview: UIImage, payload: Data) {
        guard let directory = directoryURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID()
        guard let previewData = preview.pngData(),
              let thumbnailData = thumbnail(from: preview)?.pngData() else { return }
        do {
            try previewData.write(to: previewURL(id, in: directory), options: .atomic)
            try thumbnailData.write(to: thumbnailURL(id, in: directory), options: .atomic)
            try payload.write(to: payloadURL(id, in: directory), options: .atomic)
        } catch {
            deleteFiles(for: id, in: directory)
            return
        }

        var entries = loadEntries()
        entries.insert(Entry(id: id, sentAt: Date()), at: 0)
        saveEntries(trimmed(entries, in: directory))
    }

    /// 重新发送已有记录后把它移回最前面，而不是再存一份同样的画面。
    static func touch(_ id: UUID) {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index)
        entries.insert(Entry(id: id, sentAt: Date()), at: 0)
        saveEntries(entries)
    }

    static func remove(_ id: UUID) {
        guard let directory = directoryURL else { return }
        saveEntries(loadEntries().filter { $0.id != id })
        deleteFiles(for: id, in: directory)
    }

    /// 读出可以直接上屏的记录；缩略图缺失的条目视为已损坏，顺手从索引里清掉。
    static func items() -> [RecentSendItem] {
        guard let directory = directoryURL else { return [] }
        let entries = loadEntries()
        var items: [RecentSendItem] = []
        var healthy: [Entry] = []
        for entry in entries {
            guard let data = try? Data(contentsOf: thumbnailURL(entry.id, in: directory)),
                  let image = UIImage(data: data) else {
                deleteFiles(for: entry.id, in: directory)
                continue
            }
            items.append(RecentSendItem(id: entry.id, sentAt: entry.sentAt, thumbnail: image))
            healthy.append(entry)
        }
        if healthy.count != entries.count { saveEntries(healthy) }
        return items
    }

    static func payload(for id: UUID) -> Data? {
        guard let directory = directoryURL else { return nil }
        return try? Data(contentsOf: payloadURL(id, in: directory))
    }

    static func preview(for id: UUID) -> UIImage? {
        guard let directory = directoryURL else { return nil }
        guard let data = try? Data(contentsOf: previewURL(id, in: directory)) else { return nil }
        return UIImage(data: data)
    }

    // MARK: - 索引

    private static func loadEntries() -> [Entry] {
        guard let directory = directoryURL,
              let data = try? Data(contentsOf: directory.appendingPathComponent(indexFileName)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    private static func saveEntries(_ entries: [Entry]) {
        guard let directory = directoryURL,
              let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(indexFileName), options: .atomic)
    }

    private static func trimmed(_ entries: [Entry], in directory: URL) -> [Entry] {
        guard entries.count > limit else { return entries }
        for entry in entries[limit...] { deleteFiles(for: entry.id, in: directory) }
        return Array(entries.prefix(limit))
    }

    // MARK: - 文件

    private static func deleteFiles(for id: UUID, in directory: URL) {
        for url in [previewURL(id, in: directory), thumbnailURL(id, in: directory), payloadURL(id, in: directory)] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func previewURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-preview.png")
    }

    private static func thumbnailURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-thumb.png")
    }

    private static func payloadURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).payload")
    }

    private static func thumbnail(from preview: UIImage) -> UIImage? {
        guard preview.size.width > 0, preview.size.height > 0 else { return nil }
        guard preview.size.width > thumbnailWidth else { return preview }
        let scale = thumbnailWidth / preview.size.width
        let size = CGSize(
            width: thumbnailWidth,
            height: (preview.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            preview.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static var directoryURL: URL? {
        container?.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static var container: URL? {
        TodooAppGroup.container
            ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
}

/// 主页展示用的最近发送列表。写入后立刻重新读盘，界面与磁盘上的记录始终一致。
@MainActor
final class RecentSendLibrary: ObservableObject {
    @Published private(set) var items: [RecentSendItem] = []

    func refresh() {
        items = RecentSendStore.items()
    }

    func record(preview: UIImage, payload: Data) {
        RecentSendStore.record(preview: preview, payload: payload)
        refresh()
    }

    func touch(_ id: UUID) {
        RecentSendStore.touch(id)
        refresh()
    }

    func remove(_ id: UUID) {
        RecentSendStore.remove(id)
        refresh()
    }
}
