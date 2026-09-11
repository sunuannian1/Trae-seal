import SwiftUI

/// 更新通知弹窗（iOS 原生风格，居中布局，内容自适应并可限高滚动）
struct UpdateNoticeView: View {
    let notice: UpdateNotice
    let onDismiss: () -> Void
    /// 下载完成后回调本地文件 URL 触发导入安装；为 nil 时回退跳转浏览器。
    let onInstall: ((URL) -> Void)?
    @Environment(\.openURL) private var openURL

    @State private var phase: DownloadPhase = .idle
    @State private var downloadTask: Task<Void, Never>?

    private enum DownloadPhase {
        case idle
        case downloading(Int64, Int64?) // (已接收字节数, 总字节数；总大小未知时为 nil)
        case failed(String)
    }

    /// 把 Release 的 Markdown body 拆成更新内容列表（逐行去 markdown 标记）
    private func changeItems(from markdown: String) -> [String] {
        var items: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            var text = line
            text = text.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*[-*•·]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "^\\s*\\d+[.)]\\s+", with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "`(.+?)`", with: "$1", options: .regularExpression)
            text = text.replacingOccurrences(of: "\\[(.+?)\\]\\(.+?\\)", with: "$1", options: .regularExpression)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                items.append(trimmed)
            }
        }
        if items.isEmpty {
            let full = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            items = full.isEmpty ? ["点击查看详情并更新"] : [full]
        }
        return items
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .transition(.opacity)

            VStack(spacing: 0) {
                // 头部：左渐变图标框 + 右标题/版本
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.sealAccent, Color.sealAccent.opacity(0.75)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .overlay {
                            Image("UpdateBell")
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                        }
                        .shadow(color: Color.sealAccent.opacity(0.35), radius: 8, x: 0, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(notice.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(notice.version)
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()
                    .padding(.horizontal, 20)

                // 更新内容（内容自适应延长，超出限高滚动）
                VStack(alignment: .leading, spacing: 8) {
                    Text("更新内容")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.top, 14)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(changeItems(from: notice.message), id: \.self) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(Color.sealAccent)
                                        .frame(width: 5, height: 5)
                                        .padding(.top, 7)
                                    Text(item)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 240)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // 底部双按钮：取消 + 下载更新 / 进度
                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        Text("取消")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.sealSurfaceElevated)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
                            }
                    }

                    Button(action: handleUpdate) {
                        Group {
                            switch phase {
                            case .idle:
                                Text("下载更新")
                            case .downloading(let received, let total):
                                if let total, total > 0 {
                                    let progress = Double(received) / Double(total)
                                    HStack(spacing: 8) {
                                        ProgressView(value: progress)
                                            .controlSize(.small)
                                        Text("\(Int(progress * 100))%")
                                    }
                                } else if received > 0 {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("已下载 \(received.formatted(.byteCount(style: .binary)))")
                                    }
                                } else {
                                    HStack(spacing: 8) {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("正在连接…")
                                    }
                                }
                            case .failed:
                                Text("重试")
                            }
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.sealAccent)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)

                if case .failed(let reason) = phase {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 8)
                }
            }
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.sealSurface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.sealHairline.opacity(0.6), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.25), radius: 30, x: 0, y: 12)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    @MainActor
    private func handleUpdate() {
        // 下载中点按 = 取消，回到可重试状态（避免卡在 0% 时按钮「假死」）
        if isDownloading {
            downloadTask?.cancel()
            downloadTask = nil
            phase = .idle
            return
        }

        // 无 IPA 附件或未提供安装回调：回退为跳转浏览器 Release 页
        guard let ipaURL = notice.ipaDownloadURL, let onInstall else {
            if let url = notice.downloadURL {
                openURL(url)
            }
            onDismiss()
            return
        }

        phase = .downloading(0, nil)
        downloadTask = Task {
            do {
                let localURL = try await UpdateIPADownloader.shared.download(
                    from: ipaURL,
                    onProgress: { @MainActor received, total in
                        phase = .downloading(received, total)
                    }
                )
                onInstall(localURL)
            } catch is CancellationError {
                phase = .idle
            } catch let error as UpdateDownloadError {
                phase = .failed(error.errorDescription ?? "下载失败")
            } catch {
                phase = .failed("下载失败，请稍后重试")
            }
            downloadTask = nil
        }
    }
}