import Foundation

/// 应用全局配置，集中管理所有硬编码的 URL、路径和常量。
enum AppConfiguration {
    // MARK: - 网络服务
    enum Anisette {
        static let officialServerURL = URL(string: "https://ani.sidestore.app")!
        static let officialServerID = "sidestore-app"
        static let officialServerName = "ani.sidestore.app"
    }

    enum AppleServices {
        static let grandSlamLookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!
    }

    // MARK: - 文件路径
    enum Paths {
        static let applicationSupportSubdirectory = "Seal"
        static let accountsFile = "Accounts.json"
        static let pairingFile = "Pairing.plist"
        static let refreshQueueFile = "RefreshQueue.json"
        static let signingHistoryFile = "SigningHistory.json"
        static let logsSubdirectory = "Logs"
        static let minimuxerLogsSubdirectory = "Logs/Minimuxer"
        static let sealLogFile = "Logs/Seal.json"
    }

    // MARK: - 限制
    enum Limits {
        static let maxPairingFileSize = 5 * 1_024 * 1_024 // 5 MB
        static let maxIPASize = 2 * 1_024 * 1_024 * 1_024 // 2 GB
    }

    // MARK: - 时间
    enum Timing {
        static let networkRefreshRounds = 40
        static let networkRefreshDelayMilliseconds = 500
        static let installationVerificationRetries = 8
        static let installationVerificationDelayMilliseconds = 650
    }
}
