import Foundation

/// 公告数据模型（远端 JSON）
struct Announcement: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case notice
        case important
        case update
    }

    let id: String
    let kind: Kind
    let title: String
    let message: String
    let minVersion: String?
    let publishedAt: String?
}

struct AnnouncementPayload: Codable {
    let announcements: [Announcement]
}

/// 远端公告拉取服务（仿 UpdateChecker：URLSession + UserDefaults 去重）
struct AnnouncementService {
    static let shared = AnnouncementService()

    /// 拉取可展示的公告，按优先级 important > update > notice 排序
    func fetch() async -> [Announcement] {
        let dismissed = dismissedIDs()

        do {
            var request = URLRequest(url: AppConfiguration.Announcement.remoteURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Seal", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }

            let payload = try JSONDecoder().decode(AnnouncementPayload.self, from: data)
            let current = Version.current
            let priority: [Announcement.Kind] = [.important, .update, .notice]

            return payload.announcements
                .filter { item in
                    guard !dismissed.contains(item.id) else { return false }
                    if let min = item.minVersion,
                       Version.compare(min, current) == .orderedDescending {
                        return false
                    }
                    return true
                }
                .sorted { lhs, rhs in
                    let lp = priority.firstIndex(of: lhs.kind) ?? priority.count
                    let rp = priority.firstIndex(of: rhs.kind) ?? priority.count
                    return lp < rp
                }
        } catch {
            return []
        }
    }

    func markDismissed(_ id: String) {
        var ids = dismissedIDs()
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: AppConfiguration.Announcement.dismissedKey)
    }

    private func dismissedIDs() -> Set<String> {
        let stored = UserDefaults.standard.array(forKey: AppConfiguration.Announcement.dismissedKey) as? [String] ?? []
        return Set(stored)
    }
}

/// 语义化版本比较（兼容 v 前缀与多段版本号，供 minVersion 门卫）
enum Version {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(of: lhs)
        let b = components(of: rhs)
        let count = max(a.count, b.count)
        for index in 0..<count {
            let av = index < a.count ? a[index] : 0
            let bv = index < b.count ? b[index] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(of version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        return text.components(separatedBy: ".").compactMap { Int($0) }
    }
}