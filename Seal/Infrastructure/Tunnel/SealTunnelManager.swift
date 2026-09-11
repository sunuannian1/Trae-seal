import Combine
import Foundation
@preconcurrency import NetworkExtension

enum SealTunnelState: Equatable {
    case idle
    case notConfigured
    case configuring
    case connecting
    case connected
    case disconnecting
    case disconnected
    case unavailable(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .configuring, .connecting, .disconnecting:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class SealTunnelManager: ObservableObject {
    static let shared = SealTunnelManager()

    private enum Configuration {
        static let deviceAddress = "10.7.0.0"
        static let reflectedAddress = "10.7.0.1"
        static let subnetMask = "255.255.255.0"
        static let providerSuffix = ".TunnelProv"

        static let deviceAddressKey = "TunnelDeviceIP"
        static let reflectedAddressKey = "TunnelFakeIP"
        static let subnetMaskKey = "TunnelSubnetMask"
    }

    @Published private(set) var state: SealTunnelState = .idle

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

    init() {
        #if !targetEnvironment(simulator)
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor [weak self] in
                self?.handleStatusChange(connection)
            }
        }
        #endif
    }

    func refresh() {
        #if targetEnvironment(simulator)
        state = .unavailable("Seal Packet Tunnel 只能在真机上验证。")
        #else
        loadManagers(startWhenReady: false)
        #endif
    }

    func start() {
        #if targetEnvironment(simulator)
        state = .unavailable("Seal Packet Tunnel 只能在真机上验证。")
        #else
        guard state.isBusy == false else { return }
        state = .configuring
        loadManagers(startWhenReady: true)
        #endif
    }

    func stop() {
        #if targetEnvironment(simulator)
        state = .unavailable("Seal Packet Tunnel 只能在真机上验证。")
        #else
        guard let manager else {
            state = .notConfigured
            return
        }
        state = .disconnecting
        manager.connection.stopVPNTunnel()
        #endif
    }

    private var providerBundleIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "com.mjorb.seal") + Configuration.providerSuffix
    }

    private var providerConfiguration: [String: Any] {
        [
            Configuration.deviceAddressKey: Configuration.deviceAddress,
            Configuration.reflectedAddressKey: Configuration.reflectedAddress,
            Configuration.subnetMaskKey: Configuration.subnetMask,
        ]
    }

    private var startOptions: [String: NSObject] {
        [
            Configuration.deviceAddressKey: Configuration.deviceAddress as NSString,
            Configuration.reflectedAddressKey: Configuration.reflectedAddress as NSString,
            Configuration.subnetMaskKey: Configuration.subnetMask as NSString,
        ]
    }

    private func loadManagers(startWhenReady: Bool) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            // NetworkExtension documents this completion as running on the caller's
            // main thread. The manager objects are Objective-C reference types that
            // are not Sendable, so keep this transfer explicit and confined to the
            // MainActor task below without any concurrent use.
            nonisolated(unsafe) let loadedManagers = managers
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.state = .failed("无法读取 Seal VPN 配置：\(error.localizedDescription)")
                    return
                }

                let matchingManagers = (loadedManagers ?? []).filter { manager in
                    guard let proto = manager.protocolConfiguration as? NETunnelProviderProtocol else {
                        return false
                    }
                    return proto.providerBundleIdentifier == self.providerBundleIdentifier
                }

                if let existing = matchingManagers.first {
                    self.manager = existing
                    self.apply(connectionStatus: existing.connection.status)
                    if startWhenReady {
                        self.configureAndStart(existing)
                    }
                    return
                }

                self.manager = nil
                if startWhenReady {
                    self.createAndStart()
                } else {
                    self.state = .notConfigured
                }
            }
        }
    }

    private func createAndStart() {
        let manager = NETunnelProviderManager()
        self.manager = manager
        configureAndStart(manager)
    }

    private func configureAndStart(_ manager: NETunnelProviderManager) {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = providerBundleIdentifier
        proto.serverAddress = "Seal Local Network Tunnel"
        proto.providerConfiguration = providerConfiguration

        manager.localizedDescription = "Seal"
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        manager.isOnDemandEnabled = false
        manager.onDemandRules = nil
        state = .configuring

        manager.saveToPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.state = .failed("无法保存 Seal VPN 配置：\(error.localizedDescription)")
                    return
                }

                self.reloadAndStart(manager)
            }
        }
    }

    private func reloadAndStart(_ manager: NETunnelProviderManager) {
        manager.loadFromPreferences { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    self.state = .failed("无法重新载入 Seal VPN 配置：\(error.localizedDescription)")
                    return
                }

                self.manager = manager
                self.startConnection(manager)
            }
        }
    }

    private func startConnection(_ manager: NETunnelProviderManager) {
        switch manager.connection.status {
        case .connected:
            state = .connected
            return
        case .connecting, .reasserting:
            state = .connecting
            return
        case .disconnecting:
            state = .disconnecting
            return
        case .invalid, .disconnected:
            break
        @unknown default:
            break
        }

        state = .connecting
        do {
            try manager.connection.startVPNTunnel(options: startOptions)
        } catch {
            state = .failed("Seal VPN 启动失败：\(error.localizedDescription)")
        }
    }

    private func handleStatusChange(_ connection: NEVPNConnection) {
        guard let manager, connection === manager.connection else { return }
        apply(connectionStatus: connection.status)
    }

    private func apply(connectionStatus: NEVPNStatus) {
        switch connectionStatus {
        case .invalid:
            state = .notConfigured
        case .disconnected:
            state = .disconnected
        case .connecting, .reasserting:
            state = .connecting
        case .connected:
            state = .connected
        case .disconnecting:
            state = .disconnecting
        @unknown default:
            state = .failed("Seal VPN 返回了未知连接状态。")
        }
    }
}
