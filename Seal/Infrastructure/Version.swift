import Foundation

/// 语义化版本比较（兼容 v 前缀与多段版本号）
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
