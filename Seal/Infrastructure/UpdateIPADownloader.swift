import Foundation

/// 应用内更新 IPA 下载服务：流式下载到 Application Support/Seal/Downloads，带进度回调。
/// 遵循项目「大包流式处理」纪律，不整块载入内存。
final class UpdateIPADownloader {
    static let shared = UpdateIPADownloader()

    private let fileManager = FileManager.default

    private var downloadsDirectory: URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return support.appending(path: "Seal/Downloads", directoryHint: .isDirectory)
    }

    /// 下载 IPA 到本地，返回落盘文件 URL。进度 0–1。
    func download(
        from url: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        let destination = downloadsDirectory
            .appending(path: "seal-update-\(UUID().uuidString).ipa")

        let delegate = ProgressDownloadDelegate(onProgress: onProgress)
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(
                for: URLRequest(url: url),
                delegate: delegate
            )
        } catch {
            throw UpdateDownloadError.transport(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateDownloadError.badHTTPStatus
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw UpdateDownloadError.saveFailed
        }
        return destination
    }

    /// 删除指定下载文件（导入成功后清理）。
    func deleteDownloadedFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

enum UpdateDownloadError: LocalizedError {
    case badHTTPStatus
    case saveFailed
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badHTTPStatus:
            return "下载失败（服务器响应异常）"
        case .saveFailed:
            return "下载文件保存失败"
        case .transport:
            return "网络下载失败，请稍后重试"
        }
    }

    var code: String {
        switch self {
        case .badHTTPStatus: return "SEAL-UPDATE-DL-501"
        case .saveFailed: return "SEAL-UPDATE-DL-502"
        case .transport: return "SEAL-UPDATE-DL-503"
        }
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(min(max(fraction, 0), 1))
    }
}