import SwiftUI
import UIKit

struct LocalDevVPNSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @StateObject private var sealTunnel = SealTunnelManager.shared
    @State private var isChecking = false
    @State private var isCheckingSealTunnel = false
    @State private var shouldCheckSealTunnelAfterConnect = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                hero
                detailsCard
                sealTunnelCard
                actions
            }
            .padding(20)
        }
        .navigationTitle("LocalDevVPN")
        .navigationBarTitleDisplayMode(.inline)
        .sealScreenBackground()
        .task {
            sealTunnel.refresh()
        }
        .onChange(of: sealTunnel.state) { state in
            guard state == .connected, shouldCheckSealTunnelAfterConnect else { return }
            shouldCheckSealTunnelAfterConnect = false
            runSealTunnelChannelCheck()
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: heroIcon)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(statusTitle)
                .font(.title2.weight(.semibold))
            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassSurface(cornerRadius: 24)
    }

    private var detailsCard: some View {
        VStack(spacing: 0) {
            detailRow("设备响应", deviceResponseText, deviceResponseColor)
            Divider()
            detailRow("安装能力", installServiceText, installServiceColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 18)
    }

    private var sealTunnelCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(Color.sealAccent)
                Text("LocalDevVPN")
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(sealTunnelColor)
                    .frame(width: 8, height: 8)
                Text(sealTunnelTitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.sealTextSecondary)
            }

            Text(sealTunnelDetail)
                .font(.footnote)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(sealTunnelActionTitle) {
                startOrCheckSealTunnel()
            }
            .sealPrimaryAction(cornerRadius: 12)
            .disabled(sealTunnel.state.isBusy || isCheckingSealTunnel)

            if sealTunnel.state == .connected {
                Button("停止 LocalDevVPN") {
                    shouldCheckSealTunnelAfterConnect = false
                    sealTunnel.stop()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: 18)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(isChecking ? "正在检测…" : "重新检测") {
                guard isChecking == false else { return }
                isChecking = true
                Task {
                    await viewModel.testConnection()
                    isChecking = false
                }
            }
            .sealPrimaryAction(cornerRadius: 12)
            .disabled(isChecking)
        }
    }

    private func startOrCheckSealTunnel() {
        if sealTunnel.state == .connected {
            runSealTunnelChannelCheck()
            return
        }

        guard sealTunnel.state.isBusy == false else { return }
        shouldCheckSealTunnelAfterConnect = true
        sealTunnel.start()
    }

    private func runSealTunnelChannelCheck() {
        guard isCheckingSealTunnel == false else { return }
        isCheckingSealTunnel = true
        Task {
            await viewModel.testSealTunnelChannel()
            isCheckingSealTunnel = false
        }
    }

    private func detailRow(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 54)
    }

    private var heroIcon: String {
        if case .ready = viewModel.diagnosticState { return "checkmark.circle.fill" }
        if case .running = viewModel.diagnosticState { return "arrow.triangle.2.circlepath" }
        if installFailure != nil { return "exclamationmark.triangle.fill" }
        return "network"
    }

    private var statusTitle: String {
        if case .ready = viewModel.diagnosticState { return "LocalDevVPN已连接" }
        if case .running = viewModel.diagnosticState { return "正在检测连接" }
        if installFailure != nil { return "LocalDevVPN未连接" }
        return "尚未检测"
    }

    private var statusSubtitle: String {
        if case .ready = viewModel.diagnosticState { return "LocalDevVPN可用，可以签名和续签应用" }
        if case .running = viewModel.diagnosticState { return "正在检测设备响应和安装能力" }
        if let installFailure { return installFailure.userReason }
        return "检测当前 VPN 和LocalDevVPN状态。"
    }

    private var statusColor: Color {
        if case .ready = viewModel.diagnosticState { return .sealSuccess }
        if case .running = viewModel.diagnosticState { return .sealAccent }
        return installFailure == nil ? Color.sealTextSecondary : .sealDanger
    }

    private var installFailure: ImportFailure? {
        guard case .failed(let failure) = viewModel.diagnosticState else { return nil }
        return failure.code.hasPrefix("SEAL-INSTALL-") || failure.code.hasPrefix("SEAL-PAIR-") ? failure : nil
    }

    private var sealTunnelTitle: String {
        switch sealTunnel.state {
        case .idle: return "未检测"
        case .notConfigured: return "未配置"
        case .configuring: return "配置中"
        case .connecting: return "连接中"
        case .connected: return isCheckingSealTunnel ? "验证中" : "已连接"
        case .disconnecting: return "正在停止"
        case .disconnected: return "未连接"
        case .unavailable: return "不可用"
        case .failed: return "连接失败"
        }
    }

    private var sealTunnelDetail: String {
        switch sealTunnel.state {
        case .unavailable(let reason), .failed(let reason):
            return reason
        case .connected:
            return "LocalDevVPN 已开启。这里会验证当前状态，不会修改配对状态。"
        default:
            return "开启 LocalDevVPN 后，Seal 可以签名和续签应用。"
        }
    }

    private var sealTunnelColor: Color {
        switch sealTunnel.state {
        case .connected:
            return .sealSuccess
        case .configuring, .connecting, .disconnecting:
            return .orange
        case .failed:
            return .sealDanger
        default:
            return Color.sealTextSecondary
        }
    }

    private var sealTunnelActionTitle: String {
        if isCheckingSealTunnel { return "正在验证 LocalDevVPN…" }
        switch sealTunnel.state {
        case .configuring, .connecting:
            return "正在启动 LocalDevVPN…"
        case .connected:
            return "验证 LocalDevVPN"
        default:
            return "启动并验证 LocalDevVPN"
        }
    }

    private var deviceResponseText: String {
        switch viewModel.diagnosticState {
        case .ready: return "正常"
        case .running: return "检测中"
        case .failed: return "不可用"
        case .idle: return "未检测"
        }
    }

    private var installServiceText: String {
        switch viewModel.diagnosticState {
        case .ready: return "可用"
        case .running: return "检测中"
        case .failed: return "不可用"
        case .idle: return "未检测"
        }
    }

    private var deviceResponseColor: Color {
        if case .ready = viewModel.diagnosticState { return .sealSuccess }
        if case .failed = viewModel.diagnosticState { return .sealDanger }
        return .sealTextSecondary
    }

    private var installServiceColor: Color { deviceResponseColor }
}
