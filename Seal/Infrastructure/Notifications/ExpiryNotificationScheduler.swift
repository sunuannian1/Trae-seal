import Foundation
import UserNotifications

@MainActor
final class ExpiryNotificationScheduler {
    private let center: UNUserNotificationCenter
    private let planner: ExpiryNotificationPlanner
    private let identifierPrefix = "com.mjorb.seal.expiry."

    init(
        center: UNUserNotificationCenter = .current(),
        planner: ExpiryNotificationPlanner = ExpiryNotificationPlanner()
    ) {
        self.center = center
        self.planner = planner
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func status(sealEnabled: Bool, schedulingFailure: String? = nil) async -> NotificationScheduleStatus {
        let settings = await center.notificationSettings()
        let authorization: SealNotificationAuthorization
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorization = .allowed
        case .denied:
            authorization = .denied
        case .notDetermined:
            authorization = .notDetermined
        @unknown default:
            authorization = .notDetermined
        }
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(identifierPrefix) }
        let nextDate = pending.compactMap { request in
            (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        }.min()
        return NotificationScheduleStatus(
            sealEnabled: sealEnabled,
            authorization: authorization,
            soundEnabled: settings.soundSetting == .enabled,
            scheduledCount: pending.count,
            nextReminderDate: nextDate,
            schedulingFailure: schedulingFailure
        )
    }

    /// 重排到期提醒，并**把「为什么没排」交出去**。
    ///
    /// - Returns: 本次的处置。调用方据此区分「正常跳过」（第③类，**不要**写 error 日志）
    ///   与「真的失败了」（第②类，由 `throws` 抛出、调用方带底层原因留痕）。
    ///
    /// ⚠️ 授权预检必须在**调用 `add` 之前**：系统没给权限时 `add` 必然抛错，
    /// 而那是**已知条件**（设置页本来就在显示授权状态），不是运行期失败。
    /// 不预检的话，每次刷新都会拿到一条必然失败的 error 日志 ——
    /// 2026-09-22 真机日志里那 **100 条** `SEAL-NOTIFY-002a` 就是这么来的。
    @discardableResult
    func reschedule(
        apps: [AppRecord],
        enabled: Bool,
        leadHours: Int = NotificationPreferences.fixedLeadHours
    ) async throws -> ExpiryNotificationSchedulingPolicy.Decision {
        // ⚠️ 顺序：**先清掉上一轮的残留，再判要不要排**。
        // 授权被撤 / 开关被关之后，上一轮排好的提醒也必须撤掉，
        // 否则「关掉提醒」只影响下一次调度，旧提醒照旧会响。
        let existing = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: existing)

        let authorization = ExpiryNotificationSchedulingPolicy.authorization(
            from: await center.notificationSettings().authorizationStatus
        )
        let decision = ExpiryNotificationSchedulingPolicy.decision(
            enabled: enabled,
            authorization: authorization
        )
        guard decision == .schedule else { return decision }

        for plan in planner.plans(for: apps, now: Date()) {
            let content = UNMutableNotificationContent()
            content.title = "Seal 即将到期"
            let time = Self.timeFormatter.string(from: plan.expiryDate)
            content.body = "明天 \(time) 到期，请及时续签全部。"
            content.sound = .default
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: plan.fireDate
            )
            let request = UNNotificationRequest(
                identifier: identifierPrefix + plan.appID.uuidString,
                content: content,
                trigger: UNCalendarNotificationTrigger(
                    dateMatching: components,
                    repeats: false
                )
            )
            try await center.add(request)
        }
        return decision
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
