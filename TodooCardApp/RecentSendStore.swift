import Combine
import UIKit

/// 主页最近发送列表里的一条记录。缩略图用没有抖动的原图渲染：六色画面缩到几十点
/// 只剩一片彩色噪点，看不出发的是什么。
struct RecentSendItem: Identifiable, Equatable {
    let id: UUID
    let sentAt: Date
    let thumbnail: UIImage
    /// 存了原图副本和当时构图的记录才能回到编辑器；更早版本写下的记录只能重新发送。
    let isEditable: Bool
}

/// 一条记录里够回到编辑器的全部内容。
struct RecentSendDraft {
    let source: UIImage
    let configuration: AutomaticImageConfiguration
}

/// 最近成功发送到卡片的画面。每条记录存四份东西：
/// 原图副本（长边缩到 2048 的 JPEG）与当时的构图用来回到编辑器继续调整；
/// 三种固件 Payload 原样保留，长按重新发送时仍能按目标固件选择正确线格式；
/// 六色画面用于发送成功后回填卡片外观；彩色缩略图供主页列表展示。
///
/// 和 `DeviceScreenSnapshot` 一样放在 App Group 容器里，分享扩展里手动选中的图片主 App
/// 也能读到；免费 Apple Account 拿不到 App Group 时退回各自沙盒，功能降级但不失效。
///
/// 索引是整份改写的，主 App 与分享扩展同时发送时后写入的一方会覆盖对方的这一条记录；
/// 记录本身不影响发送结果，因此这里不引入文件协调的额外开销。
enum RecentSendStore {
    /// 一条记录约 1 MB；12 条通常仍能把总占用控制在十几 MB。
    static let limit = 12

    private static let directoryName = "recent-sends"
    private static let indexFileName = "index.json"
    /// 列表里每张缩略图 84 pt 宽，264 px 足够 3 倍屏。
    private static let thumbnailWidth: CGFloat = 264
    /// 原图副本的长边上限。528 × 792 的目标区域最多放大 4 倍，2048 仍有富余。
    private static let sourceLongestSide: CGFloat = 2048
    private static let jpegQuality: CGFloat = 0.85

    private struct Framing: Codable {
        let rotation: Int
        let focusX: Double
        let focusY: Double
        let zoom: Double
        let algorithm: String
        let strength: Float
        let brightness: Float

        init(_ configuration: AutomaticImageConfiguration) {
            rotation = configuration.rotation
            focusX = configuration.focusX
            focusY = configuration.focusY
            zoom = configuration.zoom
            algorithm = configuration.algorithm.rawValue
            strength = configuration.strength
            brightness = configuration.brightnessCompensation
        }

        var configuration: AutomaticImageConfiguration {
            AutomaticImageConfiguration(
                rotation: rotation,
                focusX: focusX,
                focusY: focusY,
                zoom: zoom,
                algorithm: DitherAlgorithm(rawValue: algorithm) ?? .floydSteinberg,
                strength: strength,
                brightnessCompensation: brightness
            )
        }
    }

    private struct Entry: Codable {
        let id: UUID
        let sentAt: Date
        /// 更早版本写下的记录没有构图，也没有原图副本，只能重新发送。
        let framing: Framing?
    }

    /// 记下一次用户手动所选图片的成功发送。写盘失败时静默放弃：记录只是便利功能，
    /// 不该影响发送流程。
    static func recordUserSelected(
        source: UIImage,
        configuration: AutomaticImageConfiguration,
        preview: UIImage,
        payload: T3PayloadSet
    ) {
        guard let directory = directoryURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = UUID()
        let request = ImageProcessingRequest(
            image: source,
            rotation: configuration.rotation,
            focusX: configuration.focusX,
            focusY: configuration.focusY,
            zoom: configuration.zoom,
            algorithm: configuration.algorithm,
            strength: configuration.strength,
            brightnessCompensation: configuration.brightnessCompensation
        )
        guard let thumbnail = try? ImageProcessor.framedThumbnail(request, width: thumbnailWidth),
              let thumbnailData = thumbnail.jpegData(compressionQuality: jpegQuality),
              let sourceData = sourceCopy(of: source),
              let previewData = preview.pngData() else { return }

        do {
            try sourceData.write(to: sourceURL(id, in: directory), options: .atomic)
            try thumbnailData.write(to: thumbnailURL(id, in: directory), options: .atomic)
            try previewData.write(to: previewURL(id, in: directory), options: .atomic)
            // 保留原文件名存 legacy 流，让旧版本 App 仍可读取这条记录。
            try payload.legacyCompressed.write(to: payloadURL(id, in: directory), options: .atomic)
            if let current = payload.currentCompressed {
                try current.write(to: currentPayloadURL(id, in: directory), options: .atomic)
            }
            if let raw = payload.controllerRaw {
                try raw.write(to: rawPayloadURL(id, in: directory), options: .atomic)
            }
        } catch {
            deleteFiles(for: id, in: directory)
            return
        }

        var entries = loadEntries()
        entries.insert(
            Entry(id: id, sentAt: Date(), framing: Framing(configuration)),
            at: 0
        )
        saveEntries(trimmed(entries, in: directory))
    }

    /// 分享扩展手里只有用户所选图片的原始数据，解码一次交给上面的实现。
    static func recordUserSelected(
        sourceData: Data,
        configuration: AutomaticImageConfiguration,
        preview: UIImage,
        payload: T3PayloadSet
    ) {
        guard let source = UIImage(data: sourceData) else { return }
        recordUserSelected(
            source: ImageProcessor.normalized(source),
            configuration: configuration,
            preview: preview,
            payload: payload
        )
    }

    /// 重新发送已有记录后把它移回最前面，而不是再存一份同样的画面。
    static func touch(_ id: UUID) {
        var entries = loadEntries()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let existing = entries.remove(at: index)
        entries.insert(Entry(id: id, sentAt: Date(), framing: existing.framing), at: 0)
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
            guard let image = image(at: thumbnailURL(entry.id, in: directory)) else {
                deleteFiles(for: entry.id, in: directory)
                continue
            }
            let hasSource = FileManager.default.fileExists(
                atPath: sourceURL(entry.id, in: directory).path
            )
            items.append(
                RecentSendItem(
                    id: entry.id,
                    sentAt: entry.sentAt,
                    thumbnail: image,
                    isEditable: entry.framing != nil && hasSource
                )
            )
            healthy.append(entry)
        }
        if healthy.count != entries.count { saveEntries(healthy) }
        return items
    }

    /// 取回原图副本和当时的构图，用来在编辑器里继续调整这次发送。
    static func draft(for id: UUID) -> RecentSendDraft? {
        guard let directory = directoryURL,
              let framing = loadEntries().first(where: { $0.id == id })?.framing,
              let source = image(at: sourceURL(id, in: directory)) else { return nil }
        return RecentSendDraft(source: source, configuration: framing.configuration)
    }

    static func payload(for id: UUID) -> T3PayloadSet? {
        guard let directory = directoryURL else { return nil }
        guard let legacy = try? Data(contentsOf: payloadURL(id, in: directory)) else { return nil }
        let current = try? Data(contentsOf: currentPayloadURL(id, in: directory))
        let raw = try? Data(contentsOf: rawPayloadURL(id, in: directory))
        return T3PayloadSet(currentCompressed: current, legacyCompressed: legacy, controllerRaw: raw)
    }

    static func preview(for id: UUID) -> UIImage? {
        guard let directory = directoryURL else { return nil }
        return image(at: previewURL(id, in: directory))
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
        let urls = [
            sourceURL(id, in: directory),
            thumbnailURL(id, in: directory),
            previewURL(id, in: directory),
            payloadURL(id, in: directory),
            currentPayloadURL(id, in: directory),
            rawPayloadURL(id, in: directory),
        ]
        for url in urls { try? FileManager.default.removeItem(at: url) }
    }

    private static func sourceURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-source.jpg")
    }

    private static func thumbnailURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-thumb.jpg")
    }

    private static func previewURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-preview.png")
    }

    private static func payloadURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).payload")
    }

    private static func currentPayloadURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-current.payload")
    }

    private static func rawPayloadURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString)-raw.payload")
    }

    private static func image(at url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// 原图副本：长边超过上限就等比缩小，再统一转成 JPEG，避免一条记录占掉几十兆。
    private static func sourceCopy(of image: UIImage) -> Data? {
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > 0 else { return nil }
        guard longestSide > sourceLongestSide else {
            return image.jpegData(compressionQuality: jpegQuality)
        }
        let scale = sourceLongestSide / longestSide
        let size = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
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

/// 主页展示用的最近发送列表。写盘放在后台线程，写完再回主线程刷新，
/// 发送成功那一刻不会因为存记录卡住界面。
@MainActor
final class RecentSendLibrary: ObservableObject {
    @Published private(set) var items: [RecentSendItem] = []

    func refresh() {
        items = RecentSendStore.items()
    }

    func recordUserSelected(
        source: UIImage,
        configuration: AutomaticImageConfiguration,
        preview: UIImage,
        payload: T3PayloadSet
    ) {
        Task { [weak self] in
            await Task.detached(priority: .utility) {
                RecentSendStore.recordUserSelected(
                    source: source,
                    configuration: configuration,
                    preview: preview,
                    payload: payload
                )
            }.value
            self?.refresh()
        }
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
