import Foundation
@preconcurrency import Minimuxer

actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating
    private var cachedDeviceIdentifier: String?
    private var lastSuccessfulStart: Date?
    /// 最近一次“拿不到设备标识”的底层错误文本（Rust IdeviceError Debug），用于精准分类，不再黑盒。
    private var lastDiscoveryDetail: String?

    private static let startHardTimeoutSeconds: Double = 75
    private static let blockingCallTimeoutSeconds: Double = 5.0

    init(
        pairingStore: PairingStore,
        logDirectory: URL,
        onDemandActivator: any VPNOnDemandActivating = LocalDevVPNOnDemandActivator()
    ) {
        self.pairingStore = pairingStore
        self.logDirectory = logDirectory
        self.onDemandActivator = onDemandActivator
    }

    func start() async throws -> String {
        // 优化：如果最近 60 秒内成功启动过且设备仍就绪，直接返回缓存的 UDID
        if let cached = cachedDeviceIdentifier,
           let lastStart = lastSuccessfulStart,
           Date().timeIntervalSince(lastStart) < 60,
           await isReady() {
            return cached
        }
        // 整体硬超时：最多两轮诊断，避免永久停在"准备环境"。
        return try await withHardTimeout(seconds: Self.startHardTimeoutSeconds) {
            try await self.startOnce()
        }
    }

    /// 一次完整的隧道诊断流程；作为 actor 隔离方法，可直接读写自身缓存状态。
    private func startOnce() async throws -> String {
        var diagnostics = await diagnose()
        if diagnostics.failure != nil || diagnostics.deviceIdentifier == nil {
            // 第一轮失败：重置 Minimuxer 后再诊断一次。
            await reset()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            diagnostics = await diagnose()
        }
        if let failure = diagnostics.failure { throw failure }
        guard let deviceIdentifier = diagnostics.deviceIdentifier else {
            throw Self.channelNotReadyFailure
        }
        cachedDeviceIdentifier = deviceIdentifier
        lastSuccessfulStart = Date()
        return deviceIdentifier
    }

    func diagnose() async -> InstallChannelDiagnostics {
        var steps = InstallChannelDiagnostics.empty.steps
        var deviceIdentifier: String?

        func pass(_ kind: InstallDiagnosticStepKind) {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .passed
            }
        }

        func fail(
            _ kind: InstallDiagnosticStepKind,
            _ failure: ImportFailure
        ) -> InstallChannelDiagnostics {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .failed(failure)
            }
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: deviceIdentifier,
                failure: failure
            )
        }

        func run(_ kind: InstallDiagnosticStepKind) {
            if let index = steps.firstIndex(where: { $0.kind == kind }) {
                steps[index].status = .running
            }
        }

        do {
            run(.pairingFile)
            let pairingRecord = try await pairingStore.current()
            _ = try await pairingStore.contents()
            guard pairingRecord != nil else {
                return fail(.pairingFile, Self.missingPairingFailure)
            }
            pass(.pairingFile)

            #if targetEnvironment(simulator)
            deviceIdentifier = pairingRecord?.deviceIdentifier ?? "SIMULATOR"
            pass(.vpnTunnel)
            pass(.minimuxer)
            pass(.deviceIdentifier)
            pass(.pairingMatch)
            pass(.installationService)
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: deviceIdentifier,
                failure: nil
            )
            #else
            try FileManager.default.createDirectory(
                at: logDirectory,
                withIntermediateDirectories: true
            )
            NetworkObserver.shared.start()
            bindTunnelConfiguration()

            run(.vpnTunnel)
            await waitForNetworkRefresh(rounds: 2, delay: .milliseconds(250))
            let tunnelReachable = await onDemandActivator.probeTunnel()
            if tunnelReachable { pass(.vpnTunnel) }

            if let udid = try await readyDeviceIdentifier() {
                pass(.vpnTunnel)
                deviceIdentifier = udid
                pass(.minimuxer)
                pass(.deviceIdentifier)
                if let mismatch = Self.pairingMismatchFailure(
                    expected: pairingRecord?.effectiveDeviceIdentifier,
                    actual: udid
                ) {
                    return fail(.pairingMatch, mismatch)
                }
                pass(.pairingMatch)
                pass(.installationService)
                return InstallChannelDiagnostics(
                    steps: steps,
                    deviceIdentifier: deviceIdentifier,
                    failure: nil
                )
            }

            run(.minimuxer)
            do {
                let pairing = try await pairingStore.contents()
                let logPath = logDirectory.path
                let startOutcome = await offThread(seconds: 4.0) {
                    try Minimuxer.start(pairingFile: pairing, logPath: logPath)
                }
                if case .some(.failure(let startError)) = startOutcome {
                    lastDiscoveryDetail = Self.diagnostic(startError)
                    return fail(.minimuxer, Self.connectionFailure(startError))
                }
            } catch {
                lastDiscoveryDetail = Self.diagnostic(error)
                return fail(.minimuxer, Self.connectionFailure(error))
            }
            // 首次 RSD 握手（pair-verify + TLS-PSK + RSD handshake）在无线/冷启动时可能超过旧的 10 秒，
            // 过短会把“正在建立”误判成“设备未响应/连接失败”。延长到约 18 秒，成功即退出。
            var resolvedUDID: String?
            for attempt in 0..<36 {
                NetworkObserver.shared.refreshEndpoint()
                resolvedUDID = try await readyDeviceIdentifier()
                if resolvedUDID != nil { break }
                if attempt == 12, tunnelReachable == false {
                    // 中途再给 LocalDevVPN 一次按需拉起/探测机会，避免首次 probe 过早判死。
                    if await onDemandActivator.probeTunnel() { pass(.vpnTunnel) }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let udid = resolvedUDID else {
                return fail(
                    .deviceIdentifier,
                    Self.discoveryFailure(tunnelReachable: tunnelReachable, detail: lastDiscoveryDetail)
                )
            }
            pass(.vpnTunnel)
            deviceIdentifier = udid
            pass(.minimuxer)
            pass(.deviceIdentifier)

            if let mismatch = Self.pairingMismatchFailure(
                expected: pairingRecord?.effectiveDeviceIdentifier,
                actual: udid
            ) {
                return fail(.pairingMatch, mismatch)
            }
            pass(.pairingMatch)

            guard await isReady() else {
                return fail(.installationService, Self.channelNotReadyFailure)
            }
            pass(.installationService)
            return InstallChannelDiagnostics(
                steps: steps,
                deviceIdentifier: udid,
                failure: nil
            )
            #endif
        } catch let failure as ImportFailure {
            return fail(.pairingFile, failure)
        } catch {
            return fail(.pairingFile, Self.missingPairingFailure)
        }
    }

    func isReady() async -> Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let outcome = await offThread(seconds: Self.blockingCallTimeoutSeconds) {
            Minimuxer.ready()
        }
        guard case .some(.success(let ready)) = outcome else { return false }
        return ready
        #endif
    }

    func storedDeviceIdentifier() async -> String? {
        do {
            return try await pairingStore.current()?.effectiveDeviceIdentifier
        } catch {
            return nil
        }
    }

    func reset() async {
        #if !targetEnvironment(simulator)
        Minimuxer.reset()
        #endif
    }

    /// 整体硬超时：超时先到直接抛出；同步阻塞 FFI 无法被真正中断，
    /// 会在后台自行结束（结果被遗弃丢弃），不再阻塞用户流程。
    private func withHardTimeout<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        do {
            return try await HardTimeout.run(seconds: seconds, work)
        } catch is HardTimeout.TimeoutError {
            throw Self.channelTimeoutFailure
        }
    }

    /// Result 的 Failure 侧（any Error）不保证 Sendable，用 @unchecked 包装穿过竞速边界
    private struct OffThreadOutcome<T: Sendable>: @unchecked Sendable {
        let result: Result<T, Error>
    }

    /// 在后台线程执行可能长时间阻塞的同步 Minimuxer FFI；
    /// 超过 `seconds` 未返回则返回 nil（本次放弃），FFI 在后台自行结束后结果被丢弃，
    /// 避免同步调用把整个通道拖成“假死”。
    private func offThread<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error>? {
        // 抛错只可能是超时（工作结果/错误都装在 Result 里返回），统一映射为 nil
        do {
            let outcome: OffThreadOutcome<T> = try await HardTimeout.run(seconds: seconds) {
                OffThreadOutcome(result: Result(catching: work))
            }
            return outcome.result
        } catch {
            return nil
        }
    }

    /// 仅上传暂存（两阶段诊断路径；主链路走 install() 的合并调用）。
    /// 走缓存隧道会话，含同连接回读校验（大小不一致立即抛错，不把截断包留给 installd）。
    func pushIpa(ipaData: Data, bundleID: String) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let ipaMB = Double(ipaData.count) / 1_000_000
        // 上传含全量回读校验，总量约为单向上传的 2 倍（封顶 30 分钟）
        let pushTimeout = min(1800.0, 180.0 + ipaMB * 5.0)
        let maxAttempts = ipaMB > 100 ? 2 : 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let pushOutcome = await offThread(seconds: pushTimeout) {
                    try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)
                }
                if case .some(.failure(let pushError)) = pushOutcome { throw pushError }
                guard pushOutcome != nil else { throw Self.installTimeoutFailure }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                if attempt == 1 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } else {
                    Minimuxer.reset()
                    await waitForNetworkRefresh(rounds: 4, delay: .milliseconds(600))
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                }
                var readyWait = 0
                while await isReady() == false && readyWait < 15 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    readyWait += 1
                }
                continue
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    /// 仅触发安装（两阶段诊断路径；主链路走 install() 的合并调用）。
    /// 与 pushIpa 共用缓存隧道会话；若会话在两段之间被重建，installd 报
    /// MissingPackagePath，由 install() 的整体重跑恢复。
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let installTimeout = 600.0
        var lastError: Error?
        for attempt in 1...3 {
            do {
                // 每次安装前重置Install提供者，避免使用已断开的RSD缓存连接
                // 推送大文件后RSD连接可能超时断开，isReady()只检查TCP不检查RSD服务
                Install.resetProvider()
                if isSelfReplacement {
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    await SelfReplacementController.returnToHomeScreen()
                    try await installation.value
                } else {
                    let installOutcome = await offThread(seconds: installTimeout) {
                        try Minimuxer.installIpa(bundleId: bundleID)
                    }
                    if case .some(.failure(let installError)) = installOutcome { throw installError }
                    guard installOutcome != nil else { throw Self.installTimeoutFailure }
                }
                return
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                // 重试前重置连接，避免用死连接重试
                Install.resetProvider()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    /// 完整安装：**合并调用主链路** —— 上传 + 安装在同一条缓存隧道会话内完成。
    ///
    /// 会话不变量（官方 jas / SideStore IdeviceGateway 真机验证的形态）：
    /// shim afcd 的暂存视图绑定隧道会话，上传与安装跨会话时暂存包对 installd
    /// 不可见 → MissingPackagePath。合并调用把窗口归零；若两段之间会话因
    /// socket 错误被重建，整体重跑（重新上传）即恢复，不做局部补丁。
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let ipaMB = Double(ipaData.count) / 1_000_000
        // 合并调用 = 上传（对齐原 push 预算，封顶 30 分钟）+ 安装（600 秒）
        let mergedTimeout = min(1800.0, 180.0 + ipaMB * 5.0) + 600.0
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                if isSelfReplacement {
                    // Seal 自更新：安装命令发出后尽快回主屏，避免被替换时残留崩溃界面
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData)
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    await SelfReplacementController.returnToHomeScreen()
                    try await installation.value
                } else {
                    let outcome = await offThread(seconds: mergedTimeout) {
                        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData)
                    }
                    if case .some(.failure(let installError)) = outcome { throw installError }
                    guard outcome != nil else { throw Self.installTimeoutFailure }
                }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                let detail = Self.errorDetail(error)
                if Self.isTerminalInstallError(detail) {
                    break
                }
                if detail.contains("MissingPackagePath") == false {
                    // 非 MissingPackagePath（多为 socket/超时）：重建会话后重试
                    Minimuxer.reset()
                    await waitForNetworkRefresh(rounds: 2, delay: .milliseconds(600))
                }
                var readyWait = 0
                while await isReady() == false && readyWait < 15 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    readyWait += 1
                }
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    /// 带 AFC 上传进度（0-1）的合并安装覆写。Rust 上传线程回传的百分比经
    /// `offThread` 阻塞调用链转成异步进度回调；仅上传阶段（0-100%）有真实数值，
    /// 安装/验证仍为阶段驱动。
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let ipaMB = Double(ipaData.count) / 1_000_000
        let mergedTimeout = min(1800.0, 180.0 + ipaMB * 5.0) + 600.0
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let syncProgress: @Sendable (Double) -> Void = { [onProgress] p in
                    Task { await onProgress(p) }
                }
                if isSelfReplacement {
                    // 上传（0→100%）完成即 staging 结束、installd 即将开始；此刻回主屏，
                    // 使「回主屏」与「正在安装」对齐，避免固定 250ms 落在上传中途造成的 1-3 秒空档。
                    let selfReplaceProgress: @Sendable (Double) -> Void = { [onProgress] p in
                        Task { await onProgress(p) }
                        if p >= 1.0 {
                            Task { @MainActor in SelfReplacementController.returnToHomeScreen() }
                        }
                    }
                    let installation = Task.detached(priority: .userInitiated) {
                        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData, progress: selfReplaceProgress)
                    }
                    try await installation.value
                } else {
                    let outcome = await offThread(seconds: mergedTimeout) {
                        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData, progress: syncProgress)
                    }
                    if case .some(.failure(let installError)) = outcome { throw installError }
                    guard outcome != nil else { throw Self.installTimeoutFailure }
                }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                let detail = Self.errorDetail(error)
                if Self.isTerminalInstallError(detail) {
                    break
                }
                if detail.contains("MissingPackagePath") == false {
                    Minimuxer.reset()
                    await waitForNetworkRefresh(rounds: 2, delay: .milliseconds(600))
                }
                var readyWait = 0
                while await isReady() == false && readyWait < 15 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    readyWait += 1
                }
            }
        }
        throw Self.installationFailure(lastError!)
        #endif
    }

    func verifyInstalled(bundleID: String) async throws {
        #if targetEnvironment(simulator)
        return
        #else
        guard await isReady() else { throw Self.channelNotReadyFailure }
        // 验证前重置连接，避免用死连接查询
        Install.resetProvider()
        for _ in 0..<8 {
            if Minimuxer.lookupApp(bundleId: bundleID) != nil { return }
            try? await Task.sleep(for: .milliseconds(650))
        }
        throw ImportFailure(
            title: "安装后验证失败",
            reason: "iOS 安装服务未返回已安装的 Bundle ID。",
            recovery: "重试",
            code: "SEAL-INSTALL-707a"
        )
        #endif
    }


    #if !targetEnvironment(simulator)
    private func bindTunnelConfiguration() {
        Minimuxer.bindTunnelConfig(
            TunnelConfigBinding(
                setDeviceIP: { _ in },
                setFakeIP: { _ in },
                setSubnetMask: { _ in },
                getOverrideFakeIP: { "10.7.0.1" },
                setOverrideEffective: { _ in }
            )
        )
    }

    private func waitForNetworkRefresh(
        rounds: Int,
        delay: Duration
    ) async {
        for _ in 0..<rounds {
            NetworkObserver.shared.refreshEndpoint()
            try? await Task.sleep(for: delay)
        }
    }

    private func readyDeviceIdentifier() async throws -> String? {
        guard await isReady() else { return nil }
        let outcome = await offThread(seconds: Self.blockingCallTimeoutSeconds) {
            () -> DeviceIdentifierFetch in
            do {
                return .identified(try Minimuxer.fetchUDIDDetailed())
            } catch {
                let nsError = error as NSError
                return .rejected("\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)")
            }
        }
        // offThread 会把闭包结果再包一层 Result，这里需要两层解包：
        // 外层区分“后台执行是否超时/抛错”，内层区分“取 UDID 成功还是设备给出了具体拒绝原因”。
        guard case .some(.success(let inner)) = outcome else { return nil }
        switch inner {
        case .identified(let udid):
            return udid.isEmpty ? nil : udid
        case .rejected(let detail):
            // 保留 Rust 真实拒绝原因（PairVerifyFailed / Socket / TLS-RSD handshake…），
            // 供最终失败精准分类，不再把一切吞成“设备未响应/连接失败”。
            lastDiscoveryDetail = detail
            NSLog("[Seal] device identifier fetch failed: \(detail)")
            return nil
        }
    }

    private static func connectionFailure(_ error: Error) -> ImportFailure {
        let message = diagnostic(error)
        let normalized = message.lowercased()
        if normalized.contains("pair")
            || normalized.contains("pairing")
            || normalized.contains("lockdown")
            || normalized.contains("hostid")
            || normalized.contains("invalid host") {
            return ImportFailure(
                title: "设备配对不可用",
                reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
                recovery: "重新配对当前设备",
                code: "SEAL-INSTALL-703"
            )
        }
        if normalized.contains("trust") || normalized.contains("trusted") {
            return ImportFailure(
                title: "设备尚未信任",
                reason: "当前设备尚未完成信任确认。",
                recovery: "在 iPhone 上信任此设备后重试",
                code: "SEAL-INSTALL-704"
            )
        }
        if normalized.contains("timeout")
            || normalized.contains("timed out")
            || normalized.contains("connection")
            || normalized.contains("network")
            || normalized.contains("refused")
            || normalized.contains("unreachable")
            || normalized.contains("no connection")
            || normalized.contains("nodevice")
            || normalized.contains("no device") {
            return channelNotReadyFailure
        }
        return ImportFailure(
            title: "无法安装到手机",
            reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
            recovery: "重试",
            code: "SEAL-INSTALL-705"
        )
    }

    private static func installationFailure(_ error: Error) -> ImportFailure {
        let detail = diagnostic(error)
        let lower = detail.lowercased()

        // 确定性失败优先于连接类判断；错误文本里往往同时含 "device"（如
        // "No space left on device"），必须先识别具体根因，否则会被误判成"设备断开"。

        // 1) 存储空间不足（installd copyfile 阶段的内核 errno 28 / ENOSPC）
        if lower.contains("no space")
            || lower.contains("space left")
            || lower.contains("enospc")
            || lower.contains("errno 28")
            || lower.contains("code 28")
            || detail.contains("空间不足")
            || detail.contains("储存空间")
            || detail.contains("存储空间") {
            return ImportFailure(
                title: "设备存储空间不足",
                reason: "设备在解压并复制应用时空间不足。\(detail)",
                recovery: "删除一个或多个 App 或在系统设置中清理存储空间后重试",
                code: "SEAL-INSTALL-702s"
            )
        }

        // 2) 完整性校验失败 / 免费账号 3 应用上限（installd 的 APIInternalError）
        if lower.contains("integrity")
            || lower.contains("could not be verified")
            || lower.contains("cannot be verified")
            || lower.contains("maximum")
            || lower.contains("limit")
            || detail.contains("无法验证")
            || detail.contains("完整性")
            || detail.contains("上限")
            || detail.contains("已达") {
            return ImportFailure(
                title: "安装被 iOS 拒绝",
                reason: "iOS 拒绝了安装，常见原因是免费账号已装 3 个自签应用或签名校验失败。\(detail)",
                recovery: "卸载一个已安装的自签应用后重试，或重新签名",
                code: "SEAL-INSTALL-702l"
            )
        }

        // 3) 设备未连接/断开（精确匹配，不再用宽松的 "device" 子串，避免误伤上文）
        if detail.contains("NoDevice") || detail.contains("no device") {
            return ImportFailure(
                title: "与设备连接断开",
                reason: "设备返回：\(detail)",
                recovery: "检查 WiFi 连接后重试；大文件安装请保持 Seal 在前台",
                code: "SEAL-INSTALL-702"
            )
        }

        return ImportFailure(
            title: "安装失败",
            reason: "设备返回：\(detail)",
            recovery: "确认设备已信任、存储空间充足后重试",
            code: "SEAL-INSTALL-702"
        )
    }

    /// 确定性安装拒绝（空间不足 / 完整性校验失败 / 免费账号 3 应用上限）：
    /// 这类 installd 拒绝重传重试无意义，应首次即失败，避免把大包空推 3 轮。
    /// 与 `installationFailure` 的分类标记保持一致。
    private static func isTerminalInstallError(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        if lower.contains("no space")
            || lower.contains("space left")
            || lower.contains("enospc")
            || lower.contains("errno 28")
            || lower.contains("code 28")
            || lower.contains("integrity")
            || lower.contains("could not be verified")
            || lower.contains("cannot be verified")
            || lower.contains("maximum")
            || lower.contains("limit") {
            return true
        }
        return detail.contains("空间不足")
            || detail.contains("储存空间")
            || detail.contains("存储空间")
            || detail.contains("无法验证")
            || detail.contains("完整性")
            || detail.contains("上限")
            || detail.contains("已达")
    }

    private static func diagnostic(_ error: Error) -> String {
        let nsError = error as NSError
        if let minimuxerError = error as? MinimuxerError {
            return Minimuxer.describeError(minimuxerError)
        }
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    /// 从 Rust FFI NSError / ImportFailure 提取底层错误文本，用于设备错误分类。
    /// ImportFailure.errorDescription 返回 title（如"安装失败"），原始设备错误在 reason 里。
    private static func errorDetail(_ error: Error) -> String {
        if let failure = error as? ImportFailure {
            return failure.reason
        }
        let nsError = error as NSError
        return nsError.userInfo[NSLocalizedDescriptionKey] as? String
            ?? nsError.localizedDescription
    }
    #endif

    /// offThread 后台取 UDID 的结果：跨 @Sendable 线程只能携带 Sendable 值，
    /// 故用枚举同时表达成功标识与设备给出的具体拒绝原因（Result 的 Failure 必须遵循 Error，String 不行）。
    private enum DeviceIdentifierFetch: Sendable {
        case identified(String)
        case rejected(String)
    }

    /// 底层错误文本 → 拿不到设备标识的根因类别。纯字符串判定，可在模拟器单测。
    enum DeviceDiscoveryCause: Equatable { case pairingNotTrusted, handshake, tunnel, unknown }
    static func classifyDiscoveryFailure(_ detail: String) -> DeviceDiscoveryCause {
        let n = detail.lowercased()
        let pairingMarkers = [
            "pairverify", "pair_verify", "pairingrejected", "userdenied", "denied",
            "consent", "verifymanualpairing", "setuppairing", "not paired", "pairing failed",
            "pairingrejectedwitherror"
        ]
        let handshakeMarkers = [
            "tls", "handshake", "rsd", "opack", "cipher", "psk", "encrypt", "certificate"
        ]
        let tunnelMarkers = [
            "socket", "refused", "timed out", "timeout", "unreachable", "reset by peer",
            "broken pipe", "econn", "network", "not started", "no route", "host is down"
        ]
        if pairingMarkers.contains(where: { n.contains($0) }) { return .pairingNotTrusted }
        if handshakeMarkers.contains(where: { n.contains($0) }) { return .handshake }
        if tunnelMarkers.contains(where: { n.contains($0) }) { return .tunnel }
        return .unknown
    }

    /// “设备标识拿不到”的最终失败：结合隧道可达性与底层错误，给出可操作、可区分的引导，
    /// 而不是用一句“请确认 Wi-Fi/LocalDevVPN”掩盖配对未认可、握手失败、隧道不可达等不同根因。
    static func discoveryFailure(tunnelReachable: Bool, detail: String?) -> ImportFailure {
        let suffix = detail.map { "（底层返回：\($0)）" } ?? ""
        if let detail, tunnelReachable {
            switch classifyDiscoveryFailure(detail) {
            case .pairingNotTrusted:
                return ImportFailure(
                    title: "这台 iPhone 尚未信任当前配对",
                    reason: "设备拒绝了配对校验，通常是当前配对没有在“这台”设备上完成登记（换设备、重刷或还原后常见）。请用 Seal 配对助手重新连接这台 iPhone 完成配对，再回到 Seal 导入新配对。\(suffix)",
                    recovery: "用配对助手重新配对本机",
                    code: "SEAL-PAIR-211"
                )
            case .handshake:
                return ImportFailure(
                    title: "与设备的安全握手未完成",
                    reason: "LocalDevVPN 已连通，但远程配对的加密/RSD 握手失败。请保持 Seal 在前台、确认已开启开发者模式后重试；仍失败请用配对助手重新配对。\(suffix)",
                    recovery: "保持前台后重试",
                    code: "SEAL-INSTALL-709"
                )
            case .tunnel:
                return ImportFailure(
                    title: "无法经本地隧道连到设备",
                    reason: "LocalDevVPN 虽显示连接，但设备服务端口暂时不可达。请断开后重连 LocalDevVPN、确认网络正常后重试。\(suffix)",
                    recovery: "重连 LocalDevVPN 后重试",
                    code: "SEAL-INSTALL-710"
                )
            case .unknown:
                break
            }
        }
        if tunnelReachable == false {
            return ImportFailure(
                title: vpnTunnelUnavailableFailure.title,
                reason: vpnTunnelUnavailableFailure.reason + suffix,
                recovery: vpnTunnelUnavailableFailure.recovery,
                code: vpnTunnelUnavailableFailure.code
            )
        }
        return ImportFailure(
            title: deviceNotRespondingFailure.title,
            reason: deviceNotRespondingFailure.reason + suffix,
            recovery: deviceNotRespondingFailure.recovery,
            code: deviceNotRespondingFailure.code
        )
    }

    private static func pairingMismatchFailure(
        expected: String?,
        actual: String
    ) -> ImportFailure? {
        guard let expected,
              expected.isEmpty == false,
              expected.caseInsensitiveCompare(actual) != .orderedSame else {
            return nil
        }
        return ImportFailure(
            title: "设备配对不匹配",
            reason: "当前配对信息属于另一台设备，无法用于这台 iPhone。",
            recovery: "重新配对当前设备",
            code: "SEAL-PAIR-205"
        )
    }

    private static let missingPairingFailure = ImportFailure(
        title: "设备未配对",
        reason: "当前设备还没有完成配对。",
        recovery: "连接设备",
        code: "SEAL-PAIR-203b"
    )

    private static let vpnTunnelUnavailableFailure = ImportFailure(
        title: "无法安装到手机",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-701"
    )

    private static let deviceNotRespondingFailure = ImportFailure(
        title: "设备未响应",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-708"
    )

    private static let channelNotReadyFailure = ImportFailure(
        title: "无法安装到手机",
        reason: "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试。",
        recovery: "重试",
        code: "SEAL-INSTALL-706b"
    )

    private static let channelTimeoutFailure = ImportFailure(
        title: "本地通道连接超时",
        reason: "LocalDevVPN 隧道在限定时间内未就绪。已自动重试过；仍失败请确认已连接 Wi-Fi 且 LocalDevVPN 处于连接状态后再试。",
        recovery: "重新检查",
        code: "SEAL-INSTALL-706t"
    )

    private static let installTimeoutFailure = ImportFailure(
        title: "安装超时",
        reason: "向设备传输并安装应用耗时过长，将自动重试。若多次出现，请确认 LocalDevVPN 连接稳定后再试。",
        recovery: "重试",
        code: "SEAL-INSTALL-702t"
    )
}
