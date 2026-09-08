import Foundation

struct CertificateHealthStatus: Equatable, Sendable {
    enum CheckState: String, Equatable, Sendable {
        case valid
        case invalid
        case unknown
    }

    let serialNumber: String
    let portalPresence: CheckState
    let p12Readable: CheckState
    let localPrivateKey: CheckState
    let keychainReadable: CheckState
    let appleIDMatch: CheckState
    let teamMatch: CheckState
    let expirationDate: Date?
    let lastSignedAt: Date?
    let relatedAppCount: Int
    let usableOnCurrentDeviceAppIDCount: Int?

    var expirationState: CheckState {
        guard let expirationDate else { return .unknown }
        return expirationDate > Date() ? .valid : .invalid
    }

    var isUsable: Bool {
        // 同步失败（unknown）不代表证书失效：仅当 Apple 明确判定证书不存在（invalid）、
        // 本机私钥缺失（invalid）、或证书已过期（invalid）时才判「无效」。
        // 此前强制 portalPresence == .valid，导致网络/限流同步失败时误显示「失效」。
        portalPresence != .invalid
            && p12Readable == .valid
            && localPrivateKey == .valid
            && keychainReadable == .valid
            && appleIDMatch == .valid
            && teamMatch != .invalid
            && expirationState == .valid
    }
}
