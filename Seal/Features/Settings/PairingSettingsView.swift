import SwiftUI
import UniformTypeIdentifiers

struct PairingSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isFileImporterPresented = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                hero
                if let pairing = viewModel.pairingRecord {
                    details(pairing)
                    if pairing.validationStatus == .fileUnreadable || pairing.validationStatus == .deviceMismatch {
                        acquisitionGuide
                    }
                } else {
                    acquisitionGuide
                }
                actions
            }
            .padding(20)
        }
        .navigationTitle("设备")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "mobiledevicepairing") ?? .data,
                .propertyList,
                .json,
                .data,
                .item
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await viewModel.importPairingFile(at: url) }
            case .failure:
                break
            }
        }
        .alert(item: $viewModel.alertFailure) { failure in
            Alert(
                title: Text(failure.title),
                message: Text(failure.userMessage),
                dismissButton: .default(Text(failure.recovery))
            )
        }
        .sealScreenBackground()
        .task {
            _ = await viewModel.importPairingAssistantInboxIfPresent()
        }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: heroIcon)
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(heroColor)
            Text(heroTitle)
                .font(.title2.weight(.semibold))
            Text(heroSubtitle)
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassSurface(cornerRadius: 24)
    }

    private func details(_ pairing: PairingRecord) -> some View {
        VStack(spacing: 0) {
            detailRow("配对类型", pairing.isRemotePairing ? "远程配对" : "本机配对")
            Divider()
            detailRow("设备 UDID", deviceIdentifierText(pairing))
            Divider()
            detailRow("配对状态", pairing.validationStatus.title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 18)
    }

    private var acquisitionGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接设备")
                .font(.headline)
            Text("使用电脑端 Seal 配对助手生成配对文件后，可通过「导入配对文件」手动选择，或由配对助手自动写入 Seal。")
                .font(.subheadline)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("仅支持 iOS 17 及以上设备配对（iOS 16 及以下系统不支持）。")
                .font(.caption)
                .foregroundStyle(Color.sealTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(cornerRadius: 18)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                isFileImporterPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入配对文件")
                }
            }
            .sealPrimaryAction(cornerRadius: 12)

            Button(viewModel.pairingRecord == nil ? "检查配对状态" : "重新检查") {
                Task {
                    await viewModel.testPairingConnection()
                }
            }
            .sealOutlineAction(cornerRadius: 12)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(Color.sealTextSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 54)
    }

    private var heroIcon: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "iphone.badge.exclamationmark"
        }
        switch status {
        case .verified: return "checkmark.circle.fill"
        case .validating: return "arrow.triangle.2.circlepath"
        case .unverified: return "clock.badge.checkmark"
        case .deviceMismatch, .fileUnreadable: return "exclamationmark.triangle.fill"
        }
    }

    private var heroColor: Color {
        guard let status = viewModel.pairingRecord?.validationStatus else { return .sealWarning }
        switch status {
        case .verified: return .sealSuccess
        case .validating: return .sealAccent
        case .unverified: return .sealWarning
        case .deviceMismatch, .fileUnreadable: return .sealDanger
        }
    }

    private var heroTitle: String {
        guard let pairing = viewModel.pairingRecord else { return "未导入" }
        return pairing.validationStatus.title
    }

    private var heroSubtitle: String {
        guard let status = viewModel.pairingRecord?.validationStatus else {
            return "请先在电脑上完成设备配对。"
        }
        switch status {
        case .unverified:
            return "设备信息已保存。首次连接成功后会完成配对。"
        case .validating:
            return "正在确认当前 iPhone 是否匹配。"
        case .verified:
            return "已完成配对。连接暂时不可用也不会取消配对。"
        case .deviceMismatch:
            return "当前设备不匹配，请重新配对。"
        case .fileUnreadable:
            return "设备信息无法读取，请重新配对。"
        }
    }

    private func deviceIdentifierText(_ pairing: PairingRecord) -> String {
        if let id = pairing.validatedDeviceIdentifier, id.isEmpty == false { return id }
        if let id = pairing.deviceIdentifier, id.isEmpty == false { return id }
        return "待验证"
    }
}
