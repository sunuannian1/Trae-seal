import Foundation

actor SealLogStore {
    private let fileURL: URL
    private let maximumEntries: Int
    private let fileProtector: any FileProtecting
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // 内存缓冲：append 只更新内存，由 flush_task 节流批量落盘，
    // 避免「每条日志都全量读 + JSON 重写 + atomic 双写 + protect」放大成 MB 级磁盘写。
    private var buffer: [SealLogEntry] = []
    private var bufferLoaded = false
    private var pendingFlush = false
    private var pendingMirror = false
    private var hasProtectedOnce = false

    init(
        fileURL: URL,
        maximumEntries: Int = 200,
        fileProtector: any FileProtecting = CompleteFileProtector()
    ) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        self.fileProtector = fileProtector
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func append(
        category: SealLogEntry.Category,
        level: SealLogEntry.Level = .info,
        message: String,
        code: String? = nil
    ) throws {
        loadBufferIfNeeded()
        buffer.append(
            SealLogEntry(
                category: category,
                level: level,
                message: LogPrivacyRedactor.redact(message),
                code: code.map(LogPrivacyRedactor.redact)
            )
        )
        buffer = Array(buffer.suffix(maximumEntries))
        if level == .error {
            pendingMirror = true
        }
        scheduleFlush()
    }

    func entries() throws -> [SealLogEntry] {
        loadBufferIfNeeded()
        return Array(buffer.map(Self.redacted).reversed())
    }

    func clear() throws {
        buffer = []
        bufferLoaded = true
        pendingMirror = false
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    func exportText() throws -> String {
        loadBufferIfNeeded()
        let formatter = ISO8601DateFormatter()
        return buffer.reversed().map { entry in
            let code = entry.code.map { " [\($0)]" } ?? ""
            return "\(formatter.string(from: entry.timestamp)) \(entry.level.rawValue.uppercased()) \(entry.category.rawValue)\(code) \(entry.message)"
        }.joined(separator: "\n")
    }

    private static func redacted(_ entry: SealLogEntry) -> SealLogEntry {
        SealLogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            category: entry.category,
            level: entry.level,
            message: LogPrivacyRedactor.redact(entry.message),
            code: entry.code.map(LogPrivacyRedactor.redact)
        )
    }

    private func loadBufferIfNeeded() {
        guard !bufferLoaded else { return }
        buffer = (try? read()) ?? []
        bufferLoaded = true
    }

    private func scheduleFlush() {
        guard !pendingFlush else { return }
        pendingFlush = true
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self?.performFlush()
        }
    }

    private func performFlush() {
        pendingFlush = false
        persist(buffer)
        if pendingMirror {
            pendingMirror = false
            mirrorToDocuments()
        }
    }

    /// 把最近日志镜像到 Documents（文件 App → 我的 iPhone → Seal → Seal-log.txt）
    private func mirrorToDocuments() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return }
        let text = (try? exportText()) ?? ""
        try? text.write(
            to: documents.appendingPathComponent("Seal-log.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func persist(_ entries: [SealLogEntry]) {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // 非 atomic：避免每条日志临时文件 + rename 的双写放大
        try? encoder.encode(entries).write(to: fileURL)
        if !hasProtectedOnce {
            hasProtectedOnce = true
            try? fileProtector.protect(fileURL)
        }
    }

    private func read() throws -> [SealLogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode(
            [SealLogEntry].self,
            from: Data(contentsOf: fileURL)
        )
    }
}