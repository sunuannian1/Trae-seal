import Foundation

enum AppValidityTone: Equatable, Sendable {
    case success
    case neutral
    case warning
    case danger
}

struct AppValidityPresentation: Equatable, Sendable {
    let text: String
    let detailText: String
    let tone: AppValidityTone
}

enum AppOperationKind: Equatable, Sendable {
    case signing
    case renewal
    case urgentRenewal
    case expiredRenewal
}

struct AppOperationPresentation: Equatable, Sendable {
    let kind: AppOperationKind
    let validity: AppValidityPresentation?

    init(app: AppRecord, now: Date = Date()) {
        guard app.belongsInInstalledList, let expiryDate = app.expiryDate else {
            kind = .signing
            validity = nil
            return
        }

        let interval = expiryDate.timeIntervalSince(now)
        guard interval > 0 else {
            kind = .expiredRenewal
            validity = AppValidityPresentation(text: "已过期", detailText: "已过期", tone: .danger)
            return
        }

        if interval < 86_400 {
            kind = .urgentRenewal
            let hours = max(1, Int(interval / 3_600))
            validity = AppValidityPresentation(text: "\(hours)小时", detailText: "\(hours)小时", tone: .danger)
            return
        }

        let days = max(1, Int(interval / 86_400))
        kind = days <= 3 ? .urgentRenewal : .renewal
        validity = AppValidityPresentation(
            text: "\(days)天",
            detailText: "\(days)天",
            // 充裕期（>3天）用中性陈述，不使用 success 绿色：剩余可续签天数不是一种“成功”，
            // success 语义保留给证书校验可用（CertificateValidationStatus.available）。
            tone: days <= 3 ? .warning : .neutral
        )
    }

    var sheetTitle: String { primaryAction }

    var primaryAction: String {
        switch kind {
        case .signing: "签名并安装"
        case .renewal, .urgentRenewal, .expiredRenewal: "续签并安装"
        }
    }
}

enum AppImportTimeFormatter {
    static func string(
        from date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "今天 \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "昨天 \(time)"
        }
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.calendar = calendar
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "M月d日 HH:mm"
        return dateFormatter.string(from: date)
    }
}


enum ProfileDisplayStatus: Equatable, Sendable {
    case available
    case expiringSoon
    case expired
    case mismatch
    case pendingValidation
    case missing

    var title: String {
        switch self {
        case .available: "可用"
        case .expiringSoon: "临期"
        case .expired: "已过期"
        case .mismatch: "不匹配"
        case .pendingValidation: "待校验"
        case .missing: "未记录"
        }
    }

    var tone: AppValidityTone {
        switch self {
        case .available: .success
        case .expiringSoon: .warning
        case .expired, .mismatch: .danger
        case .pendingValidation, .missing: .neutral
        }
    }
}

enum AppSigningPresentationHelpers {
    static let renewNowAction = "立即续签"
    static let keepSealOpenTip = "请保持 Seal 打开，不要锁屏或切换 App。"

    static func certificateName(serial: String?) -> String {
        guard let serial, serial.isEmpty == false else { return "签名时创建" }
        return "Apple 开发证书 · \(compactSerial(serial))"
    }

    static func compactSerial(_ value: String) -> String {
        let normalized = value.filter(\.isHexDigit).uppercased()
        let source = normalized.isEmpty ? value : normalized
        guard source.count > 8 else { return source }
        return "\(source.prefix(4))…\(source.suffix(4))"
    }

    static func profileStatus(for app: AppRecord, now: Date = Date()) -> ProfileDisplayStatus {
        guard let expiration = app.provisioningProfileExpirationDate ?? app.expiryDate else {
            return app.belongsInInstalledList ? .missing : .pendingValidation
        }
        guard expiration > now else { return .expired }

        if let teamID = app.signingTeamID,
           app.signingTargets.isEmpty == false {
            let hasMatchingTeam = app.signingTargets.contains { target in
                target.teamIdentifier.caseInsensitiveCompare(teamID) == .orderedSame
            }
            if hasMatchingTeam == false { return .mismatch }
        }

        if let signedBundleID = app.mappedBundleIdentifier ?? app.preferredBundleIdentifier,
           app.signingTargets.isEmpty == false {
            let hasMatchingBundleID = app.signingTargets.contains { target in
                target.bundleIdentifier.caseInsensitiveCompare(signedBundleID) == .orderedSame
            }
            if hasMatchingBundleID == false { return .mismatch }
        }

        if let serial = app.certificateSerialNumber, serial.isEmpty == false,
           app.signingTargets.isEmpty == false {
            let expected = SigningCertificateSelectionPolicy.normalizedSerialNumber(serial)
            let hasMatchingCertificate = app.signingTargets.contains { target in
                target.certificateSerialNumbers.contains { value in
                    SigningCertificateSelectionPolicy.normalizedSerialNumber(value) == expected
                }
            }
            if hasMatchingCertificate == false { return .mismatch }
        }

        if let deviceID = app.signedDeviceIdentifier, deviceID.isEmpty == false,
           app.signingTargets.isEmpty == false {
            let hasMatchingDevice = app.signingTargets.contains { target in
                target.deviceIdentifiers.contains { $0.caseInsensitiveCompare(deviceID) == .orderedSame }
            }
            if hasMatchingDevice == false { return .mismatch }
        }

        if expiration.timeIntervalSince(now) <= 4 * 86_400 { return .expiringSoon }
        return .available
    }

    static func profileExpirationDate(for app: AppRecord) -> Date? {
        app.provisioningProfileExpirationDate ?? app.expiryDate
    }
}
