import SwiftUI

struct BatchRefreshView: View {
    @ObservedObject var viewModel: AppsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SealDrawer(title: drawerTitle, showsFooter: !isRunning) {
            VStack(alignment: .leading, spacing: 16) {
                headlineBlock
                if showsQueue { queueBlock }
                if let footerTip { tipText(footerTip) }
            }
            .padding(.bottom, 12)
        } footer: {
            action
        }
        .interactiveDismissDisabled(isRunning)
    }

    private var drawerTitle: String {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running, .preparingSealUpdate:
            return "批量续签"
        case .completed:
            return "批量续签完成"
        case .failed:
            return "批量续签失败"
        case nil:
            return "批量续签"
        }
    }

    @ViewBuilder private var headlineBlock: some View {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, nil:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("正在准备续签队列")
                    .font(.system(size: 18, weight: .semibold))
                Text("正在检查需要续签的 App")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .running:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                Text(viewModel.batchRefreshSession?.currentStage?.stageTitle(isRenewal: true) ?? "正在续签")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
                Text(viewModel.batchRefreshSession?.currentAppName ?? "当前 App")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .preparingSealUpdate:
            VStack(alignment: .leading, spacing: 8) {
                Text("其他 App 已完成")
                    .font(.system(size: 18, weight: .semibold))
                Text("即将更新 Seal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.sealAccent)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .completed(let result):
            VStack(alignment: .leading, spacing: 8) {
                Text(result.failed == 0 ? "全部处理完成" : "部分 App 续签失败")
                    .font(.system(size: 18, weight: .semibold))
                Text(result.failed == 0 ? "\(result.succeeded) 个 App 已续签" : "\(result.succeeded) 个成功，\(result.failed) 个失败")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        case .failed(let failure):
            VStack(alignment: .leading, spacing: 8) {
                Text(failure.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.sealDanger)
                Text(failure.userReason)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .glassSurface(cornerRadius: 18)
        }
    }

    private var queueBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("续签队列")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.sealTextSecondary)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        queueRow(item)
                        if index < items.count - 1 { Divider().padding(.leading, 24) }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(16)
        .glassSurface(cornerRadius: 18)
    }

    private func queueRow(_ item: BatchRefreshSession.Item) -> some View {
        HStack(spacing: 10) {
            Text(symbol(for: item.state))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color(for: item.state))
                .frame(width: 16)
            Text(item.name)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 10)
            Text(title(for: item.state, isSeal: item.isSeal, stage: item.stage))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(color(for: item.state))
                .lineLimit(1)
        }
        .frame(minHeight: 38)
    }

    private func tipText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.sealTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    @ViewBuilder private var action: some View {
        switch viewModel.batchRefreshSession?.status {
        case .completed(let result):
            VStack(spacing: 10) {
                if result.failed > 0 {
                    Button("重试失败项") { viewModel.refreshAll() }
                        .sealOutlineAction(cornerRadius: 14)
                }
                Button("完成") { viewModel.dismissBatchRefresh(); dismiss() }
                    .sealPrimaryAction(cornerRadius: 14)
            }
        case .failed:
            VStack(spacing: 10) {
                Button("重试") { viewModel.refreshAll() }
                    .sealPrimaryAction(cornerRadius: 14)
                Button("完成") { viewModel.dismissBatchRefresh(); dismiss() }
                    .sealOutlineAction(cornerRadius: 14)
            }
        case .preparing, .running, .preparingSealUpdate:
            EmptyView()
        case nil:
            EmptyView()
        }
    }

    private var items: [BatchRefreshSession.Item] {
        viewModel.batchRefreshSession?.items ?? []
    }

    private var showsQueue: Bool {
        items.isEmpty == false
    }

    private var progressText: String {
        "\(viewModel.batchRefreshSession?.currentIndex ?? 0) / \(viewModel.batchRefreshSession?.total ?? 0)"
    }

    private var footerTip: String? {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running:
            return AppSigningPresentationHelpers.keepSealOpenTip
        case .preparingSealUpdate:
            return "更新 Seal 时会暂时回到主屏幕，安装完成后请重新打开。"
        case .failed:
            return "请确认已连接 Wi-Fi 且 LocalDevVPN 已连接后重试；若提示账号会话过期，请先在「我的」页重新验证。"
        case .completed, nil:
            return nil
        }
    }

    private var isRunning: Bool {
        switch viewModel.batchRefreshSession?.status {
        case .preparing, .running, .preparingSealUpdate:
            return true
        case .completed, .failed, nil:
            return false
        }
    }

    private func symbol(for state: BatchRefreshSession.Item.State) -> String {
        switch state {
        case .completed: return "✓"
        case .running, .preparingSealUpdate: return "●"
        case .waiting: return "○"
        case .failed: return "!"
        }
    }

    private func title(for state: BatchRefreshSession.Item.State, isSeal: Bool, stage: SigningStage? = nil) -> String {
        switch state {
        case .completed: return isSeal ? "已更新" : "已完成"
        case .running: return runningStageTitle(stage)
        case .preparingSealUpdate: return "即将更新"
        case .waiting: return "等待中"
        case .failed: return "失败"
        }
    }

    private func runningStageTitle(_ stage: SigningStage?) -> String {
        switch stage {
        case .signing: return "重新签名中"
        case .pushing: return "传输中"
        case .installing, .verifying: return "安装中"
        default: return "准备中"
        }
    }

    private func color(for state: BatchRefreshSession.Item.State) -> Color {
        switch state {
        case .completed: return .sealSuccess
        case .running, .preparingSealUpdate: return .sealAccent
        case .waiting: return .sealTextSecondary
        case .failed: return .sealDanger
        }
    }
}
