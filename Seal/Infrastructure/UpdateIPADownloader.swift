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
    /// - 超时策略：中国大陆网络下 GitHub 资产域可能长时间无响应，仅靠系统默认空闲超时会让
    ///   下载卡在 0% 不报错；此处收紧请求空闲超时到 15s、总时长硬上限 90s。
    /// - 取消：使用 `URLSession.download(for:)` 原生异步 API，Task 取消会自动传导到传输任务，
    ///   无需手动 `withTaskCancellationHandler`（避免旧式 `task.value` 在本 SDK 下的类型歧义）。
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

        let delegate = ProgressDownloadDelegate(onProgress: onProgress)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (temporaryURL, response): (URL, URLResponse)
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch let nsError as NSError where nsError.code == NSURLErrorCancelled {
            try? fileManager.removeItem(at: destination)
            throw CancellationError()
        } catch let nsError as NSError where nsError.code == NSURLErrorTimedOut {
            try? fileManager.removeItem(at: destination)
            throw UpdateDownloadError.timeout
        } catch {
            try? fileManager.removeItem(at: destination)
            throw UpdateDownloadError.transport(error)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            try? fileManager.removeItem(at: destination)
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
        try? FileManager.default.removeItem(at: url)
    }
}

enum UpdateDownloadError: LocalizedError {
    case badHTTPStatus
    case saveFailed
    case timeout
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badHTTPStatus:
            return "下载失败（服务器响应异常）"
        case .saveFailed:
            return "下载文件保存失败"
        case .timeout:
            return "网络下载超时，请检查网络后重试"
        case .transport:
            return "网络下载失败，请稍后重试"
        }
    }

    var code: String {
        switch self {
        case .badHTTPStatus: return "SEAL-UPDATE-DL-501"
        case .saveFailed: return "SEAL-UPDATE-DL-502"
        case .timeout: return "SEAL-UPDATE-DL-504"
        case .transport: return "SEAL-UPDATE-DL-503"
        }
    }
}

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @Sendable (Int64, Int64?) async -> Void

    init(onProgress: @escaping @Sendable (Int64, Int64?) async -> Void) {
        self.onProgress = onProgress
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
        // async download(for:) 返回后再由调用方 moveItem 到最终位置，这里无需处理。
    }
}