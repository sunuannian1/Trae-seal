import Foundation

/// 启动更新通知检查器
/// 从 GitHub Releases 拉取最新版本，有更新时弹窗提示
/// 弹窗标题和内容来自 Release 的 name 和 body，可在 GitHub 发版时自定义
struct UpdateChecker {
    static let shared = UpdateChecker()

    private let repo = "sunuannian1/Trae-seal"
    private let lastNotifiedVersionKey = "update_notifier.last_notified_version"

    /// 检查更新，返回需要展示的通知内容（无更新返回 nil）
    /// - Parameter force: 手动检查时传 true，忽略已通知记录，有新版本就弹
    func check(force: Bool = false) async -> UpdateNotice? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Seal", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                return nil
            }

            // 本地版本
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            // 如果最新版本和当前版本相同，不提示
            if tagName == currentVersion || tagName == "v\(currentVersion)" {
                return nil
            }

            // 非强制模式：已经通知过这个版本，不重复弹
            if !force {
                let lastNotified = UserDefaults.standard.string(forKey: lastNotifiedVersionKey)
                if lastNotified == tagName {
                    return nil
                }
                // 仅自动检查标记已通知；手动检查不写记录，避免吃掉后续自动弹窗
                UserDefaults.standard.set(tagName, forKey: lastNotifiedVersionKey)
            }

            // 从 Release 读取标题和正文，发版时可自定义
            let releaseName = json["name"] as? String ?? "发现新版本"
            let releaseBody = (json["body"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = releaseBody?.isEmpty == false ? releaseBody! : "点击查看详情并更新"

            // 下载跳转地址：优先 Release 详情页，回退到仓库页面
            let downloadURL = (json["html_url"] as? String)
                .flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repo)/releases")

            // 从 attachments 里找 .ipa 附件，供应用内直接下载覆盖安装
            let ipaAsset = (json["assets"] as? [[String: Any]])?
                .first { attachment in
                    let name = attachment["name"] as? String ?? ""
                    return name.lowercased().hasSuffix(".ipa")
                }
            let ipaDownloadURL = (ipaAsset?["browser_download_url"] as? String)
                .flatMap(URL.init(string:))

            return UpdateNotice(
                version: tagName,
                title: releaseName,
                message: message,
                downloadURL: downloadURL,
                ipaDownloadURL: ipaDownloadURL
            )
        } catch {
            return nil
        }
    }
}

struct UpdateNotice: Identifiable {
    let id = UUID()
    let version: String
    let title: String
    let message: String
    let downloadURL: URL?
    let ipaDownloadURL: URL?
}
