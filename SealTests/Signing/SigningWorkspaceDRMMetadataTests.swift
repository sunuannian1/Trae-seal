import Foundation
import Testing
@testable import Seal

/// `SC_Info`（FairPlay DRM 元数据）清理的单元测试。
///
/// **真机闭环**（构建 184，源阅读，2026-09-21）：`SC_Info/Manifest.plist` 登记的
/// root sinf 路径越界时，installd 报
/// `ApplicationSINFCaptureFailed (Root sinf URL points outside of bundle)` 拒绝安装，
/// 而桌面图标已注册且失败路径不回收 ⇒ 用户看到「有图标、点不开」。
///
/// **本组测试守的形态**：`SC_Info` **不止在 app 根目录** —— 嵌套 bundle
/// （`Frameworks/*.framework`、`PlugIns/*.appex`）里也有。真实样本的
/// `SinfReplicationPaths` 同时列着 `Frameworks/Cronet.framework/SC_Info/…` 与
/// `PlugIns/*.appex/SC_Info/…`，所以只删根目录那一个会漏掉大多数引用。
struct SigningWorkspaceDRMMetadataTests {

    /// 搭一个含「根 / 框架 / 扩展」三处 `SC_Info` 的 bundle，
    /// 外加两个**名字相近但不应被匹配**的目录（防止判据退化成前缀匹配）。
    private func makeBundle() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seal-drm-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        let fileManager = FileManager.default

        let directories = [
            "SC_Info",
            "Frameworks/Cronet.framework/SC_Info",
            "PlugIns/Share.appex/SC_Info",
            "Assets/SC_InfoBackup",
            "SC_InfoNested"
        ]
        for directory in directories {
            try fileManager.createDirectory(
                at: app.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("plist".utf8).write(to: app.appendingPathComponent("SC_Info/Manifest.plist"))
        try Data("bin".utf8).write(to: app.appendingPathComponent("Demo"))
        return root
    }

    private func relativeSCInfoPaths(in app: URL) -> [String] {
        var found: [String] = []
        for url in SigningWorkspace.drmMetadataDirectories(in: app) {
            found.append(url.path.replacingOccurrences(of: app.path + "/", with: ""))
        }
        found.sort()
        return found
    }

    /// 三处 `SC_Info` 必须全部找到（含嵌套 bundle 里的）。
    @Test
    func findsSCInfoInNestedBundles() throws {
        let root = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Demo.app", isDirectory: true)

        #expect(relativeSCInfoPaths(in: app) == [
            "Frameworks/Cronet.framework/SC_Info",
            "PlugIns/Share.appex/SC_Info",
            "SC_Info"
        ])
    }

    /// 名字相近的目录不得被误删：判据必须是**整名相等**，不是前缀匹配。
    @Test
    func doesNotMatchLookalikeDirectories() throws {
        let root = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Demo.app", isDirectory: true)

        let found = SigningWorkspace.drmMetadataDirectories(in: app)
        #expect(found.count == 3)
        #expect(found.contains { $0.lastPathComponent == "SC_InfoBackup" } == false)
        #expect(found.contains { $0.lastPathComponent == "SC_InfoNested" } == false)
    }

    /// 砸壳工具导出的正常 IPA 本就不含 `SC_Info` ⇒ 必须返回空，且不抛错。
    @Test
    func cleanBundleYieldsNothing() throws {
        let root = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Demo.app", isDirectory: true)

        for directory in SigningWorkspace.drmMetadataDirectories(in: app) {
            try FileManager.default.removeItem(at: directory)
        }
        #expect(SigningWorkspace.drmMetadataDirectories(in: app).isEmpty)
    }
}
