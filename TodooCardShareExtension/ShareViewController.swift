import Combine
import UniformTypeIdentifiers
import UIKit

@MainActor
final class ShareViewController: UIViewController {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let actionButton = UIButton(type: .system)

    private var sendTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var failureError: Error?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        startSending()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 0, height: 290)

        iconView.image = UIImage(systemName: "rectangle.portrait.and.arrow.forward")
        iconView.tintColor = .systemBlue
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 34, weight: .medium)

        titleLabel.text = "发送到 TodooCard"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center

        statusLabel.text = "正在读取分享的图片…"
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 3

        activityIndicator.startAnimating()
        progressView.progress = 0
        progressView.isHidden = true

        actionButton.configuration = .bordered()
        actionButton.configuration?.title = "取消"
        actionButton.addTarget(self, action: #selector(actionButtonTapped), for: .touchUpInside)

        let progressStack = UIStackView(arrangedSubviews: [activityIndicator, progressView])
        progressStack.axis = .vertical
        progressStack.alignment = .fill
        progressStack.spacing = 14

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, statusLabel, progressStack, actionButton])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.heightAnchor.constraint(equalToConstant: 46),
            actionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    private func startSending() {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let imageData = try await self.loadSharedImageData()
                try Task.checkCancellation()
                self.statusLabel.text = "正在生成六色卡片内容…"

                let processed = try await Task.detached(priority: .userInitiated) {
                    try AutomaticImageProcessor.process(
                        imageData,
                        configuration: .standard
                    )
                }.value
                try Task.checkCancellation()

                let bluetooth = TodooBluetoothManager.shared
                self.observe(bluetooth)
                self.statusLabel.text = "正在连接上次使用的设备…"
                try await bluetooth.sendAutomaticallyAndWait(processed.payload)
                DeviceScreenSnapshot.save(processed.preview)
                RecentSendStore.record(
                    sourceData: imageData,
                    configuration: .standard,
                    preview: processed.preview,
                    payload: processed.payload
                )
                self.finishSuccessfully()
            } catch is CancellationError {
                return
            } catch {
                self.showFailure(error)
            }
        }
    }

    private func observe(_ bluetooth: TodooBluetoothManager) {
        bluetooth.$statusText
            .removeDuplicates()
            .sink { [weak self] status in
                guard !status.isEmpty else { return }
                self?.statusLabel.text = status
            }
            .store(in: &cancellables)

        bluetooth.$progress
            .sink { [weak self] progress in
                guard let self else { return }
                self.progressView.progress = Float(progress)
                self.progressView.isHidden = progress <= 0
            }
            .store(in: &cancellables)
    }

    private func finishSuccessfully() {
        activityIndicator.stopAnimating()
        progressView.isHidden = false
        progressView.setProgress(1, animated: true)
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = .systemGreen
        titleLabel.text = "发送成功"
        statusLabel.text = "TodooCard 屏幕已刷新"
        actionButton.isHidden = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func showFailure(_ error: Error) {
        failureError = error
        activityIndicator.stopAnimating()
        progressView.isHidden = true
        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconView.tintColor = .systemOrange
        titleLabel.text = "发送失败"
        statusLabel.text = error.localizedDescription
        actionButton.configuration?.title = "关闭"
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    @objc private func actionButtonTapped() {
        sendTask?.cancel()
        let error = failureError ?? ShareExtensionError.cancelled
        extensionContext?.cancelRequest(withError: error)
    }

    private func loadSharedImageData() async throws -> Data {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else {
            throw ShareExtensionError.noImage
        }

        let typeIdentifier = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier

        do {
            return try await loadData(from: provider, typeIdentifier: typeIdentifier)
        } catch {
            guard provider.canLoadObject(ofClass: UIImage.self) else { throw error }
            return try await loadImageObject(from: provider)
        }
    }

    private func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? ShareExtensionError.cannotReadImage)
                }
            }
        }
    }

    private func loadImageObject(from provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                guard let image = object as? UIImage, let data = image.pngData() else {
                    continuation.resume(throwing: error ?? ShareExtensionError.cannotReadImage)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}

private enum ShareExtensionError: LocalizedError {
    case noImage
    case cannotReadImage
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noImage:
            return "分享内容中没有可用的图片。"
        case .cannotReadImage:
            return "无法读取分享的图片，请换一张图片重试。"
        case .cancelled:
            return "已取消发送。"
        }
    }
}
