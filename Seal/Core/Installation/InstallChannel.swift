import Foundation

protocol InstallChannel: Actor {
    func start() async throws -> String
    func diagnose() async -> InstallChannelDiagnostics
    func isReady() async -> Bool
    func storedDeviceIdentifier() async -> String?
    func reset() async
    func pushIpa(ipaData: Data, bundleID: String) async throws
    func installPushedIpa(bundleID: String, isSelfReplacement: Bool) async throws
    func install(ipaData: Data, bundleID: String, isSelfReplacement: Bool) async throws
    func verifyInstalled(bundleID: String) async throws
}

extension InstallChannel {
    func storedDeviceIdentifier() async -> String? { nil }
    func reset() async {}

    /// 带进度回调用法的合并安装默认实现：忽略进度，直接转发到无进度版本。
    /// 已在协议要求中声明，故经 `any InstallChannel` 调用时若具体实现未覆写，
    /// 这里作为默认回退仍可编译（向后兼容）。
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        try await install(
            ipaData: ipaData,
            bundleID: bundleID,
            isSelfReplacement: isSelfReplacement
        )
    }
}
