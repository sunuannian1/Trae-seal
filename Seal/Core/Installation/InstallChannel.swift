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
    func install(
        ipaData: Data,
        bundleID: String,
        isSelfReplacement: Bool,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws
    func verifyInstalled(bundleID: String) async throws
}

extension InstallChannel {
    func storedDeviceIdentifier() async -> String? { nil }
    func reset() async {}

    /// 带进度回调用法的默认实现：忽略进度，直接转发到无进度版本。
    /// `install(onProgress:)` 已声明为协议要求，`any InstallChannel` 会动态派发到
    /// 具体实现（MinimuxerInstallChannel 覆写版走真实 AFC 上传进度 + 自更新回主屏时机）；
    /// 此默认实现仅供未覆写该方法的遵循类型（如测试桩）向后兼容。
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
