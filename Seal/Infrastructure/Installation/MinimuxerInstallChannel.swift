import Foundation
@preconcurrency import Minimuxer

/// 自替换安装的「单飞」闸门。
///
/// 2026-09-16 真机日志（Seal-log(8)）显示：`19:43:50` 提交了一笔自替换安装，
/// `19:45:51` 又提交了一笔 —— 间隔只有 91 秒，而第一笔的 `stageAndInstall`
/// **根本没有返回**。`Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制，
/// 于是同一个 Bundle ID 上会同时存在两个 installd 安装命令，正是 R05 要防的
/// 「第二次安装」（表现为 `ApplicationVerificationFailed`、白图标、装到一半的应用）。
///
/// 抽成纯类型是为了能单测：**超时不得放行第二次安装**（底下那次很可能还在跑），
/// 只有安装真的返回、或真的抛错（非超时）才解锁。
struct SelfReplacementInstallGate {
    private(set) var isInFlight = false

    /// 取闸。返回 `false` 表示已有安装在进行中，调用方必须直接拒绝本次请求。
    mutating func acquire() -> Bool {
        guard isInFlight == false else { return false }
        isInFlight = true
        return true
    }

    /// 归还闸。`timedOut` 为真时**保持置位**：超时只代表上层不再等待，
    /// 底层同步 FFI 很可能仍在设备端执行；此时放行第二次安装就是在制造并发安装。
    mutating func release(timedOut: Bool) {
        guard timedOut == false else { return }
        isInFlight = false
    }
}

/// RSD 的暂存区绑定同一条隧道会话，必须使用 Rust 合并入口；Lockdown 不存在 RSD
/// 暂存区，必须依次走 AFC + installation_proxy。若两者混用，17.0–17.3.1 会直接
/// 调到没有 RPPairing 文件的 Rust FFI，安装和续签均无法开始。
enum PairingInstallTransport: Equatable {
    case remotePairing
    case lockdown
}

func pairingInstallTransport(isRemotePairing: Bool) -> PairingInstallTransport {
    isRemotePairing ? .remotePairing : .lockdown
}

/// ⚠️ `progress` **必须带 `@escaping`**（2026-09-21，CI 实报）✗ ——
/// `Minimuxer.stageAndInstall(bundleId:ipaBytes:progress:)` 的参数是 `@escaping`，
/// 而 Swift 的闭包参数**默认 non-escaping** ⇒ 少了它编译失败：
/// `passing non-escaping parameter 'progress' to function expecting an '@escaping' closure`。
/// 本机没有 Swift 工具链，这类错误只在云构建暴露 ⇒ 透传闭包时先看目标签名。
private func installIPAUsingActivePairingTransport(
    bundleID: String,
    ipaData: Data,
    progress: @escaping @Sendable (Double) -> Void
) throws {
    switch pairingInstallTransport(isRemotePairing: Minimuxer.isRemotePairing) {
    case .remotePairing:
        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData, progress: progress)
    case .lockdown:
        try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)
        progress(1.0)
        try Minimuxer.installIpa(bundleId: bundleID)
    }
}

actor MinimuxerInstallChannel: InstallChannel {
    private let pairingStore: PairingStore
    private let logDirectory: URL
    private let onDemandActivator: any VPNOnDemandActivating
    /// 安装链路自己的日志出口（可选：测试桩与预览不传）。
    ///
    /// 2026-09-16 之前这条链路**一行日志都没有**：真机日志里 Seal 自替换在
    /// 「签名产物核验通过」之后 93 秒完全空白，既没有「安装调用已返回」，
    /// 也没有任何失败结论 —— 无法区分「还在装」和「已经死了」。
    /// 对照同一天的普通 App 安装：`16:59:06` 开始 → `16:59:13` 就写出
    /// 「签名并安装成功」，只有 7 秒。安装是整条链路里唯一会静默卡死的一段，
    /// 它必须留下日志。
    private let logStore: SealLogStore?
    /// 自替换安装的单飞闸门，见 `SelfReplacementInstallGate`。
    private var selfReplacementGate = SelfReplacementInstallGate()
    private var cachedDeviceIdentifier: String?
    private var lastSuccessfulStart: Date?
    /// 正在进行的整段隧道诊断。签名链路与 ViewModel 现在会**并发**请求启动通道
    /// （ViewModel 在签名开始就并行发起、SigningCoordinator 安装前再 ensure 一次），
    /// 没有它就会各自跑一遍完整诊断（reset + 18s RSD 握手 + 36×500ms 轮询），
    /// 既重复又让「正在连接设备」耗时翻倍。并发调用一律合并到同一次启动。
    private var inFlightStart: Task<String, Error>?
    /// 最近一次“拿不到设备标识”的底层错误文本（Rust IdeviceError Debug），用于精准分类，不再黑盒。
    private var lastDiscoveryDetail: String?
    /// 失败熔断：最近一次诊断失败的时间与错误。
    /// 用途是让批量续签在通道不可用时**只付一次**诊断代价，而不是 N×75s。
    private var lastFailureAt: Date?
    private var lastFailure: Error?

    private static let startHardTimeoutSeconds: Double = 75
    private static let blockingCallTimeoutSeconds: Double = 5.0
    /// 设备标识缓存窗口。签名/续签是一条从「连设备」到「装完」的长会话，
    /// 批量续签在两次 start 之间会隔很久（每个 App 都要签名、申请描述文件），
    /// 原 60s 窗口一过期就整体重跑诊断（reset + 18s RSD 握手 + 36×500ms 轮询），
    /// 于是每个 App 都在「连接设备」卡一下。窗口放宽到整场会话，
    /// 命中仍要求 isReady() 为真，设备真的断开不会用到陈腐缓存。
    private static let cacheWindowSeconds: Double = 900
    /// 诊断失败后的熔断窗口（秒）。
    ///
    /// 批量续签若把前置的「通道可用性判定」拿掉，通道不可用时 N 个 App 会各自
    /// 重跑一遍完整诊断（每个最长 75s）。有了这段窗口，第一个 App 付掉诊断代价，
    /// 后续 App 在窗口内直接拿到同一个错误快速失败。
    ///
    /// 取值 60 秒：需要覆盖「一轮批量里从第一个 App 失败到最后一个 App 尝试」的跨度 ——
    /// 每个 App 失败前还会走一遍申请证书/描述文件，间隔可能到几十秒，窗口太短会在
    /// 中途过期，导致又有一个 App 重跑 75s 诊断。
    ///
    /// 这不会挡住用户的手动重试：用户发起的签名/续签会话（`runSigning` /
    /// `startBatchRefresh` / `refreshSigningChannel`）都会在开始时显式调用
    /// `clearFailureCooldown()`，只有**同一轮批量内部**的连续调用才吃熔断。
    private static let failureCooldownSeconds: TimeInterval = 60

    /// 安装等待的心跳间隔。
    ///
    /// 安装阶段 installd **不回报任何进度**，所以「等待中」和「已死」在日志上
    /// 本来长得一模一样。心跳是这段唯一的活性信号（普通 App 安装实测 7 秒，
    /// 心跳通常不会触发；真机 93 秒静默就是缺了它）。
    ///
    /// ⚠️ **两条安装路径共用这一个常量与同一个 `beginInstallHeartbeat`**。
    /// 2026-09-17 真机（构建 97）：普通安装卡了 **9 分多钟**，日志里从「开始安装」
    /// 到用户导出日志**一行都没有** —— 因为心跳当时只加在**自替换**那条路径上。
    /// 同一条规则只落在两条链路中的一条，正是本仓库反复踩到的形态。
    private static let installHeartbeatNanoseconds: UInt64 = 15_000_000_000

    /// 等待安装返回期间的活性心跳。
    ///
    /// - Parameter label: 进日志的前缀，例如 `安装` / `自替换安装`。
    /// - Returns: 需要在等待结束后 `cancel()` 的任务。
    ///
    /// 刻意做成「返回任务、由调用方 `defer { cancel() }`」而不是包住一段闭包：
    /// 两条路径的等待原语不同（`offThread` 返回 `Result?`，自替换走 `HardTimeout.run`），
    /// 包闭包会把它们各自的语义压平。共用的是**心跳本身**，不是等待方式。
    /// 安装等待「明显超常」的阈值：超过它就在心跳里**多写一条可判读的记录**（只写一次）。
    ///
    /// 这条记录的价值是把「卡在哪儿」从一句笼统的「没有进度回报」里区分出来 ——
    /// 两者的排查方向完全不同：
    ///
    /// - 界面**仍显示上传百分比** ⇒ 卡在**传输**（会话 / 隧道问题）
    /// - 界面显示「**设备正在安装**」⇒ 卡在 **installd**（安装阶段）
    ///
    /// ⚠️ **只记日志、不改变行为**：等待上限按包大小算（小包 804 秒、大包 2400 秒），
    /// 而「慢」与「死」在没有设备端进度信号时无法区分，所以不能据此提前放弃。
    /// 它只是让下一次真机日志可判读。
    ///
    /// ⚠️ 阈值**按本次等待上限算**（2026-09-17 修正）：第一版写死 **120 秒** ——
    /// 那是按「普通小包 7–11 秒」定的，但**大包本来就慢**（抖音 779 MB 的上限是 2400 秒，
    /// 等两分钟完全正常）。写死阈值会对大包报**假警报**，而假警报会把真信号埋掉。
    /// ⇒ 取上限的四分之一：小包 804/4 ≈ 201 秒、抖音 2400/4 = 600 秒。
    private static func abnormalInstallWaitSeconds(budget: Double) -> Double {
        max(120.0, budget / 4.0)
    }

    private func beginInstallHeartbeat(_ label: String, budget: Double) -> Task<Void, Never> {
        let threshold = Self.abnormalInstallWaitSeconds(budget: budget)
        let startedAt = Date()
        return Task.detached(priority: .utility) { [weak self] in
            var didReportAbnormal = false
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: Self.installHeartbeatNanoseconds)
                if Task.isCancelled { return }
                let waited = Int(Date().timeIntervalSince(startedAt))
                await self?.log("\(label)仍在等待：已等待 \(waited) 秒（installd 安装阶段不回报进度）")
                if didReportAbnormal == false, Double(waited) >= threshold {
                    didReportAbnormal = true
                    await self?.log(
                        "\(label)等待已明显超常：已等待 \(waited) 秒"
                        + "（本次等待上限 \(Int(budget)) 秒；普通小包安装约 7–11 秒）。"
                        + "判读：界面仍显示上传百分比 ⇒ 卡在传输；显示「设备正在安装」"
                        + "⇒ 卡在 installd",
                        level: .warning
                    )
                }
            }
        }
    }

    /// 复用缓存通道前，超过这个时长就做一次**有界**的活性探测。
    ///
    /// 60 秒是「批量续签里相邻两个 App 的间隔」量级：比它短的复用**完全跳过**探测，
    /// 保住 `start()` 那 900 秒缓存的意义（不为每个 App 都多问一次设备）。
    private static let cachedSessionProbeThresholdSeconds: TimeInterval = 60

    /// 活性探测的硬上限。探测**自己也不能卡住** —— 它要验证的正是「死连接会阻塞」。
    private static let cachedSessionProbeTimeoutSeconds: Double = 5

    /// **只取证、不改变行为**的缓存会话活性探测（2026-09-17）。
    ///
    /// ## 为什么需要它
    ///
    /// 安装复用 `connect_to_rsd_services` 的**缓存隧道会话**，而这条链路上**没有任何
    /// 一处验证会话在链路上还活着**：
    /// - `start()` 的 900 秒缓存只查 `Minimuxer.ready()` 这个**标志位**；
    /// - `installSignedIPA` 的唯一漏斗 `if !isReady() { start() }` 同样只查标志位
    ///   ⇒ 标志为真时**连 `start()` 都不会调**，更不会重建连接。
    ///
    /// 而本仓自己的注释**三处**都记着这个失败模式：
    /// 「推送大文件后 RSD 连接可能超时断开，**isReady() 只检查 TCP 不检查 RSD 服务**」、
    /// 「RSD 缓存连接可能已随隧道断开；不复位会让重试一直复用死连接」、
    /// 「验证前重置连接，避免用死连接查询」。
    ///
    /// 死会话上跑同步 FFI 不会立刻报错，而是**阻塞到操作系统放弃** ——
    /// 2026-09-17 真机：普通安装静默 **9 分多钟**（等待上限 804 秒），日志里一行都没有，
    /// 而同一次会话里前一次安装只用了 10.7 秒（那次会话是刚建立的）。
    ///
    /// ## 为什么现在**只记日志**
    ///
    /// 真正的补救是重建连接（`Minimuxer.reset()` 内部的
    /// `RustIdevice.invalidateConnection()`；注意 `Install.resetProvider()` **只清
    /// Swift 侧对象、清不掉 Rust 的会话缓存**，所以那个不是杠杆）。
    /// 但 `Minimuxer.reset()` 会拆掉**可能仍在跑**的上一笔安装连接（R05）——
    /// 在拿到「会话确实是死的」这条直接证据之前不动行为。
    /// 这次探测就是为了拿到它：下一次再卡住，日志里会**先**出现这一条。
    private func probeCachedSessionIfStale() async {
        guard let lastStart = lastSuccessfulStart,
              Date().timeIntervalSince(lastStart) > Self.cachedSessionProbeThresholdSeconds else {
            return
        }
        let age = Int(Date().timeIntervalSince(lastStart))
        let outcome = await offThread(seconds: Self.cachedSessionProbeTimeoutSeconds) {
            try Minimuxer.fetchUDIDDetailed()
        }
        // 成功路径**不写日志**：每次安装都多一行会把真实信号淹掉（本仓已有一次
        // 「临时脚手架占了 30% 日志」的教训）。
        if case .none = outcome {
            await log(
                "安装前探测：复用已启动 \(age) 秒的缓存会话，"
                + "\(Int(Self.cachedSessionProbeTimeoutSeconds)) 秒无响应（疑似死连接）",
                level: .warning
            )
        } else if case .some(.failure(let error)) = outcome {
            await log(
                "安装前探测：复用已启动 \(age) 秒的缓存会话，查询报错（疑似死连接）—— "
                + Self.diagnostic(error),
                level: .warning
            )
        }
    }

    init(
        pairingStore: PairingStore,
        logDirectory: URL,
        onDemandActivator: any VPNOnDemandActivating = LocalDevVPNOnDemandActivator(),
        logStore: SealLogStore? = nil
    ) {
        self.pairingStore = pairingStore
        self.logDirectory = logDirectory
        self.onDemandActivator = onDemandActivator
        self.logStore = logStore
    }

    func start() async throws -> String {
        // 优化：如果最近一次成功启动仍在缓存窗口内且设备仍就绪，直接返回缓存的 UDID，
        // 避免批量签名/续签对每个 App 都重跑完整诊断（reset + RSD 握手 + 轮询）卡在「连设备」。
        if let cached = cachedDeviceIdentifier,
           let lastStart = lastSuccessfulStart,
           Date().timeIntervalSince(lastStart) < Self.cacheWindowSeconds,
           await isReady() {
            return cached
        }
        // 失败熔断：刚诊断失败过就不再来一遍，直接把同一个错误还回去。
        // 这是批量续签能安全去掉前置等待的前提 —— 否则 N 个 App 各跑一遍 75s 诊断。
        if let lastFailureAt,
           let lastFailure,
           Date().timeIntervalSince(lastFailureAt) < Self.failureCooldownSeconds {
            throw lastFailure
        }
        // 单飞：已有诊断在跑就加入它，不再另起一轮。
        if let inFlightStart {
            return try await inFlightStart.value
        }
        let task = Task { () -> String in
            // 整体硬超时：最多两轮诊断，避免永久停在"准备环境"。
            try await withHardTimeout(seconds: Self.startHardTimeoutSeconds) {
                try await self.startOnce()
            }
        }
        inFlightStart = task
        defer { inFlightStart = nil }
        do {
            let deviceIdentifier = try await task.value
            lastFailureAt = nil
            lastFailure = nil
            return deviceIdentifier
        } catch {
            lastFailureAt = Date()
            lastFailure = error
            throw error
        }
    }

    /// 用户主动刷新时清除熔断，让下一次 `start()` 真正重跑诊断。
    /// 见 `InstallChannel.clearFailureCooldown()` 的说明。
    func clearFailureCooldown() async {
        lastFailureAt = nil
        lastFailure = nil
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
        // 追踪当前正进行到哪一步，顶层 catch 据此归因，避免配对/目录/设备断开等
        // 无关异常被一律误报成「配对文件损坏」。
        var currentKind: InstallDiagnosticStepKind = .pairingFile

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
            currentKind = kind
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
            if tunnelReachable {
                pass(.vpnTunnel)
            }
            // 不再自动拉起内置 SealTunnel：它只会把 10.7.0.0↔10.7.0.1 来回反射、
            // 不把流量真正转发到设备，Minimuxer 经 10.7.0.1:49152 仍连不上设备，
            // 反而会和外部 LocalDevVPN 抢 10.7.0.0/24 网段。
            // 免费账号一律走外部 LocalDevVPN 软件的真转发（回到 v1.0.13 及以前行为）。

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
            return fail(currentKind, failure)
        } catch {
            #if !targetEnvironment(simulator)
            lastDiscoveryDetail = Self.diagnostic(error)
            return fail(currentKind, Self.connectionFailure(error))
            #else
            // 模拟器下 diagnose 走 simulator 分支（直接 return），不会真的抛真机错误；
            // 此处兜底仅保证编译合法，复用块外始终可用的通用失败，避免引用被
            // #if !targetEnvironment(simulator) 排除的 diagnostic/connectionFailure。
            return fail(currentKind, Self.channelNotReadyFailure)
            #endif
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

    /// 在后台线程执行可能长时间阻塞的同步 Minimuxer FFI；
    /// 超过 `seconds` 未返回则返回 nil（本次放弃），FFI 在后台自行结束后结果被丢弃，
    /// 避免同步调用把整个通道拖成“假死”。
    ///
    /// ⚠️ 实现已抽到 `BlockingCall.bounded` —— 本仓还有另外几处同步 FFI
    /// （`isAppInstalled` 等）也需要同一个有界语义，**不要在这里再抄一份**
    /// （「同一条规则两份实现」已经踩过五次）。
    private func offThread<T: Sendable>(
        seconds: Double,
        _ work: @Sendable @escaping () throws -> T
    ) async -> Result<T, Error>? {
        await BlockingCall.bounded(seconds: seconds, work)
    }

    // MARK: - 安装等待预算与日志

    /// 纯上传预算：含同连接全量回读校验，总量约为单向上传的 2 倍（封顶 30 分钟）。
    private static func uploadBudgetSeconds(ipaMB: Double) -> Double {
        min(1800.0, 180.0 + ipaMB * 5.0)
    }

    /// 上传 + 安装的合并预算：上传预算 + 安装 600 秒。
    private static func mergedInstallBudgetSeconds(ipaMB: Double) -> Double {
        uploadBudgetSeconds(ipaMB: ipaMB) + 600.0
    }

    /// 安装链路日志：**最佳努力**，写不进去也绝不阻断安装。
    ///
    /// 每条都立刻 `flush()`：自替换的终点是**当前进程被新包替换掉**，
    /// 还留在缓冲里的最后几行（恰好是「安装调用已返回」这种最关键的一行）
    /// 会随进程一起消失，而用户导出的 `Documents/Seal-log.txt` 正是 `flush()` 镜像的。
    private func log(
        _ message: String,
        level: SealLogEntry.Level = .info,
        code: String? = nil
    ) async {
        guard let logStore else { return }
        try? await logStore.append(
            category: .installation,
            level: level,
            message: message,
            code: code
        )
        await logStore.flush()
    }

    private static func megabyteText(_ ipaMB: Double) -> String {
        String(format: "%.1f MB", ipaMB)
    }

    private static func elapsedText(since start: Date) -> String {
        String(format: "%.1f 秒", Date().timeIntervalSince(start))
    }

    /// 底层错误 → 可读文本（Rust FFI 的 MinimuxerError 优先，其余退回 NSError 描述）。
    ///
    /// 刻意放在 `#if !targetEnvironment(simulator)` **之外**：自替换看门狗要在
    /// 模拟器上也能编译（它只负责等待与写日志，不碰 Minimuxer 的安装 API），
    /// 而它的「抛错」日志需要这段文本。`MinimuxerError` / `describeError` 来自
    /// `Vendor/Minimuxer/Sources` 的纯 Swift 层，全平台可用。
    static func diagnostic(_ error: Error) -> String {
        if let minimuxerError = error as? MinimuxerError {
            return Minimuxer.describeError(minimuxerError)
        }
        let nsError = error as NSError
        return "\(nsError.domain) (\(nsError.code)): \(nsError.localizedDescription)"
    }

    /// 从 Rust FFI NSError / ImportFailure 提取底层错误文本，用于设备错误分类。
    /// ImportFailure.errorDescription 返回 title（如"安装失败"），原始设备错误在 reason 里。
    ///
    /// 非 `ImportFailure` 必须复用 `diagnostic`：生产安装路径抛的是
    /// `MinimuxerError.InstallApp(deviceError)`，该枚举只遵循 `Error` +
    /// `CustomStringConvertible`，桥接成 `NSError` 后关联值里的
    /// `ApplicationVerificationFailed` / `No space left` 会全部丢失，于是
    /// `isTerminalInstallError` 恒判「可重试」⇒ 500MB 整包被空推 3 轮。
    /// `installationFailure` 用的也是 `diagnostic`，两者同源才不会「一张表认得、
    /// 另一张表喂错文本」。
    static func errorDetail(_ error: Error) -> String {
        if let failure = error as? ImportFailure {
            return failure.reason
        }
        return diagnostic(error)
    }

    /// 确定性安装拒绝（空间不足 / 完整性校验失败 / 免费账号 3 应用上限）：
    /// 这类 installd 拒绝重传重试无意义，应首次即失败，避免把大包空推 3 轮。
    ///
    /// 与 `installationFailure` 共用 `errorDetail`/`diagnostic` 取词；新增错误名时
    /// 两处必须同步。刻意放在 `#if !targetEnvironment(simulator)` **之外**：
    /// 纯文本判定只有这样才可能被单测覆盖（`@testable import Seal` 跑在模拟器上）。
    ///
    /// 注意「安装超时 **不等于** 安装失败」这条判据在 `isTimeoutInstallError`
    /// —— 超时必须走那条路，不能用这里的文本匹配。
    static func isTerminalInstallError(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        if lower.contains("no space")
            || lower.contains("space left")
            || lower.contains("enospc")
            || lower.contains("errno 28")
            || lower.contains("code 28")
            || lower.contains("integrity")
            || lower.contains("could not be verified")
            || lower.contains("cannot be verified")
            || lower.contains("applicationverificationfailed")
            || lower.contains("verificationfailed")
            || lower.contains("failed to verify")
            || lower.contains("code signature")
            || lower.contains("signed resource")
            // DRM 元数据残留（SC_Info 里登记的 sinf 路径越界）：installd 捕获 sinf 失败。
            // 真机实测（构建 184，源阅读）：ApplicationSINFCaptureFailed
            // (Root sinf URL points outside of bundle)。同一份包必然同错 ⇒ 首次即终止。
            || lower.contains("sinf")
            || lower.contains("invalidsignature")
            || lower.contains("profileexpired")
            || lower.contains("untrusted")
            || lower.contains("maximum")
            || lower.contains("limit") {
            return true
        }
        return detail.contains("空间不足")
            || detail.contains("储存空间")
            || detail.contains("存储空间")
            || detail.contains("无法验证")
            || detail.contains("无法安装")
            || detail.contains("完整性")
            || detail.contains("上限")
            || detail.contains("已达")
    }

    /// 安装超时 **不等于** 安装失败（R05 的核心判据）。
    ///
    /// `Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制：`offThread` 的
    /// 「超时」只是**上层不再等待**，底下这次安装**很可能还在跑**。因此超时后一旦重试，
    /// 就会在同一个 Bundle ID 上出现两个并发的 installd（旧的还在装、新的已经开始传包）
    /// —— 这正是 R05 要防的「第二次安装」，表现为 `ApplicationVerificationFailed`、
    /// 白图标、或装到一半的应用。
    ///
    /// 判定不依赖错误文本（文案会漂移），而是看错误本身是不是超时：
    /// - `HardTimeout.TimeoutError`：直接来自竞速包装；
    /// - `installTimeoutFailure`：`offThread` 返回 nil 后由调用方抛出的那种。
    ///
    /// 放在 `#if !targetEnvironment(simulator)` **之外**：自替换看门狗（同样在 `#if` 之外）
    /// 要用它决定超时后是否解锁单飞闸门，而这段逻辑与平台无关。
    /// ⚠️ 这是本轮实际踩到的编译错误 —— `build-package` 绿、`swift-regression` 红。
    private static func isTimeoutInstallError(_ error: Error) -> Bool {
        if error is HardTimeout.TimeoutError { return true }
        if let failure = error as? ImportFailure,
           failure.code == installTimeoutFailure.code {
            return true
        }
        return false
    }

    /// 自替换被「上一笔仍在进行中」拒绝（见 `SelfReplacementInstallGate`）。
    ///
    /// 与超时一样按终态处理：重试只会被同一个闸门再拒一次，而两条重试路径里的
    /// `Minimuxer.reset()` / `Install.resetProvider()` 还会把**可能仍在跑的安装连接**
    /// 拆掉 —— 那会让第一笔安装彻底失败，比不重试更糟。
    ///
    /// 判定同样不依赖错误文本，只看错误码。同样放在 `#if` 之外（理由同上）。
    private static func isSelfReplacementBusyError(_ error: Error) -> Bool {
        guard let failure = error as? ImportFailure else { return false }
        return failure.code == selfReplacementAlreadyRunningFailure.code
    }

    // MARK: - 自替换安装

    /// 提交一笔自替换安装（Seal 覆盖运行中的自己）。**同一时刻只允许一笔**。
    ///
    /// 闸门见 `SelfReplacementInstallGate`；等待与日志见 `waitForSelfReplacement`。
    private func runSelfReplacementInstall(
        bundleID: String,
        context: String,
        budget: Double,
        start: @Sendable @escaping () throws -> Void
    ) async throws {
        guard selfReplacementGate.acquire() else {
            await log(
                "自替换安装被拒绝：上一笔仍在进行中，本次未提交（避免同一 Bundle ID 上出现两次并发安装）",
                level: .warning,
                code: Self.selfReplacementAlreadyRunningFailure.code
            )
            throw Self.selfReplacementAlreadyRunningFailure
        }
        let installation = Task.detached(priority: .userInitiated) {
            try start()
        }
        do {
            try await waitForSelfReplacement(
                bundleID: bundleID,
                context: context,
                budget: budget,
                installation: installation
            )
        } catch {
            selfReplacementGate.release(timedOut: Self.isTimeoutInstallError(error))
            throw error
        }
        selfReplacementGate.release(timedOut: false)
    }

    /// 自替换安装的等待看门狗。
    ///
    /// 与 `offThread` 的差别是**要害**：`offThread` 走 `HardTimeout.run` 的默认
    /// `cancelsWorkOnTimeout: true`，超时会把承载 `stageAndInstall` 的任务 cancel 掉。
    /// 同步 FFI 本身响应不了取消，但 Rust 侧一旦把取消信号当作「调用方放弃」来清理，
    /// 就会撤销已经下发的 installation_proxy 命令 —— 那是把「可能还在装」变成
    /// 「确定装不上」。自替换只能**停止等待**，绝不能取消工作，所以这里显式传 `false`。
    ///
    /// 超时后**不重试**（R05）：底下那次安装很可能还在跑。
    ///
    /// 旧实现是裸的 `try await installation.value`，安装前后一行日志都没有 ——
    /// 真机上卡住时日志里只剩「签名产物核验通过」，无法归因。现在等待期间每 15 秒心跳。
    private func waitForSelfReplacement(
        bundleID: String,
        context: String,
        budget: Double,
        installation: Task<Void, Error>
    ) async throws {
        let startedAt = Date()
        await log("开始自替换安装：\(bundleID)，\(context)，等待上限 \(Int(budget)) 秒")
        let heartbeat = beginInstallHeartbeat("自替换安装", budget: budget)
        defer { heartbeat.cancel() }
        do {
            // 返回值刻意用 Bool 而不是 Void：`HardTimeout.run` 的 T 需要 Sendable，
            // 写成 Void 会让「Void 是否满足 Sendable」变成编译期的不确定项。
            _ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: false) {
                try await installation.value
                return true
            }
        } catch is HardTimeout.TimeoutError {
            await log(
                "自替换安装等待超时：已等待 \(Int(budget)) 秒仍未返回，已停止等待。"
                + "底层 installation_proxy 调用不会被取消（同步 FFI 无取消机制），也不会重试",
                level: .warning,
                code: Self.installTimeoutFailure.code
            )
            throw Self.installTimeoutFailure
        } catch {
            await log(
                "自替换安装调用抛错：\(bundleID)，耗时 \(Self.elapsedText(since: startedAt))，"
                + "原因：\(Self.diagnostic(error))",
                level: .error
            )
            throw error
        }
        await log("自替换安装调用已返回：\(bundleID)，耗时 \(Self.elapsedText(since: startedAt))")
    }

    /// 仅上传暂存（两阶段诊断路径；主链路走 install() 的合并调用）。
    /// 走缓存隧道会话，含同连接回读校验（大小不一致立即抛错，不把截断包留给 installd）。
    func pushIpa(ipaData: Data, bundleID: String) async throws {
        #if !targetEnvironment(simulator)
        guard await isReady() else { throw Self.channelNotReadyFailure }
        let ipaMB = Double(ipaData.count) / 1_000_000
        // 上传含全量回读校验，总量约为单向上传的 2 倍（封顶 30 分钟）
        let pushTimeout = Self.uploadBudgetSeconds(ipaMB: ipaMB)
        let maxAttempts = ipaMB > 100 ? 2 : 4
        var lastError: Error?
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
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
            try Task.checkCancellation()
            do {
                // 每次安装前重置Install提供者，避免使用已断开的RSD缓存连接
                // 推送大文件后RSD连接可能超时断开，isReady()只检查TCP不检查RSD服务
                Install.resetProvider()
                if isSelfReplacement {
                    try await runSelfReplacementInstall(
                        bundleID: bundleID,
                        context: "使用已暂存包，第 \(attempt)/3 次",
                        budget: installTimeout,
                        start: { try Minimuxer.installIpa(bundleId: bundleID) }
                    )
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
                // 自替换被闸门拒绝：重试只会被同一个闸门再拒一次，
                // 且重试前的 reset 会把可能仍在跑的安装连接拆掉 —— 原样抛出。
                if Self.isSelfReplacementBusyError(error) {
                    throw error
                }
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
    ///
    /// 无进度回调的版本**转发**到带进度的实现，不再各写一份：
    /// 两个重载各自维护「自替换必须带看门狗、必须记日志、必须单飞」这套规则，
    /// 迟早会漂移成「修了一个、漏了另一个」—— 本仓库反复踩过这个坑
    ///（`InstallStageBridge` 的注释里也记着同一类教训）。
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws {
        try await install(
            ipaData: ipaData,
            bundleID: bundleID,
            isSelfReplacement: isSelfReplacement,
            onProgress: { _ in }
        )
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
        // 合并调用 = 上传（对齐原 push 预算，封顶 30 分钟）+ 安装（600 秒）
        let mergedTimeout = Self.mergedInstallBudgetSeconds(ipaMB: ipaMB)
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                // 第一次尝试前做一次**有界**的缓存会话活性探测。
                // 只记日志、不改行为 —— 理由见 `probeCachedSessionIfStale()` 的说明。
                if attempt == 1 { await probeCachedSessionIfStale() }
                let syncProgress: @Sendable (Double) -> Void = { [onProgress] p in
                    // 上传进度 0→100% 逐值透传；到达 100%（p == 1.0）即视为上传结束、立即
                    // 发 1.01 把阶段切到「正在安装」，而不是等 Rust 在预检（连 instproxy +
                    // lookup + afcd 快照）之后才发的 101 哨兵——预检在无线配对 + 大文件 +
                    // 设备 IO 繁忙时可长达数十秒，进度条会假停在 100% 干等。后续 101 哨兵
                    // 到达时 stage 已是 .installing，切阶段逻辑幂等无副作用。
                    // 自更新同样只更新阶段，不再主动挂起承载安装连接的进程。
                    if p >= 1.0 {
                        Task { await onProgress(1.01) }
                        return
                    }
                    Task { await onProgress(p) }
                }
                if isSelfReplacement {
                    // 自替换也必须让 installation_proxy 完整返回；iOS 成功替换应用时会自然
                    // 终止旧进程。提前 suspend 会冻结当前连接并留下旧 profile。
                    try await runSelfReplacementInstall(
                        bundleID: bundleID,
                        context: "包 \(Self.megabyteText(ipaMB))，第 \(attempt)/\(maxAttempts) 次",
                        budget: mergedTimeout,
                        start: {
                            try installIPAUsingActivePairingTransport(
                                bundleID: bundleID,
                                ipaData: ipaData,
                                progress: syncProgress
                            )
                        }
                    )
                } else {
                    await log(
                        "开始安装：\(bundleID)，包 \(Self.megabyteText(ipaMB))，"
                        + "第 \(attempt)/\(maxAttempts) 次，等待上限 \(Int(mergedTimeout)) 秒"
                    )
                    let startedAt = Date()
                    // 与自替换共用同一个心跳：安装阶段 installd 不回报进度，
                    // 没有它，一次卡住的普通安装在日志上就是一段**完全空白**
                    // （2026-09-17 真机卡了 9 分多钟，导出的日志里一行都没有）。
                    let heartbeat = beginInstallHeartbeat("安装", budget: mergedTimeout)
                    defer { heartbeat.cancel() }
                    let outcome = await offThread(seconds: mergedTimeout) {
                        try installIPAUsingActivePairingTransport(
                            bundleID: bundleID,
                            ipaData: ipaData,
                            progress: syncProgress
                        )
                    }
                    if case .some(.failure(let installError)) = outcome {
                        await log(
                            "安装调用抛错：\(bundleID)，耗时 \(Self.elapsedText(since: startedAt))，"
                            + "原因：\(Self.diagnostic(installError))",
                            level: .error
                        )
                        throw installError
                    }
                    guard outcome != nil else {
                        await log(
                            "安装等待超时：\(bundleID)，已等待 \(Int(mergedTimeout)) 秒",
                            level: .warning,
                            code: Self.installTimeoutFailure.code
                        )
                        throw Self.installTimeoutFailure
                    }
                    await log("安装调用已返回：\(bundleID)，耗时 \(Self.elapsedText(since: startedAt))")
                }
                return
            } catch {
                lastError = error
                guard attempt < maxAttempts else { break }
                // 超时必须按「确定性拒绝」处理 —— 立即终止，不再重传重试（R05）。
                // 原因见 isTimeoutInstallError 的注释：底下那次安装很可能还在跑。
                // 原样抛出而不是走末尾的 installationFailure 归类：超时文案本身就是
                // 给用户看的解释（含「已停止等待、不会重试」），归类会把它改写成
                // 泛泛的「安装失败」并丢掉恢复指引。
                if Self.isTimeoutInstallError(error) {
                    throw error
                }
                // 自替换被闸门拒绝：重试只会被同一个闸门再拒一次，
                // 而重试路径里的 Minimuxer.reset() 还会把可能仍在跑的安装连接拆掉。
                if Self.isSelfReplacementBusyError(error) {
                    throw error
                }
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
            // ⚠️ **必须有界**（2026-09-17 补）：`lookupApp` 是同步阻塞 FFI，
            // 在一条已死的会话上**不报错、只阻塞到操作系统放弃** ——
            // 与安装路径同一个失败模式，而这里还是**循环里的 8 次**。
            // 超时/报错一律按「这次没查到」处理：循环本身会重试，
            // 8 次都没查到就按「验证失败」抛错（与原先语义一致，只是变成有界）。
            let probe = await offThread(seconds: BlockingCall.queryTimeoutSeconds) {
                Minimuxer.lookupApp(bundleId: bundleID) != nil
            }
            if case .some(.success(true)) = probe { return }
            try? await Task.sleep(for: .milliseconds(650))
        }
        throw ImportFailure(
            title: "安装后验证失败",
            reason: "iOS 安装服务未返回已安装的 Bundle ID（\(bundleID)）。",
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
                reason: "当前 iPhone 的配对信息不可用或已失效，无法用于安装。",
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
            title: "无法连接到设备",
            reason: "无法连接设备，且未能识别具体原因。请确认 iPhone 已解锁、已连接 Wi-Fi，并检查是否打开 LocalDevVPN（免费账号需先安装并打开外部 LocalDevVPN 软件）。",
            recovery: "检查是否打开 LocalDevVPN",
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

        // 1b) DRM 元数据残留（SC_Info 里登记的 sinf 路径越界）：installd 无法捕获 sinf。
        //     真机实测（构建 184，源阅读）：ApplicationSINFCaptureFailed
        //     (Root sinf URL points outside of bundle)。
        //     ⚠️ 与分支 2 分开的理由：这不是「免费账号 3 应用上限 / 签名校验失败」，
        //     给用户的动作完全不同（换账号 / 卸载 App 都无效，该包必须重新砸壳导出）。
        //     同一份 IPA 必然同错 ⇒ `isTerminalInstallError` 也把 sinf 列为确定性拒绝。
        if lower.contains("sinf") {
            return ImportFailure(
                title: "安装被 iOS 拒绝（DRM 元数据）",
                reason: "IPA 内残留 App Store 的 DRM 元数据（SC_Info），iOS 无法从中捕获签名信息。\(detail)",
                recovery: "该 IPA 需先用砸壳工具重新导出（去掉 SC_Info）后再签名",
                code: "SEAL-INSTALL-702f"
            )
        }

        // 2) 完整性校验失败 / 免费账号 3 应用上限（installd 的 APIInternalError /
        //    ApplicationVerificationFailed——免费上限的设备级拒绝就是它）
        if lower.contains("integrity")
            || lower.contains("could not be verified")
            || lower.contains("cannot be verified")
            || lower.contains("applicationverificationfailed")
            || lower.contains("verificationfailed")
            || lower.contains("failed to verify")
            || lower.contains("code signature")
            || lower.contains("signed resource")
            || lower.contains("invalidsignature")
            || lower.contains("profileexpired")
            || lower.contains("untrusted")
            || lower.contains("maximum")
            || lower.contains("limit")
            || detail.contains("无法验证")
            || detail.contains("无法安装")
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
                recovery: "检查 Wi-Fi 连接后重试；大文件安装请保持 Seal 在前台",
                code: "SEAL-INSTALL-702d"
            )
        }

        return ImportFailure(
            title: "安装失败",
            reason: "设备返回：\(detail)",
            recovery: "确认设备已信任、存储空间充足后重试",
            code: "SEAL-INSTALL-702"
        )
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
                    reason: "LocalDevVPN 虽显示连接，但设备服务端口暂时不可达。请检查 VPN 是否正常连接、网络是否稳定后重试。\(suffix)",
                    recovery: "检查是否打开 LocalDevVPN",
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
        recovery: "使用配对助手连接 iPhone 后重试",
        code: "SEAL-PAIR-203b"
    )

    private static let vpnTunnelUnavailableFailure = ImportFailure(
        title: "LocalDevVPN 未就绪",
        reason: "本地隧道未就绪，无法连接设备。免费账号签名的 Seal 需先安装并打开外部 LocalDevVPN 软件；付费账号的 Seal 会自动拉起内置隧道，请检查 VPN 是否已开启，并确认已连接 Wi-Fi。",
        recovery: "检查是否打开 LocalDevVPN",
        code: "SEAL-INSTALL-701"
    )

    private static let deviceNotRespondingFailure = ImportFailure(
        title: "设备未响应",
        reason: "设备未响应。请确认 iPhone 已解锁、已连接 Wi-Fi，并检查是否打开 LocalDevVPN（免费账号需先安装并打开外部 LocalDevVPN 软件）。",
        recovery: "检查是否打开 LocalDevVPN",
        code: "SEAL-INSTALL-708"
    )

    private static let channelNotReadyFailure = ImportFailure(
        title: "设备连接失败",
        reason: "无法建立到设备的连接（超时、网络不可达或无设备）。请确认 iPhone 已解锁、已连接 Wi-Fi，并检查是否打开 LocalDevVPN（免费账号需先安装并打开外部 LocalDevVPN 软件）。",
        recovery: "检查是否打开 LocalDevVPN",
        code: "SEAL-INSTALL-706b"
    )

    private static let channelTimeoutFailure = ImportFailure(
        title: "本地通道连接超时",
        reason: "本地隧道在限定时间内未就绪，已自动重试过。仍失败请确认已连接 Wi-Fi，并检查是否打开 LocalDevVPN（免费账号需先安装并打开外部 LocalDevVPN 软件）。",
        recovery: "检查是否打开 LocalDevVPN",
        code: "SEAL-INSTALL-706t"
    )

    /// 安装等待超时的用户提示。
    ///
    /// ## ⚠️ 文案必须与**实际行为**一致
    ///
    /// 2026-09-17 发现这里写着「**系统已自动重试**」，而超时路径其实是
    /// **原样抛出、不重试**的（`isTimeoutInstallError` 在重试循环里直接 `throw`，
    /// 理由见 R05：底下那次安装很可能还在跑，重试会在同一个 Bundle ID 上
    /// 造出第二个 installd 命令）。用户读到「已自动重试」会**继续等一个并不存在的重试**。
    ///
    /// 「超过 10 分钟」也是错的：等待上限按包大小算
    /// （`mergedInstallBudgetSeconds` = 上传预算 + 600，小包约 804 秒、大包可到 2400 秒）。
    ///
    /// 这类「文案把用户引向错误预期」的错法与 3018 那次同族：不崩、不编译失败，
    /// 只在真机上让人做出错误判断。
    private static let installTimeoutFailure = ImportFailure(
        title: "安装超时",
        reason: "向设备传输并安装应用超过等待上限仍未完成，已停止等待。"
            + "底层安装调用不会被取消（同步调用没有取消机制），也不会自动重试 —— "
            + "所以它可能在你看到这条提示之后仍然完成安装。"
            + "若多次出现，请检查 LocalDevVPN 连接是否稳定后再试（免费账号需使用外部 LocalDevVPN 软件）。",
        recovery: "先等 1–2 分钟，回列表确认这个 App 是否其实已经装上；确认没装上再重试",
        code: "SEAL-INSTALL-702t"
    )

    /// 上一笔自替换安装还没结束就来了第二笔。
    ///
    /// `Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制：一旦卡住，
    /// 上层既等不到它返回、也取消不掉它，于是同一 Bundle ID 上会同时存在两个
    /// installd 安装命令（R05 要防的「第二次安装」）。真机日志里确实出现过
    /// 91 秒内两次提交，所以这里宁可拒绝，也不制造并发安装。
    private static let selfReplacementAlreadyRunningFailure = ImportFailure(
        title: "上一次安装仍在进行中",
        reason: "Seal 的自替换安装还在进行中，本次已跳过，以免同一个应用上出现两次并发安装（会导致安装失败或应用损坏）。同步安装调用没有取消机制，请完全退出并重新打开 Seal 后再试。",
        recovery: "重新启动 Seal 后再试",
        code: "SEAL-INSTALL-738"
    )
}
