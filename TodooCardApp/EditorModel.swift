import Combine
import UIKit
#if canImport(TodooCore)
import TodooCore
#endif

@MainActor
final class EditorModel: ObservableObject {
    static let maximumImageBytes = 100_000_000
    static let maximumImagePixels = 50_000_000

    @Published private(set) var sourceImage: UIImage?
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var payload: Data?
    @Published private(set) var payloadSHA256 = "—"
    @Published private(set) var isProcessing = false
    @Published var errorMessage: String?

    @Published private(set) var rotation = 0
    @Published private(set) var zoom = 1.0
    @Published private(set) var focusX = 50.0
    @Published private(set) var focusY = 50.0
    @Published private(set) var algorithm = DitherAlgorithm.floydSteinberg
    @Published private(set) var brightnessCompensation = 0.0
    private let strength: Float = 1

    private var generation = 0
    private var processingTask: Task<Void, Never>?

    var canSend: Bool { payload != nil && !isProcessing }

    var hasFramingChanges: Bool {
        rotation != 0
            || abs(zoom - 1) > 0.001
            || abs(focusX - 50) > 0.001
            || abs(focusY - 50) > 0.001
    }

    /// 返回是否真的换上了新图片；失败时保留上一张图片和它的编辑状态。
    /// `preferredAlgorithm` 给的是这张图更合适的量化方式（例如本机生成的健康摘要要用最近色
    /// 保住文字边缘），只在换图这一刻覆盖一次，之后用户仍然可以自己改。
    @discardableResult
    func loadImage(data: Data, preferredAlgorithm: DitherAlgorithm? = nil) -> Bool {
        guard data.count <= Self.maximumImageBytes else {
            errorMessage = "图片超过 100 MB 安全限制。"
            return false
        }
        guard let decoded = UIImage(data: data) else {
            errorMessage = "无法解码这张图片，请改用 PNG、JPEG、HEIF 或 WebP。"
            return false
        }
        let pixelWidth = decoded.cgImage?.width ?? Int(decoded.size.width * decoded.scale)
        let pixelHeight = decoded.cgImage?.height ?? Int(decoded.size.height * decoded.scale)
        guard pixelWidth * pixelHeight <= Self.maximumImagePixels else {
            errorMessage = "图片超过 5000 万像素安全限制。"
            return false
        }

        processingTask?.cancel()
        sourceImage = ImageProcessor.normalized(decoded)
        previewImage = nil
        payload = nil
        payloadSHA256 = "—"
        rotation = 0
        zoom = 1
        focusX = 50
        focusY = 50
        if let preferredAlgorithm { algorithm = preferredAlgorithm }
        errorMessage = nil
        scheduleProcessing()
        return true
    }

    /// 当前的构图与效果，存进最近发送记录后可以原样还原回来。
    var configuration: AutomaticImageConfiguration {
        AutomaticImageConfiguration(
            rotation: rotation,
            focusX: focusX,
            focusY: focusY,
            zoom: zoom,
            algorithm: algorithm,
            strength: strength,
            brightnessCompensation: Float(brightnessCompensation)
        )
    }

    /// 从最近发送记录回到编辑：换上原图副本，并把当时的构图与效果一起装回来。
    func restore(source: UIImage, configuration: AutomaticImageConfiguration) {
        processingTask?.cancel()
        sourceImage = ImageProcessor.normalized(source)
        previewImage = nil
        payload = nil
        payloadSHA256 = "—"
        rotation = configuration.rotation
        zoom = min(4, max(1, configuration.zoom))
        focusX = min(100, max(0, configuration.focusX))
        focusY = min(100, max(0, configuration.focusY))
        algorithm = configuration.algorithm
        brightnessCompensation = min(1, max(-1, Double(configuration.brightnessCompensation)))
        errorMessage = nil
        scheduleProcessing()
    }

    func clearImage() {
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        sourceImage = nil
        previewImage = nil
        payload = nil
        payloadSHA256 = "—"
        isProcessing = false
        rotation = 0
        zoom = 1
        focusX = 50
        focusY = 50
        algorithm = .floydSteinberg
        brightnessCompensation = 0
        errorMessage = nil
    }

    func setAlgorithm(_ value: DitherAlgorithm) {
        algorithm = value
        scheduleProcessing()
    }

    func setBrightnessCompensation(_ value: Double) {
        brightnessCompensation = min(1, max(-1, value))
        scheduleProcessing()
    }

    func setZoom(_ value: Double) {
        zoom = min(4, max(1, value))
        scheduleProcessing()
    }

    func rotateClockwise() {
        rotation = (rotation + 90) % 360
        focusX = 50
        focusY = 50
        scheduleProcessing()
    }

    func resetFraming() {
        rotation = 0
        zoom = 1
        focusX = 50
        focusY = 50
        scheduleProcessing()
    }

    func applyGesture(
        translation: CGSize,
        magnification: Double,
        in viewport: CGSize
    ) {
        guard let image = sourceImage, viewport.width > 0, viewport.height > 0,
              magnification.isFinite,
              magnification > 0 else { return }

        let proposedZoom = min(4, max(1, zoom * magnification))
        guard
              let layout = try? computeCoverLayout(
                sourceWidth: image.size.width,
                sourceHeight: image.size.height,
                rotation: rotation,
                focusX: focusX,
                focusY: focusY,
                zoom: proposedZoom
              )
        else { return }

        var proposedFocusX = focusX
        var proposedFocusY = focusY
        let targetDeltaX = Double(translation.width / viewport.width) * Double(CardDisplay.width)
        let targetDeltaY = Double(translation.height / viewport.height) * Double(CardDisplay.height)
        if layout.overflowX > 0 {
            proposedFocusX = min(100, max(0, (layout.cropX - targetDeltaX) / layout.overflowX * 100))
        }
        if layout.overflowY > 0 {
            proposedFocusY = min(100, max(0, (layout.cropY - targetDeltaY) / layout.overflowY * 100))
        }

        let changed = abs(proposedZoom - zoom) > 0.001
            || abs(proposedFocusX - focusX) > 0.001
            || abs(proposedFocusY - focusY) > 0.001
        guard changed else { return }

        zoom = proposedZoom
        focusX = proposedFocusX
        focusY = proposedFocusY
        scheduleProcessing()
    }

    private func scheduleProcessing() {
        guard let sourceImage else { return }
        generation += 1
        let expectedGeneration = generation
        processingTask?.cancel()
        payload = nil
        isProcessing = true
        let request = ImageProcessingRequest(
            image: sourceImage,
            rotation: rotation,
            focusX: focusX,
            focusY: focusY,
            zoom: zoom,
            algorithm: algorithm,
            strength: strength,
            brightnessCompensation: Float(brightnessCompensation)
        )

        processingTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let result = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try ImageProcessor.process(request)
                }.value
                guard !Task.isCancelled, let self, self.generation == expectedGeneration else { return }
                self.previewImage = result.preview
                self.payload = result.payload
                self.payloadSHA256 = result.payloadSHA256
                self.isProcessing = false
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.generation == expectedGeneration else { return }
                self.payload = nil
                self.isProcessing = false
                self.errorMessage = error.localizedDescription
            }
        }
    }
}
