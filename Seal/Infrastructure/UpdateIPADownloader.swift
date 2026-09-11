import Foundation

/// 应用内更新 IPA 下载服务：流式下载到 Application Support/Seal/Downloads，带进度回调。
/// 遵循项目「大包流式处理」纪律，不整块载入内存。
/// 无实例可变状态（struct），`shared` 满足 Swift 6 并发安全。
struct UpdateIPADownloader {
    static let shared = UpdateIPADownloader()

    private var downloadsDirectory: URL {
        let fileManager = FileManager.default
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first!
        return support.appending(path: "Seal/Downloads", directoryHint: .isDirectory)
    }

    /// 下载 IPA 到本地，返回落盘文件 URL。
    /// - Parameter onProgress: 回调（已接收字节数, 总字节数可空）。总大小未知（无 Content-Length）时
    ///   `total` 为 nil，由 UI 改为展示「已下载 X」字节数，不再返回假百分比。
    func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64?) async -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: downloadsDirectory,
            withIntermediateDirectories: true
        )

        let destination = downloadsDirectory
            .appending(path: "seal-update-\(UUID().uuidString).ipa")

        let delegate = ProgressDownloadDelegate(onProgress: onProgress, destination: destination)
        // 中国大陆网络下 GitHub 资产域可能长时间无响应，默认 60s 空闲超时过久会让
        // 下载卡在 0% 不报错；此处收紧到 30s，失败快速抛出 transport 错误并显示「重试」。
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await URLSession.shared.download(
                for: request,
                delegate: delegate
            )
        } catch {
            try? fileManager.removeItem(at: destination)
            throw UpdateDownloadError.transport(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? fileManager.removeItem(at: destination)
            throw UpdateDownloadError.badHTTPStatus
        }

        // Apple 语义：didFinishDownloadingTo 的 location 仅在回调内有效，已在回调内移到 destination。
        // 若实现未生效（destination 不存在），用 async 返回的 temporaryURL 兜底再移一次。
        if !fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.moveItem(at: temporaryURL, to: destination)
            } catch {
                try? fileManager.removeItem(at: temporaryURL)
                throw UpdateDownloadError.saveFailed
            }
        }
        return destination
    }

    /// 删除指定下载文件（导入成功后清理）。
    func deleteDownloadedFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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
    private let onProgress: @Sendable (Int64, Int64?) async -> Void
    private let destination: URL

    init(onProgress: @escaping @Sendable (Int64, Int64?) async -> Void, destination: URL) {
        self.onProgress = onProgress
        self.destination = destination
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // totalBytesExpectedToWrite 在无 Content-Length（GitHub 302 重定向后的响应、
        // chunked transfer）时为 NSURLSessionTransferSizeUnknown(-1)，不能作为进度分母。
        // 优先用任务自身的接收字节数锚点；总大小仍未知时 total 传 nil，由 UI 展示已下载字节数，
        // 不再发假百分比（否则「0% 突然跳到续签」）。
        var expected = downloadTask.countOfBytesExpectedToReceive
        if expected <= 0 { expected = totalBytesExpectedToWrite }
        let total: Int64? = expected > 0 ? expected : nil
        Task { await onProgress(totalBytesWritten, total) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // location 仅在回调内有效，须立即移动到永久位置，否则会被系统删除。
        try? FileManager.default.moveItem(at: location, to: destination)
    }
}