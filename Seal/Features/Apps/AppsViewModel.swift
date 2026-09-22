import Combine
import Foundation
@preconcurrency import Minimuxer

@MainActor
final class AppsViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case committing
    }

    enum SigningChannelStatus: Equatable {
        case idle
        case connecting
        case ready
        case unavailable
    }

    @Published private(set) var apps: [AppRecord]
    @Published private(set) var accounts: [AppleAccountRecord]
    @Published private(set) var fullAccountEmails: [UUID: String] = [:]
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var iconData: [UUID: Data]
    @Published private(set) var phase: Phase
    @Published var isImporterPresented = false
    @Published var isImportSheetPresented: Bool
    @Published private(set) var sheetDraft: ImportDraft?
    @Published private(set) var sheetFailure: ImportFailure?
    @Published var alertFailure: ImportFailure?
    @Published var accountSelectionApp: AppRecord?
    @Published var selectedOperationApp: AppRecord?
    @Published var signingSession: SigningSession?
    @Published var batchRefreshSession: BatchRefreshSession?
    @Published private(set) var importCompletionCount = 0
    @Published private(set) var lastImportCompletedInstalledApp = false
    @Published var shouldOpenSettings = false
    @Published var requestedSettingsRoute: SettingsRoute?
    @Published private(set) var signingChannelStatus: SigningChannelStatus = .idle
    @Published private(set) var installingCachedPackageAppID: UUID?

    private struct PendingTeamSwitch {
        let app: AppRecord
        let account: AppleAccountRecord
        let requestedBundleIdentifier: String?
        let completionMode: SigningCompletionMode
    }
    private var pendingTeamSwitch: PendingTeamSwitch?

    private let workflow: ImportWorkflow?
    private let appStore: (any AppStore)?
    private let fileStore: AppFileStore?
    private let accountRepository: (any AccountRepository)?
    private let keychain: KeychainVault?
    private let signingCoordinator: SigningCoordinator?
    private let installChannel: (any InstallChannel)?
    private let renewalCoordinator: RenewalCoordinator?
    private let logStore: SealLogStore?
    private let signingHistoryStore: SigningHistoryStore?
    private let notificationScheduler: ExpiryNotificationScheduler?
    private let notificationPreferences: NotificationPreferences?
    private let signingPreferenceStore: SigningPreferenceStore?
    private let operationCoordinator: OperationCoordinator?
    private let maintenanceJob: AppMaintenanceJob?
    private var signingTask: Task<Void, Never>?
    private var batchRefreshTask: Task<Void, Never>?
    private var channelTask: Task<Bool, Never>?
    /// 「已安装列表对账」的**单飞闸门**（见 `reconcileInstalledAppsWithDevice`）。
    /// 该函数有三个触发点（启动 / 回到前台 / 下拉刷新），而每次探测是一条最长 15 秒、
    /// **不可取消**的同步 FFI ⇒ 并发跑只会互相拖慢，且各自独立下结论。
    private var isReconcilingInstalledApps = false
    /// 「撤销并继续签名」（SEAL-CERT-204e）确认后，因证书被撤而失效、待自动重签的已装 App。
    /// 仅本次签名重试成功后才会消费；重试失败时清空并提示手动续签。
    private var certificateSacrificeResignQueue: [UUID] = []
    private var pendingVPNAction: PendingVPNAction?
    private var hasLoaded = false
    private var loadGeneration = 0
    // 自更新下载导入完成后，自动打开签名抽屉（仅 Seal 自身更新触发）
    private var autoOpenSigningAfterImport = false

    private enum PendingVPNAction {
        case signing(
            AppRecord,
            accountID: UUID?,
            requestedBundleIdentifier: String?,
            completionMode: SigningCompletionMode
        )
        case batch
    }

    init(
        workflow: ImportWorkflow,
        appStore: any AppStore,
        fileStore: AppFileStore,
        accountRepository: any AccountRepository,
        keychain: KeychainVault,
        signingCoordinator: SigningCoordinator,
        installChannel: any InstallChannel,
        renewalCoordinator: RenewalCoordinator,
        logStore: SealLogStore,
        signingHistoryStore: SigningHistoryStore,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        signingPreferenceStore: SigningPreferenceStore,
        operationCoordinator: OperationCoordinator? = nil,
        maintenanceJob: AppMaintenanceJob? = nil
    ) {
        self.workflow = workflow
        self.appStore = appStore
        self.fileStore = fileStore
        self.accountRepository = accountRepository
        self.keychain = keychain
        self.signingCoordinator = signingCoordinator
        self.installChannel = installChannel
        self.renewalCoordinator = renewalCoordinator
        self.logStore = logStore
        self.signingHistoryStore = signingHistoryStore
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.signingPreferenceStore = signingPreferenceStore
        self.operationCoordinator = operationCoordinator
        self.maintenanceJob = maintenanceJob
        apps = []
        accounts = []
        iconData = [:]
        phase = .idle
        isImportSheetPresented = false
    }

    init(startupFailure: ImportFailure) {
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        maintenanceJob = nil
        apps = []
        accounts = []
        iconData = [:]
        phase = .idle
        isImportSheetPresented = false
        alertFailure = startupFailure
    }

    private init(apps: [AppRecord], draft: ImportDraft?) {
        alertFailure = nil
        workflow = nil
        appStore = nil
        fileStore = nil
        accountRepository = nil
        keychain = nil
        signingCoordinator = nil
        installChannel = nil
        renewalCoordinator = nil
        logStore = nil
        signingHistoryStore = nil
        notificationScheduler = nil
        notificationPreferences = nil
        signingPreferenceStore = nil
        operationCoordinator = nil
        maintenanceJob = nil
        self.apps = apps
        accounts = []
        iconData = [:]
        phase = .idle
        sheetDraft = draft
        isImportSheetPresented = draft != nil
        hasLoaded = true
    }

    var unsignedApps: [AppRecord] {
        let installedKeys = installedAppIdentityKeys
        return apps
            .filter(\.belongsInUnsignedList)
            .filter { $0.userIdentityKeys.isDisjoint(with: installedKeys) }
            .sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }


    private var installedAppIdentityKeys: Set<String> {
        apps
            .filter(\.belongsInInstalledList)
            .reduce(into: Set<String>()) { result, app in
                result.formUnion(app.userIdentityKeys)
            }
    }

    var installedApps: [AppRecord] {
        apps.filter(\.belongsInInstalledList)
            .sorted { lhs, rhs in
                if lhs.isSeal != rhs.isSeal { return lhs.isSeal }
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }

                let lhsRank = installedSortRank(for: lhs)
                let rhsRank = installedSortRank(for: rhs)
                if lhsRank != rhsRank { return lhsRank > rhsRank }

                let lhsExpiry = lhs.expiryDate ?? .distantPast
                let rhsExpiry = rhs.expiryDate ?? .distantPast
                if lhsExpiry != rhsExpiry { return lhsExpiry > rhsExpiry }

                if lhs.importedAt != rhs.importedAt { return lhs.importedAt > rhs.importedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var hasPendingVPNRecovery: Bool {
        pendingVPNAction != nil
    }

    var isBatchRefreshActive: Bool {
        batchRefreshTask != nil
    }

    var availableAccounts: [AppleAccountRecord] {
        accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
    }

    // Kept for existing call sites; locally available accounts remain selectable
    // while offline even if a fresh Portal validation has not run yet.
    var verifiedAccounts: [AppleAccountRecord] { availableAccounts }

    func selectActiveAccount(id: UUID) async {
        guard availableAccounts.contains(where: { $0.id == id }) else { return }
        activeAccountID = id
        await signingPreferenceStore?.setActiveAccountID(id)
    }

    func refreshActiveAccountSelection() async {
        guard let signingPreferenceStore else { return }
        let storedID = await signingPreferenceStore.activeAccountID()
        if let storedID, accounts.contains(where: { $0.id == storedID }) {
            activeAccountID = storedID
        } else if let current = activeAccountID, accounts.contains(where: { $0.id == current }) {
            // Keep the in-memory choice. Do not clear it because connectivity changed.
        } else if activeAccountID == nil {
            activeAccountID = availableAccounts.first?.id
            if storedID == nil {
                await signingPreferenceStore.setActiveAccountID(activeAccountID)
            }
        }
    }

    private func installedSortRank(for app: AppRecord, now: Date = Date()) -> Int {
        guard let expiryDate = app.expiryDate else { return 1 }
        return expiryDate > now ? 2 : 0
    }

    func presentOperation(for app: AppRecord) {
        selectedOperationApp = app
    }

    func dismissOperation() {
        guard signingTask == nil else { return }
        selectedOperationApp = nil
        signingSession = nil
    }

    func beginRenewalDirectly(for app: AppRecord, overrideAccountID: UUID? = nil) async {
        guard app.belongsInInstalledList else {
            presentOperation(for: app)
            return
        }
        // 选择优先级：用户手动覆盖 > 记录账号 > Seal 按 Team 匹配 > 当前活跃账号 > 第一个可选账号
        let accountID: UUID
        if let overrideAccountID,
           accounts.contains(where: { $0.id == overrideAccountID && AccountAvailabilityPolicy.isSelectable($0) }) {
            accountID = overrideAccountID
        } else if let recordedAccountID = app.accountID {
            accountID = recordedAccountID
        } else if app.isSeal, let teamID = app.signingTeamID,
                  let matchedID = accounts.first(where: {
                      $0.teamID.caseInsensitiveCompare(teamID) == .orderedSame
                          && AccountAvailabilityPolicy.isSelectable($0)
                  })?.id {
            accountID = matchedID
        } else if let activeID = activeAccountID, accounts.contains(where: { $0.id == activeID && AccountAvailabilityPolicy.isSelectable($0) }) {
            accountID = activeID
        } else if let fallbackID = accounts.first(where: { AccountAvailabilityPolicy.isSelectable($0) })?.id {
            accountID = fallbackID
        } else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: "尚未添加可用的 Apple ID，无法续签。",
                recovery: "在「我的」中添加 Apple ID",
                code: "SEAL-AUTH-104"
            )
            return
        }
        await beginSigning(
            for: app,
            accountID: accountID,
            requestedBundleIdentifier: nil,
            completionMode: .signAndInstall
        )
        if signingSession?.app.id == app.id {
            selectedOperationApp = signingSession?.app ?? app
        }
    }

    @discardableResult
    func refreshSigningChannel() async -> Bool {
        if let channelTask {
            return await channelTask.value
        }
        guard let installChannel else {
            signingChannelStatus = .unavailable
            return false
        }
        // 用户主动刷新（VPN 恢复重试、设置页刷新）：先清熔断，保证这次真实重跑诊断，
        // 而不是把 60 秒前的失败原样还回去。
        await installChannel.clearFailureCooldown()

        signingChannelStatus = .connecting
        let task = Task {
            do {
                _ = try await installChannel.start()
                return true
            } catch {
                return false
            }
        }
        channelTask = task
        let ready = await task.value
        channelTask = nil
        signingChannelStatus = ready ? .ready : .unavailable
        return ready
    }

    /// 非阻塞版通道启动：把隧道诊断（reset + RSD 握手 + 轮询，冷启动最长 75s）**丢到后台并行**，
    /// 立刻返回让签名链路先跑起来。
    ///
    /// 旧行为是在签名前 `await refreshSigningChannel()`，于是整段隧道诊断都压在
    /// 「正在连接设备」这一个阶段上 —— 这正是「签名/续签卡在正在连接很久」的根因。
    /// 签名本身（申请证书 / AppID / 描述文件 / codesign）与连设备互不依赖，且安装前
    /// `SigningCoordinator` 会自己 `await installChannel.start()`（900s 缓存命中即返回，
    /// 并由通道层单飞合并并发启动），所以这里不必等。
    func beginSigningChannel() {
        guard channelTask == nil, let installChannel else { return }
        signingChannelStatus = .connecting
        let task = Task { [weak self] () -> Bool in
            let ready: Bool
            do {
                _ = try await installChannel.start()
                ready = true
            } catch {
                ready = false
            }
            await MainActor.run {
                self?.signingChannelStatus = ready ? .ready : .unavailable
                self?.channelTask = nil
            }
            return ready
        }
        channelTask = task
    }

    /// 加载应用列表。**只读**：不写 DB、不动文件。
    ///
    /// 记录恢复 / Seal 自注册 / 孤儿文件清理曾经挂在这里，会让「看列表」这种纯读取动作
    /// 顺手改数据，并与用户正在进行的签名 / 安装交错。它们现在归 `runMaintenanceIfIdle()`，
    /// 由启动流程在空闲时单独执行。
    func load(force: Bool = false) async {
        guard force || hasLoaded == false, let appStore else { return }
        loadGeneration &+= 1
        let generation = loadGeneration

        do {
            let fetched = try await appStore.fetchAll()
            guard generation == loadGeneration else { return }

            var fetchedAccounts = try await accountRepository?.fetchAll() ?? []
            guard generation == loadGeneration else { return }
            fetchedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = fetchedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, fetchedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, fetchedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // 快速显示应用列表
            apps = fetched
            accounts = fetchedAccounts
            activeAccountID = resolvedAccountID
            hasLoaded = true
            restorePendingBatchResultIfNeeded()

            // 后台只做「读取 + 派生」：邮箱、图标、签名历史、通知调度。
            // 每一步都校验加载代次 —— 快速连续 load（导入/签名/删除后都会触发）会同时存在
            // 多个后台任务，旧代次的任务不得回写 UI 状态，否则新数据会被旧数据覆盖。
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                let emails = await self.loadFullAccountEmails(for: fetchedAccounts)
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run { self.fullAccountEmails = emails }

                var icons: [UUID: Data] = [:]
                if let fileStore = self.fileStore {
                    for app in fetched {
                        guard let path = app.displayIconRelativePath,
                              let data = try? await fileStore.read(relativePath: path) else { continue }
                        icons[app.id] = data
                    }
                }
                guard await self.isCurrentLoad(generation) else { return }
                await MainActor.run { self.iconData = icons }

                await self.seedSigningHistoryIfNeeded(apps: fetched, accounts: fetchedAccounts)

                guard await self.isCurrentLoad(generation) else { return }
                if let notificationScheduler = self.notificationScheduler,
                   let notificationPreferences = self.notificationPreferences {
                    do {
                        try await notificationScheduler.reschedule(apps: fetched, enabled: notificationPreferences.isEnabled, leadHours: notificationPreferences.leadHours)
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "通知调度失败", code: "SEAL-NOTIFY-002a")
                    }
                }
            }
        } catch let failure as ImportFailure {
            guard generation == loadGeneration else { return }
            alertFailure = failure
        } catch {
            guard generation == loadGeneration else { return }
            alertFailure = ImportFailure(
                title: "无法读取应用",
                reason: "本地应用数据读取失败，应用列表无法加载。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-APP-002"
            )
        }
    }

    /// 后台任务的加载代次校验。`loadGeneration` 属于主 actor，后台任务必须 `await` 访问。
    private func isCurrentLoad(_ generation: Int) -> Bool {
        loadGeneration == generation
    }

    /// 空闲时执行维护作业：记录恢复 → Seal 自注册 → 孤儿文件清理 → 设备端旧描述文件清理。
    ///
    /// 互斥由 `MaintenanceGate` 保证：非空闲（用户正在签名 / 安装 / 续签，或已有维护作业在跑）
    /// 时直接跳过本轮，**不做任何写入或删除**，也不阻塞用户操作。
    /// 调用方在拿到 `.completed` 之后应当重新 `load()` —— 恢复与自注册可能新增或更新了记录。
    ///
    /// **每个非 `.completed` 的结果都要留痕**：真机日志里「设备端旧描述文件清理」一次都没出现过
    /// （`AppMaintenanceJob` 那条日志是**无条件**写的），而 `.skipped` 原先只有一句 `break`、
    /// `.failed` 只弹窗不写日志 —— 于是「profile 为什么一直在堆」完全无法归因。
    @discardableResult
    func runMaintenanceIfIdle() async -> AppMaintenanceJob.Outcome {
        guard let maintenanceJob else { return .skipped }
        let outcome = await maintenanceJob.run()
        switch outcome {
        case .skipped:
            // 非空闲就跳过是**设计意图**（低优先级、可抢占，永不阻塞用户操作），
            // 但必须能回答「这一轮到底跑没跑」—— 否则 profile 堆积看起来像清理逻辑坏了。
            try? await logStore?.append(
                category: .system,
                message: "维护作业本轮跳过：有前台操作正在进行（下次启动或空闲时再试）",
                code: "SEAL-STORAGE-009"
            )
        case .completed(let report):
            if report.orphans.removedTotal > 0 {
                try? await logStore?.append(
                    category: .system,
                    message: "已清理 \(report.orphans.removedTotal) 个未使用的应用目录",
                    code: "SEAL-STORAGE-005"
                )
            }
            if report.orphans.skippedInFlightTransactions > 0 {
                // 跳过说明确实存在进行中的导入事务；留痕便于排查「为什么没清干净」。
                try? await logStore?.append(
                    category: .system,
                    message: "有 \(report.orphans.skippedInFlightTransactions) 个导入事务目录仍在进行，本轮未清理",
                    code: "SEAL-STORAGE-008"
                )
            }
            if report.profiles.removed > 0 {
                try? await logStore?.append(
                    category: .system,
                    message: "已清理 \(report.profiles.removed) 份设备端旧描述文件",
                    code: "SEAL-PROFILE-321"
                )
            }
        case .aborted(let stage, let reason):
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "维护作业在「\(stage)」阶段被打断（\(reason)），未执行的步骤已跳过",
                code: "SEAL-STORAGE-006"
            )
        case .failed(let failure):
            // 原先只弹窗：用户划掉弹窗后日志里什么都没留下，事后完全查不出是哪一步失败。
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "维护作业失败：\(failure.title)（\(failure.code)）",
                code: "SEAL-STORAGE-010"
            )
            alertFailure = failure
        }
        return outcome
    }

    func fullEmail(for account: AppleAccountRecord) -> String {
        fullAccountEmails[account.id] ?? "未记录"
    }

    private func loadFullAccountEmails(
        for accounts: [AppleAccountRecord]
    ) async -> [UUID: String] {
        guard let keychain else { return [:] }
        var values: [UUID: String] = [:]
        for account in accounts {
            guard let secret = try? await keychain.load(accountID: account.id) else { continue }
            values[account.id] = secret.email
        }
        return values
    }

    func performLightweightLaunchCheck() async {
        await load(force: true)
    }

    func refreshUnsignedApps() async {
        await load(force: true)
    }

    func refreshInstalledApps(userInitiated: Bool = true) async {
        await load(force: true)
        await reconcileInstalledAppsWithDevice(userInitiated: userInitiated)
    }

    /// 与设备对账「记录里的 App 是否还装着」，**不在了才删**本地记录与文件。
    ///
    /// ⚠️ 这条路径 2026-09-21 之前是**静默删数据**：设备查询失败被读成「没装」
    /// （`RustInstProxy.lookup` 把 RPC 失败折成 nil），于是冷启动时通道还没就绪
    /// ⇒ 每条都答「没装」⇒ 整个已安装列表被删（连 Seal 自己都没了），
    /// 而且**不弹窗、不报错、日志里一行都没有**。
    ///
    /// 现在照抄描述文件回收路径（`DeviceProfileCleaner` / `ProfileReclaimPolicy`）
    /// 的三件套：**阳性对照 / 失败即中止整轮 / 决策走纯函数**。
    /// 两条路径调的是**同一个** `Minimuxer.isAppInstalled`，安全网必须同样完整。
    private func reconcileInstalledAppsWithDevice(userInitiated: Bool) async {
        let installedRecords = installedApps
        guard installedRecords.isEmpty == false else { return }

        // ⚠️ **单飞**：本函数有三个触发点 —— 启动（`AppsRootView` 的 `.task`）、
        // 每次回到前台（`scenePhase == .active`）、下拉刷新。
        // 而每次探测是一条最长 15 秒、**不可取消**的同步 FFI
        //（`BlockingCall.bounded` 只是放弃等待，底层仍在跑）。
        // 并发跑时它们互相拖慢，且每一条都用同一条（可能不健康的）通道**独立下结论**
        // ⇒ 结论还会互相矛盾。
        // 早退而不是排队：后到的那次刷新拿到的就是前一次的结论，重复跑没有新信息。
        guard isReconcilingInstalledApps == false else {
            try? await logStore?.append(
                category: .installation,
                level: .info,
                message: "已安装列表对账跳过：上一轮仍在进行",
                code: "SEAL-RECONCILE-001"
            )
            return
        }
        isReconcilingInstalledApps = true
        defer { isReconcilingInstalledApps = false }

        // 导入与已安装 IPA 相同（签名后的 Bundle ID 一致）会残留多条相同身份的记录，
        // iOS 无法并存同 Bundle ID 的应用，这里按身份合并去重，只保留真实存在的一条。
        await removeDuplicateInstalledRecords(installedRecords)

        // ── ① **阳性对照**（整条路径的安全底线）──────────────────────────────
        // Seal 自己**正在运行** ⇒ 它一定装着。先拿它去问：答的不是「已安装」
        // 就说明这条通道此刻在撒谎 ⇒ 本轮**一条记录都不许删**。
        //
        // ⚠️ 这不是防御性编程，是**真机上发生过的**：守卫 `R44` 注释里留着 2026-09-19
        // 的日志「阳性对照未通过（com.mjorb.seal.CT8QZ7352B 被答成未安装）」；
        // 构建 175 实测失败集中在**刚启动**（冷启动后 22 秒 / 自替换重启后 60 秒），
        // 16 秒后再跑就正常 ⇒ **启动早期通道还没就绪**。
        // 而这条路径恰好就在启动时跑 ⇒ 没有对照就等于「每次冷启动清空列表」。
        guard let controlBundleID = Bundle.main.bundleIdentifier,
              controlBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "已安装列表对账中止：取不到自身 Bundle ID，无法做阳性对照",
                code: "SEAL-RECONCILE-002"
            )
            return
        }
        let controlProbe = await InstalledAppDeviceVerifier.probe(bundleIdentifier: controlBundleID)
        let positiveControlPassed = controlProbe == .installed
        guard positiveControlPassed else {
            try? await logStore?.append(
                category: .installation,
                level: .warning,
                message: "已安装列表对账中止：阳性对照未通过"
                    + "（\(controlBundleID)：\(controlProbe.logName)），本轮不删除任何记录",
                code: "SEAL-RECONCILE-003"
            )
            if userInitiated {
                alertFailure = ImportFailure(
                    title: "\u{65E0}\u{6CD5}\u{5237}\u{65B0}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}",
                    reason: "\u{672A}\u{80FD}\u{4ECE}\u{8BBE}\u{5907}\u{8BFB}\u{53D6}\u{771F}\u{5B9E}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}\u{72B6}\u{6001}\u{3002}",
                    recovery: "\u{91CD}\u{65B0}\u{8FDE}\u{63A5}\u{624B}\u{673A}\u{5E76}\u{5B8C}\u{6210}\u{914D}\u{5BF9}\u{540E}\u{91CD}\u{8BD5}",
                    code: "SEAL-INSTALL-707"
                )
            }
            return
        }

        // ── ② 探测：先问完全部记录，再决定删谁 ────────────────────────────
        // **必须分两轮**：边问边删时，「通道在问到第 5 条时坏掉」会让前 4 条已经被删掉，
        // 而它们恰恰是通道还健康时问出来的 —— 但已经收不回来。
        var probes: [(app: AppRecord, probe: ProfileReclaimPolicy.InstallProbe)] = []
        for app in installedRecords {
            // Seal 自身由 `SelfAppRegistrar` 管理，永远不在这条删除路径上
            //（与 `removeDuplicateInstalledRecords` 里的同一句话保持一致）。
            guard app.isSeal == false else { continue }
            guard let bundleIdentifier = installedBundleIdentifier(for: app) else { continue }
            let probe = await InstalledAppDeviceVerifier.probe(bundleIdentifier: bundleIdentifier)
            if probe == .unavailable {
                try? await logStore?.append(
                    category: .installation,
                    level: .warning,
                    message: "已安装列表对账中止：\(bundleIdentifier) 查询失败，本轮不删除任何记录",
                    code: "SEAL-RECONCILE-004"
                )
                if userInitiated {
                    alertFailure = ImportFailure(
                        title: "\u{65E0}\u{6CD5}\u{5237}\u{65B0}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}",
                        reason: "\u{672A}\u{80FD}\u{4ECE}\u{8BBE}\u{5907}\u{8BFB}\u{53D6}\u{771F}\u{5B9E}\u{5DF2}\u{5B89}\u{88C5}\u{5E94}\u{7528}\u{72B6}\u{6001}\u{3002}",
                        recovery: "\u{91CD}\u{65B0}\u{8FDE}\u{63A5}\u{624B}\u{673A}\u{5E76}\u{5B8C}\u{6210}\u{914D}\u{5BF9}\u{540E}\u{91CD}\u{8BD5}",
                        code: "SEAL-INSTALL-707"
                    )
                }
                return
            }
            probes.append((app, probe))
        }

        // ── ③ 决策走纯函数 ────────────────────────────────────────────────
        // `InstalledAppReconcilePolicy.decision` 要求「答未安装」必须**问过阳性对照**
        // 才允许删 —— 单测与守卫都钉在这一句上，别在调用点改成字面量 true。
        var removedCount = 0
        for entry in probes {
            switch InstalledAppReconcilePolicy.decision(
                probe: entry.probe,
                positiveControlPassed: positiveControlPassed
            ) {
            case .keepInstalled:
                continue
            case .removeRecord:
                if await delete(entry.app) { removedCount += 1 }
            case .abortPass:
                // 走不到这里：`.unavailable` 在上面就已经整轮返回了。
                // 保留这个分支是为了让「决策函数的三个分支都被显式处理」在形状上成立 ——
                // 将来有人把上面的拦截挪走时，不会静默漏掉一种结果。
                return
            }
        }

        // 有结论就留痕：这条路径此前是**静默**的（不弹窗、不写日志），
        // 用户只能看到 App 凭空消失，排查时连「跑没跑过」都无从判断。
        try? await logStore?.append(
            category: .installation,
            level: .info,
            message: "已安装列表对账完成：探测 \(probes.count) 条，删除 \(removedCount) 条",
            code: "SEAL-RECONCILE-005"
        )
    }

    private func installedBundleIdentifier(for app: AppRecord) -> String? {
        if let mapped = app.mappedBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           mapped.isEmpty == false {
            return mapped
        }
        if let preferred = app.preferredBundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           preferred.isEmpty == false {
            return preferred
        }
        return nil
    }

    /// 合并本机已安装列表中「签名后 Bundle ID 相同」的重复记录，只保留最可信的一条，
    /// 删除其余重复记录及其文件夹。仅处理非 Seal 的第三方应用；Seal 自身由 SelfAppRegistrar 管理。
    private func removeDuplicateInstalledRecords(_ records: [AppRecord]) async {
        var bestByBundle: [String: AppRecord] = [:]
        var duplicates: [AppRecord] = []
        for record in records where record.isSeal == false {
            guard let bundle = installedBundleIdentifier(for: record)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  bundle.isEmpty == false else {
                continue
            }
            if let existing = bestByBundle[bundle] {
                if preferKeeping(record, over: existing) {
                    duplicates.append(existing)
                    bestByBundle[bundle] = record
                } else {
                    duplicates.append(record)
                }
            } else {
                bestByBundle[bundle] = record
            }
        }
        for duplicate in duplicates {
            _ = await delete(duplicate)
        }
    }

    private func preferKeeping(_ lhs: AppRecord, over rhs: AppRecord) -> Bool {
        if lhs.hasSignedArtifact != rhs.hasSignedArtifact {
            return lhs.hasSignedArtifact
        }
        if lhs.isPinned != rhs.isPinned {
            return lhs.isPinned
        }
        // 设备上只有一个应用，保留 state == .installed 的那条更接近真实状态。
        if lhs.state == .installed && rhs.state != .installed { return true }
        if rhs.state == .installed && lhs.state != .installed { return false }
        let lhsDate = lhs.lastInstalledAt ?? lhs.importedAt
        let rhsDate = rhs.lastInstalledAt ?? rhs.importedAt
        return lhsDate >= rhsDate
    }

    private func seedSigningHistoryIfNeeded(
        apps: [AppRecord],
        accounts: [AppleAccountRecord]
    ) async {
        guard let signingHistoryStore else { return }
        let existingRecords: [SigningHistoryRecord]
        do {
            existingRecords = try await signingHistoryStore.records()
        } catch {
            surfaceHistoryWarning(
                title: "签名历史读取失败",
                reason: "无法读取历史记录，已跳过本次历史回填。",
                code: "SEAL-HISTORY-004"
            )
            return
        }
        let existingKeys = Set(
            existingRecords.compactMap { record -> String? in
                guard let appID = record.appID else { return nil }
                return "\(record.accountID.uuidString)-\(appID.uuidString)"
            }
        )

        for app in apps where app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = accounts.first(where: { $0.id == accountID }) else {
                continue
            }
            let key = "\(accountID.uuidString)-\(app.id.uuidString)"
            guard existingKeys.contains(key) == false else { continue }
            let record = SigningHistoryRecord(
                app: app,
                account: account,
                action: .imported,
                result: .success,
                signedAt: app.importedAt,
                attemptedBundleIdentifier: app.preferredBundleIdentifier,
                finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                lifecycleStatus: .active
            )
            do {
                try await signingHistoryStore.append(record)
            } catch {
                surfaceHistoryWarning(
                    title: "签名历史回填未完成",
                    reason: "部分已有应用的历史记录无法保存。",
                    code: "SEAL-HISTORY-004a"
                )
                return
            }
        }
    }

    func presentImporter() {
        guard phase == .idle else { return }
        isImporterPresented = true
    }

    func importSelectedFile(_ url: URL) async {
        _ = await importSelectedFile(url, autoOpenSigning: false)
    }

    /// 应用内更新下载完成后导入 Seal 自身 IPA，成功后自动打开签名抽屉覆盖安装。
    /// 返回 true 表示 IPA 已成功入库（记录已提交）；失败时保留下载源供用户重试。
    @discardableResult
    func importSelfUpdateFile(_ url: URL) async -> Bool {
        await importSelectedFile(url, autoOpenSigning: true)
    }

    @discardableResult
    private func importSelectedFile(_ url: URL, autoOpenSigning: Bool) async -> Bool {
        guard let workflow, phase == .idle else { return false }
        guard let operationLease = await acquireOperation(.importing) else { return false }
        defer { releaseOperation(operationLease) }
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        alertFailure = nil
        sheetFailure = nil
        isImportSheetPresented = false
        autoOpenSigningAfterImport = autoOpenSigning
        phase = .preparing
        await workflow.prepare(sourceURL: url)
        await consumeWorkflowState()
        if case .completed = await workflow.state {
            return true
        }
        return false
    }

    func confirmImport() async {
        guard let workflow else { return }
        guard let operationLease = await acquireOperation(.importing) else { return }
        defer { releaseOperation(operationLease) }
        guard let draft = sheetDraft else {
            sheetFailure = ImportFailure(
                title: "无法导入 IPA",
                reason: "导入确认信息已失效，请重新选择 IPA。",
                recovery: "重新选择",
                code: "SEAL-IPA-211"
            )
            isImportSheetPresented = true
            phase = .idle
            return
        }

        phase = .committing
        sheetFailure = nil
        isImportSheetPresented = true
        await workflow.confirm(preferredDraft: draft)
        await consumeWorkflowState()
    }

    func retryImport() async {
        guard let workflow, sheetDraft != nil else { return }
        guard let operationLease = await acquireOperation(.importing) else { return }
        defer { releaseOperation(operationLease) }
        phase = .committing
        sheetFailure = nil
        await workflow.retry()
        await consumeWorkflowState()
    }

    func cancelImport() async {
        var cleanupFailure: ImportFailure?
        if let workflow {
            await workflow.cancel()
            cleanupFailure = await workflow.takeCleanupFailure()
        }
        sheetDraft = nil
        sheetFailure = nil
        isImportSheetPresented = false
        phase = .idle
        if let cleanupFailure {
            alertFailure = cleanupFailure
        }
    }

    func handleImporterFailure(_ error: Error) {
        let cocoaError = error as? CocoaError
        guard cocoaError?.code != .userCancelled else { return }
        alertFailure = ImportFailure(
            title: "无法选择 IPA",
            reason: "文件选择失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
            recovery: "重试",
            code: "SEAL-IPA-206"
        )
    }

    func performAlertRecovery(for failure: ImportFailure) {
        alertFailure = nil
        if failure.code == "SEAL-AUTH-115",
           let pending = pendingTeamSwitch {
            pendingTeamSwitch = nil
            let isRenewal = pending.app.belongsInInstalledList
            startSigning(
                app: pending.app,
                account: pending.account,
                requestedBundleIdentifier: isRenewal ? nil : pending.requestedBundleIdentifier,
                completionMode: pending.completionMode
            )
            return
        }
        let recovery = failure.recovery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard recovery != "知道了" else { return }
        if failure.code.hasPrefix("SEAL-IPA-") {
            presentImporter()
        } else if let route = settingsRoute(for: failure) {
            openSettings(route: route)
        }
    }

    func openSettings(route: SettingsRoute) {
        requestedSettingsRoute = route
        shouldOpenSettings = true
    }

    func requestSigning(for app: AppRecord) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        await load(force: true)
        let availableAccounts = accounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
        guard availableAccounts.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: accounts.isEmpty ? "尚未添加 Apple ID" : "Apple ID 需要重新验证",
                recovery: "前往设置",
                code: "SEAL-AUTH-104a"
            )
            return
        }

        // 宽松策略：已安装应用没有记录签名账号时，不拒绝，让用户选择账号进行续签
        continueSigningRequest(for: app, availableAccounts: availableAccounts)
    }

    func beginSigning(
        for app: AppRecord,
        accountID: UUID,
        requestedBundleIdentifier: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall
    ) async {
        guard signingTask == nil, batchRefreshTask == nil else { return }
        let isRenewal = app.belongsInInstalledList
        // 宽松策略：续签时优先用应用记录的账号，没有则用传入的账号
        let resolvedAccountID = (isRenewal ? app.accountID : nil) ?? accountID
        guard var account = verifiedAccounts.first(where: { $0.id == resolvedAccountID }) else {
            alertFailure = ImportFailure(
                title: "Apple ID 不可用",
                reason: isRenewal ? "请选择一个已验证的 Apple ID 进行续签。" : "请选择一个已验证的 Apple ID",
                recovery: "前往设置",
                code: "SEAL-AUTH-104b"
            )
            return
        }

        // Seal 覆盖安装自己（内部更新/自续签）的签名身份 = TeamID + Bundle ID；Bundle ID 由
        // isSeal 分支保留，但 TeamID 取决于所选账号。若 Team 变化，iOS 判为全新应用，清空本地
        // 容器（Accounts.json / Seal.sqlite）并使 Keychain 访问组失配 —— 即「更新后 Apple ID
        // 失效需重新添加」。这里按当前运行 Seal 的真实签名 Team 纠正账号，保住身份；只有找不到
        // 同 Team 账号（如首次从他人账号切到自己账号）才允许切换并提示会重置本地数据。
        if app.isSeal,
           let currentSealTeam = SelfAppMetadata.current()?.signingTeamIdentifier,
           currentSealTeam.isEmpty == false,
           account.teamID.caseInsensitiveCompare(currentSealTeam) != .orderedSame {
            if let sameTeamAccount = verifiedAccounts.first(where: {
                $0.teamID.caseInsensitiveCompare(currentSealTeam) == .orderedSame
            }) {
                account = sameTeamAccount
                try? await logStore?.append(
                    category: .signing,
                    message: "Seal 自更新沿用同 Team 账号 \(sameTeamAccount.maskedEmail)，避免更新后 Apple ID 失效"
                )
            } else {
                pendingTeamSwitch = PendingTeamSwitch(
                    app: app,
                    account: account,
                    requestedBundleIdentifier: requestedBundleIdentifier,
                    completionMode: completionMode
                )
                alertFailure = ImportFailure(
                    title: "更新将重置本地数据",
                    reason: "当前 Seal 由另一 Team 签名，改用所选 Apple ID 覆盖安装会清空已添加的 Apple ID 与已安装应用，需重新添加。",
                    recovery: "继续签名",
                    code: "SEAL-AUTH-115"
                )
                return
            }
        }

        if isRenewal == false {
            await selectActiveAccount(id: account.id)
        }
        startSigning(
            app: app,
            account: account,
            requestedBundleIdentifier: isRenewal ? nil : requestedBundleIdentifier,
            completionMode: completionMode
        )
    }

    private func continueSigningRequest(
        for app: AppRecord,
        availableAccounts: [AppleAccountRecord]
    ) {
        if app.belongsInInstalledList {
            guard let accountID = app.accountID,
                  let account = availableAccounts.first(where: { $0.id == accountID }) else {
                alertFailure = ImportFailure(
                    title: "签名账号不可用",
                reason: "上次签名这个应用的 Apple ID 已被删除或凭据失效。",
                recovery: "在「我的」中重新添加原 Apple ID，或用当前账号重新签名安装",
                    code: "SEAL-AUTH-104c"
                )
                return
            }
            startSigning(app: app, account: account)
        } else if let activeAccountID,
                  let account = availableAccounts.first(where: { $0.id == activeAccountID }) {
            startSigning(app: app, account: account)
        } else if availableAccounts.count == 1, let account = availableAccounts.first {
            startSigning(app: app, account: account)
        } else {
            accountSelectionApp = app
        }
    }

    func resumePendingVPNAction() async {
        guard let action = pendingVPNAction else {
            _ = await refreshSigningChannel()
            return
        }
        alertFailure = nil
        guard await refreshSigningChannel() else {
            presentVPNRecovery(for: action)
            return
        }
        pendingVPNAction = nil
        switch action {
        case .signing(
            let app,
            let accountID,
            let requestedBundleIdentifier,
            let completionMode
        ):
            if let accountID {
                await beginSigning(
                    for: app,
                    accountID: accountID,
                    requestedBundleIdentifier: requestedBundleIdentifier,
                    completionMode: completionMode
                )
            } else {
                await requestSigning(for: app)
            }
        case .batch:
            startBatchRefresh()
        }
    }

    func cancelPendingVPNRecovery() {
        pendingVPNAction = nil
        alertFailure = nil
    }

    func selectAccount(_ account: AppleAccountRecord, for app: AppRecord) {
        accountSelectionApp = nil
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard Task.isCancelled == false else { return }
            await self?.selectActiveAccount(id: account.id)
            self?.startSigning(app: app, account: account)
        }
    }

    func chooseAnotherAccount(for app: AppRecord) async {
        await load(force: true)
        guard accounts.contains(where: { AccountAvailabilityPolicy.isSelectable($0) }) else {
            alertFailure = ImportFailure(
                title: "缺少签名账号",
                reason: accounts.isEmpty ? "尚未添加 Apple ID" : "Apple ID 需要重新验证",
                recovery: "前往设置",
                code: "SEAL-AUTH-104d"
            )
            return
        }
        accountSelectionApp = app
    }

    func retrySigning() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: session.allowsDroppingExtensions
        )
    }

    /// 「重新签名」场景：签名包已缺失/损坏/过期/设备不符/结构不完整，
    /// 必须强制重新走完整签名（不复用本机缓存的旧签名包），否则会对同一个坏包反复安装。
    func retrySigningFromScratch() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: session.allowsDroppingExtensions,
            forceResign: true
        )
    }

    /// 用户已在 Lara 完成 3-App Bypass 后继续签名：跳过免费账号设备上限预检，
    /// 交回 installd 最终裁决（未真正绕过时 installd 仍会拒绝并落到 iOS 拒绝分支）。
    func continueBypassingDeviceLimit() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: session.allowsDroppingExtensions,
            bypassFreeAccountDeviceLimit: true
        )
    }

    func retryWithoutExtensions() {
        guard let session = signingSession else { return }
        restartSigning(
            session,
            allowDroppingExtensions: true
        )
    }

    /// 签名失败页「撤销并继续签名」（SEAL-CERT-204e）一键流程：
    /// 撤销账号下所有本机无私钥的证书 → 自动重试本次签名 → 成功后自动重签因此失效的
    /// 其余已装 App。撤销会让仍用旧证书的 App 立即打不开，确认弹窗已在失败页给出。
    func confirmCertificateSacrificeAndRetry() {
        guard let session = signingSession,
              case .failed(let failure) = session.status,
              failure.code == "SEAL-CERT-204e",
              signingTask == nil,
              batchRefreshTask == nil,
              let signingCoordinator else { return }
        // 走同一条阶段推进路径（而不是直接赋值 `status`）：阶段与「本阶段起点」一起落。
        // 绕过 `updateSigningStage` 的话，进度估算的起点会停在**上一个**阶段 ——
        // 表现是进度从旧阶段的数值开始爬，而不是从本阶段的地板值起。
        updateSigningStage(.preparingCertificate)
        signingTask = Task { [weak self] in
            guard let self else { return }
            var retrySession: SigningSession?
            // defer 保证取消路径也释放 signingTask（restartSigning 有 signingTask == nil 门禁，
            // 漏清会把后续所有重试卡死）；成功时在 defer 里接力重启签名。
            defer {
                signingTask = nil
                if let retrySession {
                    restartSigning(
                        retrySession,
                        allowDroppingExtensions: retrySession.allowsDroppingExtensions
                    )
                }
            }
            do {
                let result = try await signingCoordinator
                    .revokeKeylessCertificatesAfterConfirmation(accountID: session.account.id)
                try? await logStore?.append(
                    category: .signing,
                    message: "用户确认撤销 \(result.revokedSerials.count) 张无钥匙证书，继续本次签名"
                )
                certificateSacrificeResignQueue = result.affectedInstalledApps
                    .map(\.id)
                    .filter { $0 != session.app.id }
                retrySession = session
            } catch is CancellationError {
                signingSession = nil
            } catch let sacrificeFailure as ImportFailure {
                signingSession?.status = .failed(sacrificeFailure)
            } catch {
                signingSession?.status = .failed(Self.unexpectedSigningFailure(error))
            }
        }
    }

    /// 证书撤销流程收尾：本次签名**成功**关闭进度页后，自动批量重签因撤销而失效的
    /// 其余已装 App（复用续签队列，覆盖安装不新增设备槽位）；重试未成功则清空队列，
    /// 留日志引导手动续签。
    private func resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: Bool) {
        let queue = certificateSacrificeResignQueue
        certificateSacrificeResignQueue = []
        guard queue.isEmpty == false else { return }
        guard signingSucceeded else {
            Task { [weak self] in
                try? await self?.logStore?.append(
                    category: .signing,
                    level: .warning,
                    message: "签名重试未成功，\(queue.count) 个因证书撤销而失效的应用请稍后手动续签"
                )
            }
            return
        }
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                message: "本次签名已完成，开始自动重签 \(queue.count) 个因证书撤销而失效的应用"
            )
        }
        startBatchRefresh(appIDs: queue)
    }


    /// 取消当前签名 / 续签（运行中抽屉的「取消」）。软取消，语义同 `cancelBatchRefresh`：
    /// 界面立即关闭、后续步骤停止，但**已经下发到设备的那次安装不会被中断**，
    /// 它会由 installd 自己跑完并按安装校验结果落库。
    func cancelSigning() {
        let appName = signingSession?.app.displayName
        signingTask?.cancel()
        signingSession = nil
        selectedOperationApp = nil
        guard let appName else { return }
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                level: .warning,
                message: "用户取消签名/续签：\(appName)，正在进行的安装会由设备自行完成",
                code: "SEAL-SIGN-012"
            )
            await self?.load(force: true)
        }
    }

    func dismissSigningResult() {
        guard let signingSession else { return }
        if case .running = signingSession.status { return }
        var signingSucceeded = false
        if case .succeeded = signingSession.status { signingSucceeded = true }
        self.signingSession = nil
        selectedOperationApp = nil
        // 进度页关闭后再发起批量重签：两个 sheet 同挂 AppsRootView，
        // 同时弹出会导致批量续签页被盖住。
        resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)
    }

    @discardableResult
    func updatePreferredBundleIdentifier(for app: AppRecord, value: String) async -> Bool {
        guard let appStore, BundleIDPolicy.isEditable(app) else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let validationError = BundleIDPolicy.validationError(for: trimmed) {
            alertFailure = ImportFailure(
                title: "Bundle ID 无效",
                reason: validationError,
                recovery: "修改 Bundle ID",
                code: "SEAL-BUNDLE-001a"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredBundleIdentifier = trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 Bundle ID",
                reason: "Bundle ID 草稿保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-BUNDLE-003"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredDisplayName(for app: AppRecord, name: String) async -> Bool {
        guard let appStore, app.state != .installed, app.hasSignedArtifact == false else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "App 名称无效",
                reason: "App 名称不能为空。",
                recovery: "修改 App 名称",
                code: "SEAL-CUSTOM-001"
            )
            return false
        }
        do {
            var updated = app
            updated.preferredDisplayName = trimmed == app.name ? nil : trimmed
            try await appStore.save(updated)
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 App 名称",
                reason: "App 名称记录保存失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-CUSTOM-002"
            )
            return false
        }
    }

    @discardableResult
    func updatePreferredIcon(for app: AppRecord, data: Data?) async -> Bool {
        guard let appStore, let fileStore, app.state != .installed, app.hasSignedArtifact == false else { return false }
        do {
            var updated = app
            if let data {
                updated.preferredIconRelativePath = try await fileStore.storePreferredIcon(data: data, appID: app.id)
            } else {
                try await fileStore.removePreferredIcon(appID: app.id)
                updated.preferredIconRelativePath = nil
            }
            try await appStore.save(updated)
            if let path = updated.displayIconRelativePath,
               let data = try? await fileStore.read(relativePath: path) {
                iconData[updated.id] = data
            } else {
                iconData[updated.id] = nil
            }
            await load(force: true)
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法保存 App 图标",
                reason: "图标文件无法写入本机存储。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-CUSTOM-003"
            )
            return false
        }
    }

    func retryInstallationForCurrentSigningSession() async {
        guard let session = signingSession else { return }
        await load(force: true)
        guard let signedApp = apps.first(where: { $0.id == session.app.id && $0.hasSignedArtifact }) else {
            alertFailure = ImportFailure(
                title: "无法重新安装",
                reason: "本机没有可用于安装的签名包。",
                recovery: "重新签名",
                code: "SEAL-INSTALL-715"
            )
            return
        }
        let succeeded = await installSignedArtifact(signedApp)
        guard succeeded, let installed = apps.first(where: { $0.id == signedApp.id }) else { return }
        var updatedSession = session
        updatedSession.status = .succeeded(installed)
        signingSession = updatedSession
    }

    func installSignedArtifact(_ app: AppRecord) async -> Bool {
        guard signingTask == nil, batchRefreshTask == nil, installingCachedPackageAppID == nil,
              let signingCoordinator else { return false }
        guard let operationLease = await acquireOperation(.installing, appID: app.id) else { return false }
        defer { releaseOperation(operationLease) }
        installingCachedPackageAppID = app.id
        defer { installingCachedPackageAppID = nil }
        do {
            let installed = try await signingCoordinator.installSignedArtifact(
                appID: app.id,
                progress: { _ in }
            )
            try? await logStore?.append(
                category: .signing,
                message: "已使用本机保存的签名包完成安装：\(installed.displayName)"
            )
            await cleanTemporaryFilesIfNeeded(appID: app.id)
            await load(force: true)
            return true
        } catch let failure as ImportFailure {
            alertFailure = failure
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "签名包安装失败：\(failure.reason)",
                code: failure.code
            )
        } catch {
            alertFailure = Self.unexpectedSigningFailure(error)
        }
        await load(force: true)
        return false
    }


    func delete(_ app: AppRecord) async -> Bool {
        guard let appStore, let fileStore else { return false }
        guard let operationLease = await acquireOperation(.maintainingStorage, appID: app.id) else { return false }
        defer { releaseOperation(operationLease) }
        do {
            try await appStore.delete(id: app.id)
            do {
                try await fileStore.removeApp(appID: app.id)
            } catch {
                do {
                    try await appStore.save(app)
                } catch {
                    alertFailure = ImportFailure(
                        title: "应用删除未完整回滚",
                        reason: "本地文件删除失败，并且应用数据库记录未能恢复。",
                        recovery: "重新打开 Seal 让启动恢复检查本地文件",
                        code: "SEAL-APP-ROLLBACK-001"
                    )
                    await load(force: true)
                    return false
                }
                throw error
            }

            var historyFailure: ImportFailure?
            if let signingHistoryStore {
                do {
                    try await signingHistoryStore.markDeleted(appID: app.id)
                } catch {
                    historyFailure = ImportFailure(
                        title: "应用已删除",
                        reason: "「\(app.displayName)」和本地文件已删除，但签名历史状态未能同步。",
                        recovery: "稍后在设置日志中核对；如仍失败请重新打开 Seal",
                        code: "SEAL-HISTORY-003"
                    )
                }
            }
            await load(force: true)
            if let historyFailure {
                alertFailure = historyFailure
            }
            return true
        } catch {
            alertFailure = ImportFailure(
                title: "无法移除应用",
                reason: "「\(app.displayName)」的本地文件删除失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                recovery: "重试",
                code: "SEAL-APP-003"
            )
            return false
        }
    }

    func refreshAll() {
        startBatchRefresh()
    }

    /// 「重试失败项」：只重试上一轮失败的 App，避免对已成功应用重复签名/上传/安装。
    func refreshFailedItems() {
        let failedIDs = batchRefreshSession?.items
            .filter { $0.state == .failed }
            .map { $0.id } ?? []
        guard failedIDs.isEmpty == false else {
            alertFailure = ImportFailure(
                title: "无法定位失败项",
                reason: "本轮没有可识别的失败应用，未重新处理已成功应用。",
                recovery: "查看续签结果；如确需全部续签，请重新发起全部续签",
                code: "SEAL-RENEW-QUEUE-006"
            )
            return
        }
        startBatchRefresh(appIDs: failedIDs)
    }

    /// 取消本轮批量续签（运行中抽屉的「取消续签」）。
    ///
    /// 语义是**软取消**：立即关掉界面并停止后续项，但**已经开始的那一次安装不会被中断** ——
    /// `Minimuxer.stageAndInstall` 是同步阻塞 FFI，没有取消机制，强行丢弃只会留下
    /// 「包传了一半」的状态。所以：
    ///   - 取消发生在签名/申请证书阶段 → 协程在下一个 `Task.checkCancellation()` 退出，
    ///     队列项被标回 `pending`，下次续签会重新处理；
    ///   - 取消发生在安装阶段 → 本次安装由 installd 自己跑完，应用会正常装上，
    ///     记录在安装校验通过后照常落库（列表刷新即为准）。
    ///
    /// 不做「假装已停止」的假象：日志里明确记一笔，用户与开发者都能对上账。
    func cancelBatchRefresh() {
        let processed = batchRefreshSession?.currentIndex ?? 0
        let total = batchRefreshSession?.total ?? 0
        batchRefreshTask?.cancel()
        batchRefreshSession = nil
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .renewal,
                level: .warning,
                message: "用户取消批量续签：已处理 \(processed)/\(total)，正在进行的安装会由设备自行完成",
                code: "SEAL-RENEW-011"
            )
            await self?.load(force: true)
        }
    }

    func dismissBatchRefresh() {
        guard let batchRefreshSession else { return }
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "批量续签结果抽屉已关闭（\(batchRefreshSession.status)）", code: "SEAL-RENEW-025") }
        switch batchRefreshSession.status {
        case .preparing, .running, .preparingSealUpdate:
            return
        case .completed, .failed:
            clearPendingBatchResult()
            self.batchRefreshSession = nil
        }
    }

    private func startBatchRefresh(appIDs: [UUID]? = nil) {
        guard batchRefreshTask == nil,
              signingTask == nil,
              renewalCoordinator != nil else { return }
        batchRefreshSession = BatchRefreshSession()
        batchRefreshTask = Task { [weak self] in
            guard let self else { return }
            // 不再前置 `await refreshSigningChannel()`：整段隧道诊断（reset + 18s RSD 握手 +
            // 36×500ms 轮询，硬超时 75s）压在「正在连接设备」上，是「点续签后卡很久」的
            // 第二个入口（第一个是单签，见 runSigning）。
            //
            // 改为并行预热：先清熔断（这是用户发起的新会话），再让通道在后台开始诊断，
            // 同时立刻进入续签循环 —— 第一个 App 的证书/描述文件申请与隧道诊断重叠，
            // 安装前 SigningCoordinator 会 await 同一条通道（通道层单飞合并，只诊断一次）。
            //
            // 通道真不可用时不会退化成 N×75s：通道层有失败熔断（60 秒窗口），
            // 第一个 App 付掉诊断代价并写入熔断，后续 App 在窗口内快速失败，
            // 逐个给出可操作文案，而不是整批卡死在一个阶段上。
            await self.installChannel?.clearFailureCooldown()
            self.beginSigningChannel()
            await self.runBatchRefresh(appIDs: appIDs)
        }
    }

    private func presentVPNRecovery(for action: PendingVPNAction) {
        pendingVPNAction = action
        alertFailure = ImportFailure(
            title: "需要恢复连接",
            reason: Self.connectionRecoveryReason,
            recovery: "恢复连接",
            code: "SEAL-INSTALL-706"
        )
    }

    /// 启动恢复：把上一轮被中断留下的 `running` 项降级为 `unknown`。
    ///
    /// 必须放在**启动路径**上，不能等到续签前：`run(queue:)` 会用新队列整体覆盖队列文件，
    /// 一旦开始新一轮，上一轮的 `running` 残留就被冲掉了，再恢复也来不及。
    ///
    /// 恢复只改状态、不做任何签名/安装动作 —— 被中断的项结果未知，贸然重做可能造成
    /// 第二次安装或误删新 profile。此处只让用户知情，由用户决定下一步。
    func recoverInterruptedQueueIfNeeded() async {
        guard let renewalCoordinator else { return }
        // ⚠️ **顺序：先恢复批量续签结果，再结算队列。**
        //
        // Seal 自己替换自己时，进程必然在队列项还是 `running` 的时候被杀 —— 但那一项的
        // 结果其实已经写进持久化载荷了（`SEAL-RENEW-023`，Seal 那一项被显式记成 completed）。
        // 若先降级，同一个批次会给出两份互相矛盾的结论（2026-09-17 真机实测）：
        // 日志报「1 个应用的结果未知，需要重新核验」、队列里留下幽灵条目，
        // 而结果抽屉同时显示 `succeeded: 2, failed: 0`。
        restorePendingBatchResultIfNeeded()
        let settled = settledQueueStates(from: loadPendingBatchResultPayload())
        do {
            let outcome = try await renewalCoordinator.recoverInterruptedQueue(settled: settled)
            if outcome.settledFromResult > 0 {
                // 正常路径也要留痕：否则下次只看到「0 个未知」，
                // 无法判断是「本来就没有被中断的项」还是「被结果结算掉了」。
                try? await logStore?.append(
                    category: .renewal,
                    level: .info,
                    message: "上次续签被中断，但 \(outcome.settledFromResult) 个应用的结果"
                        + "已从持久化载荷结算（不再标为未知）",
                    code: "SEAL-RENEW-026"
                )
            }
            guard outcome.downgraded > 0 else { return }
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "上次续签被中断，\(outcome.downgraded) 个应用的结果未知，需要重新核验",
                code: "SEAL-RENEW-007"
            )
        } catch {
            let nsError = error as NSError
            try? await logStore?.append(
                category: .renewal,
                level: .warning,
                message: "续签队列恢复失败：\(nsError.domain) \(nsError.code)",
                code: "SEAL-RENEW-008"
            )
        }
    }

    /// 从持久化载荷里取出**已经有结论**的项（appID → 队列状态）。
    ///
    /// 判据本体在 `PendingBatchResultPayload`（那里可单测 —— 本类是 `@MainActor`、
    /// 依赖一大堆、测试构造不出来）；这里只留一层转调，免得「同一条规则两份实现」。
    private func settledQueueStates(from payload: [String: Any]?) -> [UUID: RefreshQueueItem.State] {
        PendingBatchResultPayload.settledQueueStates(from: payload)
    }

    private func runBatchRefresh(appIDs: [UUID]? = nil) async {
        guard let renewalCoordinator else { return }
        guard let operationLease = await acquireOperation(.renewing) else {
            batchRefreshSession = nil
            batchRefreshTask = nil
            return
        }
        defer { releaseOperation(operationLease) }
        // 批量续签只使用已保存会话；会话过期会快速失败，并统一引导到「我的」页重新验证。
        do {
            // 局部闭包变量默认逃逸，可直接传给 @escaping 参数的 refreshAll/refreshFailedItems；
            // 声明处不能写 @escaping（仅函数参数位合法）。
            let progress: @Sendable (BatchRefreshEvent) async -> Void = { [weak self] event in
                await self?.consumeBatchEvent(event)
            }
            let result: BatchRefreshResult
            if let appIDs {
                result = try await renewalCoordinator.refreshFailedItems(appIDs: appIDs, progress: progress)
            } else {
                result = try await renewalCoordinator.refreshAll(progress: progress)
            }
            if result.total == 0 {
                batchRefreshSession = nil
                alertFailure = ImportFailure(
                    title: "没有可续签的应用",
                    reason: "当前没有已安装的应用记录",
                    recovery: "知道了",
                    code: "SEAL-RENEW-001"
                )
            } else {
                batchRefreshSession?.status = .completed(result)
                // 计数分桶写进日志：`total == succeeded + failed + needsAction` 不成立就说明
                // 有项被静默丢了 —— 这正是旧实现「批量续签完成」却漏跑应用的病根。
                try? await logStore?.append(
                    category: .renewal,
                    level: (result.failed == 0 && result.needsAction == 0) ? .info : .warning,
                    message: "续签完成：共 \(result.total)，成功 \(result.succeeded)，失败 \(result.failed)，未执行 \(result.needsAction)",
                    code: "SEAL-RENEW-009"
                )
                if result.needsAction > 0 {
                    // 必须显式说出来：这些应用**根本没被处理**，而列表里它们只是「等待中」，
                    // 不说清楚用户会以为整轮都成功了。
                    alertFailure = ImportFailure(
                        title: "有 \(result.needsAction) 个应用本轮未执行",
                        reason: "它们缺少续签所需的前置条件，常见原因是没有可用的 Apple 账号。",
                        recovery: "到「我的」添加并完成账号验证后重新续签",
                        code: "SEAL-RENEW-010"
                    )
                }
                await cleanTemporaryFilesIfNeeded()
            }
            await load(force: true)
        } catch is CancellationError {
            batchRefreshSession = nil
            await load(force: true)
        } catch let failure as ImportFailure {
            batchRefreshSession?.status = .failed(Self.renewalGuidance(for: failure))
        } catch {
            batchRefreshSession?.status = .failed(
                ImportFailure(
                    title: "无法续签应用",
                    reason: "续签队列执行失败。\n[\((error as NSError).domain) \((error as NSError).code)]",
                    recovery: "重试",
                    code: "SEAL-RENEW-500a"
                )
            )
        }
        batchRefreshTask = nil
    }

    /// 批量续签失败文案引导：认证/会话类问题统一引导到“我的”页重新验证；
    /// 网络类与其他失败保留原始可操作信息。
    private static func renewalGuidance(for failure: ImportFailure) -> ImportFailure {
        guard failure.code.hasPrefix("SEAL-AUTH-") else { return failure }
        return ImportFailure(
            title: "Apple ID 会话已过期",
            reason: "批量续签需要有效的登录会话。请前往「我的」页选中该账号重新验证后再续签。",
            recovery: "知道了",
            code: failure.code
        )
    }

    private func consumeBatchEvent(_ event: BatchRefreshEvent) {
        guard batchRefreshSession != nil else { return }
        switch event {
        case .prepared(let apps):
            batchRefreshSession?.items = apps.map {
                BatchRefreshSession.Item(id: $0.id, name: $0.displayName, isSeal: $0.isSeal, state: .waiting)
            }
            batchRefreshSession?.total = apps.count
        case .started(let total):
            batchRefreshSession?.total = total
            batchRefreshSession?.status = .running
        case .appInstallProgress(let index, let total, let app, let progress):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.recordInstallProgress(progress)
        case .appProgress(let index, let total, let app, let stage):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            // 阶段推进集中走 advanceStage：它同时负责安装起点计时与上传进度的清理，
            // 避免「上一项的 87% / 已等待」泄漏到下一项。
            // 它返回的 `Tick` 同时是「是否首次进入该阶段」的判据 —— 下面触发「回主页」要用。
            // `?? .clear` 只是让类型确定下来；函数开头的 `guard batchRefreshSession != nil`
            // 已经保证这里拿得到真实的 `Tick`。
            let tick = batchRefreshSession?.advanceStage(stage) ?? .clear
            let itemState: BatchRefreshSession.Item.State = app.isSeal && (stage == .pushing || stage == .installing) ? .preparingSealUpdate : .running
            if app.isSeal && (stage == .pushing || stage == .installing) {
                batchRefreshSession?.status = .preparingSealUpdate
                persistPendingBatchResultForSealUpdate()
                // 批量续签 Seal：进入 .installing（上传完成）后同样自动回主页触发 iOS 替换，
                // 与单签 SigningProgressView 行为一致。Seal 自续签必然替换运行中的自己，
                // 进程会被新包终止，其后排队的续签项会一并中断（与手按 Home 相同）。
                //
                // `.restart` 闸门：`.installing` 会被**重复推送**，不设闸门就会排出多个
                // 「回主页」任务。这种重复本身是良性的（第一个任务转场后进程被挂起，后续
                // 任务不会执行；转场失败时第一个 `exit(0)` 已结束进程），但**每个任务都会
                // 写一遍「上传完成 / 触发转场」日志**，把真机排查最关键的那段时序信息淹没。
                // 单签那条链路本来就用同一个闸门，这里与它对齐。
                if stage == .installing, tick == .restart {
                    SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)
                }
            } else {
                batchRefreshSession?.status = .running
            }
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: itemState, stage: stage)
        case .appSucceeded(let index, let total, let app):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentInstallProgress = nil
            batchRefreshSession?.installStartedAt = nil
            batchRefreshSession?.succeeded += 1
            updateBatchItem(appID: app.id, name: app.displayName, isSeal: app.isSeal, state: .completed)
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .success,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    finalSignedBundleIdentifier: app.mappedBundleIdentifier,
                    lifecycleStatus: .active
                )
            }
        case .appFailed(let index, let total, let app, let failure):
            batchRefreshSession?.currentIndex = index
            batchRefreshSession?.total = total
            batchRefreshSession?.currentAppName = app.displayName
            batchRefreshSession?.currentInstallProgress = nil
            batchRefreshSession?.installStartedAt = nil
            // 「本轮未执行」不是失败：它根本没被尝试过，下一步动作也不同（去补前置条件，
            // 不是重试）。复用失败事件只是为了让它在列表里可见，计数与状态都必须分开，
            // 否则用户会以为「重试就能好」，而真实原因是缺账号。
            let isNeedsAction = failure.code == RenewalCoordinator.requiresActionCode
            if isNeedsAction == false {
                batchRefreshSession?.failed += 1
            }
            updateBatchItem(
                appID: app.id,
                name: app.displayName,
                isSeal: app.isSeal,
                state: isNeedsAction ? .waiting : .failed
            )
            Task { [weak self] in
                await self?.recordSigningHistory(
                    app: app,
                    action: .renew,
                    result: .failed,
                    attemptedBundleIdentifier: app.preferredBundleIdentifier ?? app.mappedBundleIdentifier,
                    lifecycleStatus: app.belongsInInstalledList ? .active : .unknown,
                    failure: failure
                )
            }
        }
    }

    private func updateBatchItem(
        appID: UUID,
        name: String,
        isSeal: Bool,
        state: BatchRefreshSession.Item.State,
        stage: SigningStage? = nil
    ) {
        guard batchRefreshSession != nil else { return }
        if let index = batchRefreshSession?.items.firstIndex(where: { $0.id == appID }) {
            batchRefreshSession?.items[index].name = name
            batchRefreshSession?.items[index].isSeal = isSeal
            batchRefreshSession?.items[index].state = state
            batchRefreshSession?.items[index].stage = stage
        } else {
            batchRefreshSession?.items.append(.init(id: appID, name: name, isSeal: isSeal, state: state, stage: stage))
        }
    }

    private func persistPendingBatchResultForSealUpdate() {
        guard let session = batchRefreshSession else {
            Task { try? await logStore?.append(category: .renewal, level: .warning, message: "批量续签结果未能持久化：当前没有进行中的会话", code: "SEAL-RENEW-022") }
            return
        }
        let itemPayload = session.items.map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "isSeal": item.isSeal,
                "state": item.isSeal ? "completed" : item.state.storageValue
            ]
        }
        let succeeded = max(session.succeeded + 1, itemPayload.filter { ($0["state"] as? String) == "completed" }.count)
        let payload: [String: Any] = [
            "succeeded": succeeded,
            "failed": session.failed,
            "total": session.total,
            "timestamp": Date().timeIntervalSince1970,
            "items": itemPayload
        ]
        UserDefaults.standard.set(payload, forKey: Self.pendingBatchResultKey)
        UserDefaults.standard.synchronize()
        // 双保险：同时写入 JSON 文件，避免 Seal 自签覆盖安装时 UserDefaults 丢失
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Self.pendingBatchResultFileURL, options: .atomic)
        }
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "批量续签结果已持久化（共 \(session.total)，成功 \(succeeded)，失败 \(session.failed)，明细 \(itemPayload.count) 项）", code: "SEAL-RENEW-023") }
    }

    /// 读取「待恢复的批量续签结果」载荷。
    ///
    /// 优先从文件读取（更可靠，避免 Seal 自签覆盖安装时 UserDefaults 丢失），
    /// 文件没有再回退到 UserDefaults。
    private func loadPendingBatchResultPayload() -> [String: Any]? {
        if let fileData = try? Data(contentsOf: Self.pendingBatchResultFileURL),
           let filePayload = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any] {
            return filePayload
        }
        return UserDefaults.standard.dictionary(forKey: Self.pendingBatchResultKey)
    }

    /// 恢复「批量续签结果」。
    ///
    /// ⚠️ **这里刻意不写轮询日志。** 本函数由 `load()` 每 ~9 秒调用一次，而
    /// 本次启动是否已经把「待恢复的批量续签结果」装进会话。
    ///
    /// 021 的判据是「**确实有待恢复的数据、却被跳过**」—— 那才是「结果丢了」的征兆。
    /// 但「已经恢复进会话」不是跳过：载荷要等抽屉关闭（`dismissBatchRefresh`）才清，
    /// 这中间每次 `load()` 轮询都会看到「载荷还在 + 会话开着」，于是**反复报同一条警告**
    /// （2026-09-17 真机实测）。用这个标志把「已恢复」与「真被跳过」分开。
    private var hasRestoredPendingBatchResult = false

    /// 启动时把上一轮持久化的批量续签结果装回会话。
    ///
    /// 见 `AppsViewModel` 顶部关于「没有成功日志 ≠ 没成功」的说明：
    /// 这条路径是「Seal 自替换把自己杀掉」之后，用户还能看到结果**唯一**的途径。
    /// 「没有待恢复的数据」与「当前有会话在进行」都是**正常路径**。
    /// 2026-09-17 真机日志实测：原先这两条轮询日志占了全部日志的 **30%**（73/244 行），
    /// 把真实信号挤出了只保留 1000 条的环形缓冲。
    /// 唯一值得留痕的是「**确实有待恢复的数据、却被跳过**」—— 那才是「结果丢了」的征兆。
    private func restorePendingBatchResultIfNeeded() {
        let pendingPayload = loadPendingBatchResultPayload()
        guard batchRefreshSession == nil, batchRefreshTask == nil else {
            if pendingPayload != nil, hasRestoredPendingBatchResult == false {
                Task { try? await logStore?.append(category: .renewal, level: .warning, message: "待恢复的批量续签结果被跳过：当前有进行中的会话或结果抽屉仍开着", code: "SEAL-RENEW-021") }
            }
            return
        }
        guard let payload = pendingPayload else { return }
        let succeeded = payload["succeeded"] as? Int ?? 0
        let failed = payload["failed"] as? Int ?? 0
        let total = payload["total"] as? Int ?? max(succeeded + failed, 0)
        var restored = BatchRefreshSession()
        // 旧持久化载荷没有 needsAction 字段，但计数不变量 `成功+失败+未执行 == 总数` 成立，
        // 因此第三个桶可以直接由差值还原（旧载荷的差值本来就是「未完成」）。
        restored.status = .completed(.init(
            total: total,
            succeeded: succeeded,
            failed: failed,
            needsAction: max(0, total - succeeded - failed)
        ))
        restored.currentIndex = total
        restored.total = total
        if let itemPayload = payload["items"] as? [[String: Any]] {
            restored.items = itemPayload.compactMap { item in
                guard let idString = item["id"] as? String,
                      let id = UUID(uuidString: idString),
                      let name = item["name"] as? String else { return nil }
                let isSeal = item["isSeal"] as? Bool ?? false
                let state = BatchRefreshSession.Item.State(storageValue: item["state"] as? String)
                return BatchRefreshSession.Item(id: id, name: name, isSeal: isSeal, state: state)
            }
        }
        batchRefreshSession = restored
        hasRestoredPendingBatchResult = true
        Task { try? await logStore?.append(category: .renewal, level: .info, message: "批量续签结果已从持久化载荷恢复（共 \(total)，成功 \(succeeded)，失败 \(failed)，明细 \(restored.items.count) 项）", code: "SEAL-RENEW-024") }
    }

    private func clearPendingBatchResult() {
        hasRestoredPendingBatchResult = false
        UserDefaults.standard.removeObject(forKey: Self.pendingBatchResultKey)
        try? FileManager.default.removeItem(at: Self.pendingBatchResultFileURL)
    }

    private static let pendingBatchResultKey = "seal.pendingBatchRefreshResult"
    private static var pendingBatchResultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(AppConfiguration.Paths.applicationSupportSubdirectory, isDirectory: true)
            .appendingPathComponent("PendingBatchResult.json")
    }

    private func startSigning(
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        completionMode: SigningCompletionMode = .signAndInstall,
        allowDroppingExtensions: Bool = false
    ) {
        guard signingTask == nil,
              batchRefreshTask == nil,
              signingCoordinator != nil else { return }
        let selectedCertificateSerialNumber: String?
        if app.belongsInInstalledList {
            selectedCertificateSerialNumber = nil
        } else {
            selectedCertificateSerialNumber = try? SigningCertificateSelectionPolicy
                .resolvedSerialNumber(for: app, account: account)
        }
        let resolvedAllowDroppingExtensions = allowDroppingExtensions
            || app.removedExtensionBundleIdentifiers.isEmpty == false
        signingSession = SigningSession(
            app: app,
            account: account,
            requestedBundleIdentifier: requestedBundleIdentifier,
            selectedCertificateSerialNumber: selectedCertificateSerialNumber,
            completionMode: completionMode,
            allowsDroppingExtensions: resolvedAllowDroppingExtensions,
            status: .running(.waitingForChannel)
        )
        let targetBundleIdentifier = (try? BundleIDPolicy.targetBundleIdentifier(
            for: app,
            requestedBundleIdentifier: requestedBundleIdentifier
        )) ?? app.mappedBundleIdentifier ?? app.originalBundleIdentifier
        Task { [weak self] in
            try? await self?.logStore?.append(
                category: .signing,
                message: "准备签名：\(app.name)，Apple ID：\(account.maskedEmail)，Team：\(account.teamID)，证书：\(selectedCertificateSerialNumber ?? "签名时申请")，Bundle ID：\(targetBundleIdentifier)"
            )
        }
        signingTask = Task { [weak self] in
            await self?.runSigning(
                app: app,
                account: account,
                requestedBundleIdentifier: requestedBundleIdentifier,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                completionMode: completionMode,
                allowDroppingExtensions: resolvedAllowDroppingExtensions
            )
        }
    }

    private func restartSigning(
        _ session: SigningSession,
        allowDroppingExtensions: Bool,
        bypassFreeAccountDeviceLimit: Bool = false,
        forceResign: Bool = false
    ) {
        guard signingTask == nil,
              batchRefreshTask == nil,
              signingCoordinator != nil else { return }
        signingSession?.allowsDroppingExtensions = allowDroppingExtensions
        // 同上：阶段推进统一走 `updateSigningStage`，让「本阶段起点」与阶段一起落。
        updateSigningStage(.waitingForChannel)
        signingTask = Task { [weak self] in
            await self?.runSigning(
                app: session.app,
                account: session.account,
                requestedBundleIdentifier: session.requestedBundleIdentifier,
                selectedCertificateSerialNumber: session.selectedCertificateSerialNumber,
                completionMode: session.completionMode,
                allowDroppingExtensions: allowDroppingExtensions,
                bypassFreeAccountDeviceLimit: bypassFreeAccountDeviceLimit,
                forceResign: forceResign
            )
        }
    }

    private func runSigning(
        app: AppRecord,
        account: AppleAccountRecord,
        requestedBundleIdentifier: String? = nil,
        selectedCertificateSerialNumber: String?,
        completionMode: SigningCompletionMode,
        allowDroppingExtensions: Bool,
        bypassFreeAccountDeviceLimit: Bool = false,
        forceResign: Bool = false
    ) async {
        guard let signingCoordinator else { return }
        defer { signingTask = nil }
        let isRenewal = app.belongsInInstalledList
        let operationKind: OperationCoordinator.Kind = isRenewal ? .renewing : .signing
        guard let operationLease = await acquireOperation(operationKind, appID: app.id) else {
            if Task.isCancelled {
                signingSession = nil
            } else if let operationCoordinator {
                signingSession?.status = .failed(operationCoordinator.conflictFailure(requested: operationKind))
            }
            return
        }
        defer { releaseOperation(operationLease) }
        let attemptedBundleIdentifier = try? BundleIDPolicy.targetBundleIdentifier(
            for: app,
            requestedBundleIdentifier: requestedBundleIdentifier
        )
        do {
            updateSigningStage(.waitingForChannel)
            if completionMode == .signAndInstall {
                // 隧道诊断丢到后台并行，签名不再干等整段「正在连接设备」。
                // 安装前 SigningCoordinator 会 await 同一条通道（通道层单飞合并，
                // 不会重复跑诊断）；通道真失败时由安装阶段的诊断错误给出可操作指引。
                //
                // 先清熔断：这是用户发起的新会话，必须真实重跑诊断，
                // 不能复用上一轮批量续签残留的失败 —— 否则用户修好 VPN 再点一次
                // 也会被瞬间拒绝，看起来像 Seal 坏了。
                await installChannel?.clearFailureCooldown()
                beginSigningChannel()
            }
            let completed = try await signingCoordinator.signAndInstall(
                appID: app.id,
                accountID: account.id,
                requestedBundleIdentifier: requestedBundleIdentifier,
                selectedCertificateSerialNumber: selectedCertificateSerialNumber,
                allowDroppingExtensions: allowDroppingExtensions,
                forceResign: forceResign || isRenewal,
                bypassFreeAccountDeviceLimit: bypassFreeAccountDeviceLimit,
                progress: { [weak self] stage in
                    await self?.updateSigningStage(stage)
                },
                onCertificateResolved: { [weak self] serialNumber in
                    await self?.updateResolvedCertificateSerialNumber(serialNumber)
                },
                onInstallProgress: { [weak self] progress in
                    await self?.updateInstallProgress(progress)
                }
            )
            let action: SigningHistoryRecord.Action = isRenewal ? .renew : .sign
            signingSession?.status = .succeeded(completed)
            try? await logStore?.append(
                category: .signing,
                message: isRenewal ? "续签并安装成功" : "签名并安装成功"
            )
            await recordSigningHistory(
                app: completed,
                account: account,
                action: action,
                result: .success,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                finalSignedBundleIdentifier: completed.mappedBundleIdentifier,
                lifecycleStatus: completed.belongsInInstalledList ? .active : .unknown
            )
            await cleanTemporaryFilesIfNeeded(appID: completed.id)
            await load(force: true)
        } catch is CancellationError {
            signingSession = nil
        } catch let failure as ImportFailure {
            signingSession?.status = .failed(failure)

            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: "\(failure.title)：\(failure.reason)",
                code: failure.code
            )
            let latestApp = await latestStoredApp(for: app)
            await recordSigningHistory(
                app: latestApp,
                account: account,
                action: isRenewal ? .renew : .sign,
                result: .failed,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                lifecycleStatus: isRenewal ? .active : .unknown,
                failure: failure
            )
            await load(force: true)
        } catch {
            let failure = Self.unexpectedSigningFailure(error)
            signingSession?.status = .failed(failure)
            try? await logStore?.append(
                category: .signing,
                level: .error,
                message: failure.reason,
                code: failure.code
            )
            let latestApp = await latestStoredApp(for: app)
            await recordSigningHistory(
                app: latestApp,
                account: account,
                action: isRenewal ? .renew : .sign,
                result: .failed,
                attemptedBundleIdentifier: attemptedBundleIdentifier,
                lifecycleStatus: isRenewal ? .active : .unknown,
                failure: failure
            )
            await load(force: true)
        }
    }

    private func latestStoredApp(for fallback: AppRecord) async -> AppRecord {
        guard let appStore,
              let stored = try? await appStore.fetchAll().first(where: {
                  $0.id == fallback.id
              }) else {
            return fallback
        }
        return stored
    }

    private func updateSigningStage(_ stage: SigningStage) {
        let currentStage: SigningStage?
        if case .running(let running) = signingSession?.status {
            currentStage = running
        } else {
            currentStage = nil
        }
        // 起点规则与批量续签共用 InstallStageTimeline：同一阶段被重复推送时不重置，
        // 每次都重置会让「已等待 m:ss」永远停在 0:0x，反而更像卡死。
        let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)
        // ⚠️ **每个阶段真正进入时记一行**（2026-09-18）—— 这是「**分段耗时**」的唯一来源。
        //
        // 背景：`SigningProgressBudget` 的 τ（每阶段时长）现在是**估的**，要靠真机日志里
        // 各阶段的时间戳差来校准。而在此之前 `updateSigningStage` **只改状态、一行都不落**
        // ⇒ 阶段切换在日志里没有任何时间戳 ⇒ 那份数据**根本拿不到**，
        // 三条线（进度 τ 校准 / 大包耗时归因 / 请求量判据）都在等它。
        //
        // ⚠️ **必须排在下面那个 `guard signingSession != nil` 之前**（2026-09-18 真机，构建 133）：
        // **批量续签走的是 `BatchRefreshSession`，`signingSession` 可能为空** ⇒ 原来那个 guard
        // 会让整段直接 return、日志不落 ⇒ 实测整份日志只有 **2 条** `SEAL-STAGE-001`
        //（而且都是 `installing`）✗。而「每阶段耗时」的样本**恰恰主要来自批量续签**
        //（用户最常用的入口）⇒ 日志必须与 session 状态**解耦**。
        //
        // ⚠️ **闸门必须是「阶段真的变了」（`stage != currentStage`），不能用 `tick`**
        //（2026-09-19 真机踩到 ✗）：`InstallStageTimeline.tick` 只对 **`.installing`** 返回
        // `.restart`，**其余阶段一律返回 `.clear`** —— 它是「安装计时起点」的簿记，
        // **不是**「阶段是否切换」✗。拿它当闸门 ⇒ **只有 `installing` 会落日志** ✗✗
        //（真机实测：整份日志只有 1 条 `SEAL-STAGE-001`，正是 `installing` ✓ 完全印证）。
        // 同一阶段会被**重复推送**（安装通道的 >1.0 哨兵 + 签名侧补发），所以闸门仍然需要 ✓。
        // ⚠️ 用 `Task` 是因为本函数是**同步**的（改完 `status` 要立刻返回，不能为了记日志
        // 改成 async 去波及所有调用点）；日志晚几毫秒不影响「算时间戳差」。
        if stage != currentStage {
            let entered = stage
            Task { [logStore] in
                try? await logStore?.append(
                    category: .signing,
                    level: .info,
                    message: "阶段进入：\(entered)",
                    code: "SEAL-STAGE-001"
                )
            }
        }

        guard signingSession != nil else { return }
        signingSession?.installStartedAt = InstallStageTimeline.applied(
            tick,
            startedAt: signingSession?.installStartedAt
        )
        // 当前阶段的起点：进度不再只随阶段跳变，阶段内部要按「已过时间」估算
        // （见 `SigningProgressBudget`），所以每个阶段都要有一个起点。
        // 规则同样抽在 `InstallStageTimeline` 里，理由与上面那条一样：
        // 「起点该不该重置」只许有一处答案。
        signingSession?.stageStartedAt = InstallStageTimeline.stageStart(
            entering: stage,
            currentStage: currentStage,
            previous: signingSession?.stageStartedAt
        )
        signingSession?.status = .running(stage)
        // Seal 自续签 = 覆盖安装运行中的自己：iOS 只有在旧进程让出前台后才完成替换，
        // 所以必须由 Seal 主动「回主页」。
        //
        // 触发点刻意放在**状态层**，而不是 SigningProgressView 的 `.onChange`：
        // 抽屉现在有「取消」按钮（软取消：立即关界面，已下发的安装由 installd 跑完），
        // 用户一旦在 Seal 安装期间点取消，界面就没了 —— 挂在界面上的触发点收不到
        // 后续阶段推进，「回主页」永远不会发生，Seal 的替换会**静默失败**
        //（旧版本继续跑，用户以为更新没生效）。批量续签那条链路本来就是在状态层触发的
        //（见 consumeBatchEvent），这里与它对齐。
        //
        // `.restart` 保证只在**首次**进入安装阶段触发一次：同一阶段会被重复推送
        //（安装通道的 >1.0 哨兵 + 签名侧补发），不设闸门会排出多个「回主页」任务。
        if stage == .installing,
           tick == .restart,
           signingSession?.app.isSeal == true {
            SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)
        }
    }

    // 安装通道 AFC 上传阶段的真实进度（0-1）→ 刷新进度 UI。
    // Rust 上传结束、installd 安装命令即将下发时的哨兵（>1.0，101→1.01）会让进度条
    // 停在 100% 干等 installd 解压/复制，故在这里把阶段切到 .installing（文案「正在安装」），
    // 进度归 1.0 收尾，避免 UI 一直显示「正在传输 100%」。
    private func updateInstallProgress(_ progress: Double) {
        guard signingSession != nil else { return }
        if progress > 1.0 {
            signingSession?.installProgress = 1.0
            if case .running(.pushing) = signingSession?.status {
                // 走同一条阶段推进路径：状态与计时起点一起落，避免「切阶段」和「记起点」
                // 分成两处各写一遍（两处漂移不会编译失败，只会让计时变成假象）。
                updateSigningStage(.installing)
            }
            return
        }
        signingSession?.installProgress = progress
    }

    // SigningCoordinator 在证书序列号确定后回传（actor 上下文 → hop 回 MainActor 更新快照）
    private func updateResolvedCertificateSerialNumber(_ serialNumber: String) {
        signingSession?.selectedCertificateSerialNumber = serialNumber
    }

    private func recordSigningHistory(
        app: AppRecord,
        account explicitAccount: AppleAccountRecord? = nil,
        action: SigningHistoryRecord.Action,
        result: SigningHistoryRecord.Result,
        attemptedBundleIdentifier: String? = nil,
        finalSignedBundleIdentifier: String? = nil,
        lifecycleStatus: SigningHistoryRecord.LifecycleStatus? = nil,
        failure: ImportFailure? = nil
    ) async {
        guard let signingHistoryStore else { return }
        let account = await resolvedHistoryAccount(for: app, explicitAccount: explicitAccount)
        guard let account else { return }
        let record = SigningHistoryRecord(
            app: app,
            account: account,
            action: action,
            result: result,
            attemptedBundleIdentifier: attemptedBundleIdentifier,
            finalSignedBundleIdentifier: finalSignedBundleIdentifier,
            lifecycleStatus: lifecycleStatus,
            errorCode: failure?.code,
            errorReason: failure?.reason
        )
        do {
            try await signingHistoryStore.append(record)
        } catch {
            surfaceHistoryWarning(
                title: "签名历史未保存",
                reason: "签名结果已经完成，但历史记录无法写入。",
                code: "SEAL-HISTORY-005"
            )
        }
    }

    private func resolvedHistoryAccount(
        for app: AppRecord,
        explicitAccount: AppleAccountRecord?
    ) async -> AppleAccountRecord? {
        if let explicitAccount { return explicitAccount }
        guard let accountID = app.accountID else { return nil }
        if let account = accounts.first(where: { $0.id == accountID }) {
            return account
        }
        guard let accountRepository else { return nil }
        do {
            let fetchedAccounts = try await accountRepository.fetchAll()
            return fetchedAccounts.first { $0.id == accountID }
        } catch {
            surfaceHistoryWarning(
                title: "签名历史账号读取失败",
                reason: "无法读取历史记录关联的 Apple ID。",
                code: "SEAL-HISTORY-006"
            )
            return nil
        }
    }

    private func surfaceHistoryWarning(
        title: String,
        reason: String,
        code: String
    ) {
        guard alertFailure == nil else { return }
        alertFailure = ImportFailure(
            title: title,
            reason: reason,
            recovery: "检查本地存储空间后重试",
            code: code
        )
    }

    private func cleanTemporaryFilesIfNeeded(appID: UUID? = nil) async {
        guard UserDefaults.standard.bool(forKey: "behavior.deleteIPAAfterInstall"),
              let fileStore else { return }
        do {
            try await fileStore.clearTemporaryFiles()
            try? await logStore?.append(
                category: .system,
                message: appID == nil ? "安装完成后已清理临时签名工作区" : "安装完成后已清理当前应用临时签名工作区"
            )
        } catch {
            try? await logStore?.append(
                category: .system,
                level: .warning,
                message: "安装完成后清理签名缓存失败",
                code: "SEAL-STORAGE-001"
            )
        }
    }

    private func repairLegacyAccountStatuses(
        _ records: [AppleAccountRecord]
    ) async throws -> [AppleAccountRecord] {
        guard let accountRepository, let keychain else { return records }
        var repaired = records
        for index in repaired.indices where repaired[index].status == .needsVerification {
            let hasLocalSecret = try await keychain.load(accountID: repaired[index].id) != nil
            let status = AccountAvailabilityPolicy.repairedStatus(
                for: repaired[index],
                hasLocalSecret: hasLocalSecret
            )
            guard status != repaired[index].status else { continue }
            repaired[index].status = status
            try await accountRepository.save(repaired[index])
        }
        return repaired
    }

    private func acquireOperation(
        _ kind: OperationCoordinator.Kind,
        appID: UUID? = nil
    ) async -> OperationCoordinator.Lease? {
        guard let operationCoordinator else {
            return .uncoordinated(kind, appID: appID)
        }
        // 自动等待当前操作完成，不弹"暂时无法执行"弹窗
        return await operationCoordinator.beginWaiting(kind, appID: appID)
    }




    private func releaseOperation(_ lease: OperationCoordinator.Lease) {
        operationCoordinator?.end(lease)
    }

    private func settingsRoute(for failure: ImportFailure) -> SettingsRoute? {
        if failure.code.hasPrefix("SEAL-AUTH-") { return .account }
        if failure.code.hasPrefix("SEAL-CERT-") || failure.code.contains("CERT") { return .certificates }
        if failure.code.hasPrefix("SEAL-PAIR-") || failure.code == "SEAL-INSTALL-703" { return .pairing }
        if failure.code.hasPrefix("SEAL-INSTALL-") { return .localDevVPN }
        return nil
    }

    private static func unexpectedSigningFailure(_ error: Error) -> ImportFailure {
        return ImportFailure(
            title: "签名失败",
            reason: "签名流程遇到未预期错误，技术信息已写入脱敏日志。",
            recovery: "重试",
            code: "SEAL-SIGN-500"
        )
    }

    private func consumeWorkflowState() async {
        guard let workflow else { return }
        let workflowState = await workflow.state
        switch workflowState {
        case .idle:
            phase = .idle
        case .preparing:
            phase = .preparing
        case .awaitingConfirmation(let draft):
            sheetDraft = draft
            sheetFailure = nil
            isImportSheetPresented = false
            phase = .committing
            await workflow.confirm(preferredDraft: draft)
            await consumeWorkflowState()
        case .committing(let draft):
            phase = .committing
            sheetDraft = draft
            isImportSheetPresented = true
        case .completed(let record):
            phase = .idle
            sheetDraft = nil
            sheetFailure = nil
            isImportSheetPresented = false
            await load(force: true)
            lastImportCompletedInstalledApp = record.belongsInInstalledList
            importCompletionCount += 1
            if autoOpenSigningAfterImport {
                autoOpenSigningAfterImport = false
                if let refreshed = apps.first(where: { $0.id == record.id }) {
                    selectedOperationApp = refreshed
                }
            }
            if let cleanupFailure = await workflow.takeCleanupFailure() {
                alertFailure = cleanupFailure
            }
        case .failed(let failure):
            phase = .idle
            if sheetDraft == nil {
                alertFailure = failure
            } else {
                sheetFailure = failure
                isImportSheetPresented = true
            }
        }
    }

    private static func exportFileName(for app: AppRecord) -> String {
        let raw = "\(app.displayName)-\(app.version)-Seal.ipa"
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return raw.components(separatedBy: invalid).joined(separator: "-")
    }

    static func uiTestModel(arguments: [String]) -> AppsViewModel? {
        if arguments.contains("--ui-testing-empty") {
            return AppsViewModel(apps: [], draft: nil)
        }

        let appID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let record = AppRecord(
            id: appID,
            originalBundleIdentifier: "com.example.demo",
            name: "Demo",
            version: "1.0",
            buildNumber: "1",
            size: 1_234_567,
            state: .preflightPassed,
            ipaRelativePath: "Apps/\(appID.uuidString)/Original.ipa",
            importedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        if arguments.contains("--ui-testing-imported") {
            return AppsViewModel(apps: [record], draft: nil)
        }
        if arguments.contains("--ui-testing-confirmation") {
            let draft = ImportDraft(
                appID: appID,
                parsedIPA: ParsedIPA(
                    name: "Demo",
                    bundleIdentifier: "com.example.demo",
                    version: "1.0",
                    buildNumber: "1",
                    fileSize: 1_234_567,
                    iconData: nil,
                    extensions: [
                        AppExtensionRecord(
                            name: "Share",
                            originalBundleIdentifier: "com.example.demo.share",
                            kind: .share
                        )
                    ],
                    entitlementKeys: [],
                    importWarnings: []
                ),
                stagedIPA: StagedIPA(
                    id: appID,
                    url: FileManager.default.temporaryDirectory.appending(path: "Demo.ipa")
                )
            )
            return AppsViewModel(apps: [], draft: draft)
        }
        return nil
    }

    private static let connectionRecoveryReason = "请确认已连接 Wi-Fi 并开启 LocalDevVPN。若长时间无响应，请在设置中确认 LocalDevVPN 已连接后重试。"
}
