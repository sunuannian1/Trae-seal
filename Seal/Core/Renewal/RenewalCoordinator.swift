import Foundation

struct BatchRefreshResult: Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let failed: Int
    let remaining: Int
}

enum BatchRefreshEvent: Sendable {
    case prepared(apps: [AppRecord])
    case started(total: Int)
    case appProgress(index: Int, total: Int, app: AppRecord, stage: SigningStage)
    case appSucceeded(index: Int, total: Int, app: AppRecord)
    case appFailed(index: Int, total: Int, app: AppRecord, failure: ImportFailure)
}

actor RenewalCoordinator {
    private let appStore: any AppStore
    private let signingCoordinator: SigningCoordinator
    private let queueStore: RefreshQueueStore
    private let planner: RefreshPlanner
    private let defaultAccountIDProvider: (@Sendable () async -> UUID?)?
    private let accountsProvider: (@Sendable () async -> [AppleAccountRecord])?

    /// 单个应用续签失败后的最大自动重试次数（即总共最多尝试 1 + maxRetries 次）
    private let maxAttempts = 3
    /// 重试前等待的基础秒数，第 n 次重试等待 baseRetryDelay * n。
    /// 涉及 Apple 限流自愈，刻意保守、不缩短；激进缩短会让 503 场景退避不足反而更慢。
    private let baseRetryDelay: UInt64 = 2_000_000_000
    /// 两个应用之间的间隔，给 Apple 服务器和本地安装通道缓冲。
    /// 应用内部本就含多段 Apple 往返（fetchTeams / App ID / profile），
    /// 此间隔仅兜底分批节奏；延续签优化从 1.5s 保守降至 0.75s，仍是「给服务器缓冲」语义。
    private let interAppDelay: UInt64 = 750_000_000

    init(
        appStore: any AppStore,
        signingCoordinator: SigningCoordinator,
        queueStore: RefreshQueueStore,
        planner: RefreshPlanner = RefreshPlanner(),
        defaultAccountIDProvider: (@Sendable () async -> UUID?)? = nil,
        accountsProvider: (@Sendable () async -> [AppleAccountRecord])? = nil
    ) {
        self.appStore = appStore
        self.signingCoordinator = signingCoordinator
        self.queueStore = queueStore
        self.planner = planner
        self.defaultAccountIDProvider = defaultAccountIDProvider
        self.accountsProvider = accountsProvider
    }

    func refreshAll(
        progress: @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        let apps = try await appStore.fetchAll()
        let fallbackAccountID: UUID?
        if let provider = defaultAccountIDProvider {
            fallbackAccountID = await provider()
        } else {
            fallbackAccountID = nil
        }
        let allAccounts: [AppleAccountRecord]
        if let provider = accountsProvider {
            allAccounts = await provider()
        } else {
            allAccounts = []
        }
        let queue = planner.makeQueue(apps: apps, fallbackAccountID: fallbackAccountID, accounts: allAccounts)
        let queuedApps = queue.compactMap { item in apps.first(where: { $0.id == item.appID }) }
        await progress(.prepared(apps: queuedApps))
        try await queueStore.replace(with: queue)
        return try await process(queue: queue, progress: progress)
    }

    /// 判断某个错误是否值得自动重试。
    /// 原则：除了用户主动取消，其余一律重试——通道抖动、Apple 限流、证书同步、
    /// 网络超时、甚至账号/凭据读取的瞬时异常都可能在下一次恢复。
    private func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? ImportFailure {
            // 本地确实没有这条应用记录，重试也找不回来
            if failure.code == "SEAL-RENEW-404" { return false }
            // 确定性失败：重试/重新安装都无法改变结果，必须立即终止不做无效重试，
            // 与单签路径 SigningProgressView.isNonRetryableFailure 对齐。
            // 批量续签已传 bypassFreeAccountDeviceLimit: true 跳过本机 3-app 预检，
            // 超限/拒绝会真正打到 installd 返回 702l；若不排除，将完整重签+上传+等待 3 次。
            if failure.code == "SEAL-APPID-DEVICELIMIT"   // 免费账号 3 应用上限（本机预检）
                || failure.code == "SEAL-INSTALL-702l"     // 安装被 iOS 拒绝（3 应用上限/完整性校验）
                || failure.code == "SEAL-INSTALL-702s" {   // 设备存储空间不足
                return false
            }
            return true
        }
        return true
    }

    /// 把任意错误归一化成 ImportFailure，同时保留原始错误描述，不再吞掉根因
    private func normalize(_ error: Error) -> ImportFailure {
        if let failure = error as? ImportFailure { return failure }
        let nsError = error as NSError
        let detail = "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
        return ImportFailure(
            title: "续签失败",
            reason: "续签过程遇到临时错误（\(detail)），已自动重试仍未恢复。",
            recovery: "检查网络后重试；如持续失败请导出日志反馈",
            code: "SEAL-RENEW-500"
        )
    }

    private func process(
        queue: [RefreshQueueItem],
        progress: @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        await progress(.started(total: queue.count))
        var succeeded = 0
        var failed = 0

        for (offset, item) in queue.enumerated() {
            try Task.checkCancellation()

            // 应用之间留出缓冲，避免连续请求 Apple 服务器触发限流；第一个不用等
            if offset > 0 {
                try? await Task.sleep(nanoseconds: interAppDelay)
            }

            // 先确认记录存在；具体最新状态在每次尝试时重新读取（失败可能已改写 Bundle ID/证书）
            let initialApps = try await appStore.fetchAll()
            guard initialApps.contains(where: { $0.id == item.appID }) else {
                // 本地记录确实不存在，无法续签
                let failure = ImportFailure(
                    title: "无法续签应用",
                    reason: "续签时未找到应用（ID：\(item.appID)）的本地记录。",
                    recovery: "重新导入 IPA 并签名安装",
                    code: "SEAL-RENEW-404"
                )
                try? await queueStore.markFailed(appID: item.appID, errorCode: failure.code)
                failed += 1
                await emitFailure(progress: progress, offset: offset, total: queue.count, item: item, failure: failure)
                continue
            }

            // —— 自动重试循环：最多 maxAttempts 次 ——
            var lastError: Error?
            var updatedRecord: AppRecord?

            for attempt in 1...maxAttempts {
                // 每次尝试都重新读取最新记录
                guard let app = (try? await appStore.fetchAll())?.first(where: { $0.id == item.appID }) else {
                    lastError = ImportFailure(
                        title: "无法续签应用",
                        reason: "续签时未找到应用（ID：\(item.appID)）的本地记录。",
                        recovery: "重新导入 IPA 并签名安装",
                        code: "SEAL-RENEW-404"
                    )
                    break
                }
                do {
                    try Task.checkCancellation()
                    try await queueStore.markRunning(appID: item.appID)
                    let queueStore = self.queueStore
                    let isSeal = app.isSeal
                    let latestApp = app
                    let updated = try await signingCoordinator.signAndInstall(
                        appID: item.appID,
                        accountID: item.accountID,
                        requestedBundleIdentifier: latestApp.mappedBundleIdentifier ?? latestApp.preferredBundleIdentifier,
                        selectedCertificateSerialNumber: nil,
                        forceResign: true,
                        // 续签是覆盖已装应用，不新增免费账号设备槽位；已绕过 3-app 上限
                        // （设备级跨 team）装 6 个应用的用户，批量续签时必须跳过本机预检，
                        // 交回 installd 裁决，否则全部被 SEAL-APPID-DEVICELIMIT 误拦。
                        bypassFreeAccountDeviceLimit: true,
                        progress: { stage in
                            if isSeal, stage == .pushing || stage == .installing {
                                try? await queueStore.markCompleted(appID: item.appID)
                            }
                            await progress(
                                .appProgress(
                                    index: offset + 1,
                                    total: queue.count,
                                    app: latestApp,
                                    stage: stage
                                )
                            )
                        }
                    )
                    updatedRecord = updated
                    lastError = nil
                    break
                } catch is CancellationError {
                    do {
                        try await queueStore.markPending(appID: item.appID)
                    } catch {
                        throw Self.queuePersistenceFailure(
                            reason: "取消续签后，队列状态未能保存。",
                            code: "SEAL-RENEW-QUEUE-002"
                        )
                    }
                    throw CancellationError()
                } catch {
                    lastError = error
                    // 还能重试就等待后继续
                    if attempt < maxAttempts && isRetryable(error) {
                        let delay = baseRetryDelay * UInt64(attempt)
                        try? await Task.sleep(nanoseconds: delay)
                        continue
                    }
                    break
                }
            }

            if let updated = updatedRecord {
                // 成功
                try await queueStore.markCompleted(appID: item.appID)
                succeeded += 1
                await progress(
                    .appSucceeded(
                        index: offset + 1,
                        total: queue.count,
                        app: updated
                    )
                )
            } else if let lastError {
                // 重试用尽，判失败
                let failure = normalize(lastError)
                do {
                    try await queueStore.markFailed(
                        appID: item.appID,
                        errorCode: failure.code
                    )
                } catch {
                    throw Self.queuePersistenceFailure(
                        reason: "续签失败状态未能写入队列。",
                        code: "SEAL-RENEW-QUEUE-003"
                    )
                }
                failed += 1
                await emitFailure(progress: progress, offset: offset, total: queue.count, item: item, failure: failure)
            }
        }

        do {
            try await queueStore.removeCompleted()
        } catch {
            throw Self.queuePersistenceFailure(
                reason: "已完成的续签任务未能从队列中清理。",
                code: "SEAL-RENEW-QUEUE-005"
            )
        }
        return BatchRefreshResult(
            total: queue.count,
            succeeded: succeeded,
            failed: failed,
            remaining: max(0, queue.count - succeeded)
        )
    }

    /// 失败后重新读取一次最新应用记录并推送失败事件
    private func emitFailure(
        progress: @Sendable (BatchRefreshEvent) async -> Void,
        offset: Int,
        total: Int,
        item: RefreshQueueItem,
        failure: ImportFailure
    ) async {
        let currentApps = (try? await appStore.fetchAll()) ?? []
        if let app = currentApps.first(where: { $0.id == item.appID }) {
            await progress(
                .appFailed(
                    index: offset + 1,
                    total: total,
                    app: app,
                    failure: failure
                )
            )
        }
    }

    private static func queuePersistenceFailure(reason: String, code: String) -> ImportFailure {
        ImportFailure(
            title: "续签队列异常",
            reason: reason,
            recovery: "检查本机存储后重试",
            code: code
        )
    }

}
