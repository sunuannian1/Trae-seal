# Seal 重写路线图（签名 / 安装 / 续签）

> 目标：用成熟、经过大规模验证的技术栈替换自研的脆弱链路。
> 原则：每期完成后独立可用、可回退，与现有链路并存做双保险。
> 决策记录（2026-09-08）：**OTA 安装路线下线**，安装一律走本地通道
> （LocalDevVPN + Minimuxer + installation_proxy）。

## 现状问题（真机日志定位 → 已定位根因）

| 环节 | 问题 | 根因 | 状态 |
|---|---|---|---|
| 安装（RSD shim 通道） | MissingPackagePath | **隧道会话绑定**：RSD shim 服务的 afcd 暂存视图绑定在建立它的 RemotePairing 隧道会话上；此前"首选 CoreDevice 隧道上传/安装"每次 FFI 调用都新建隧道，会话 A 上传的包在会话 B 的 installd 眼中不存在 | ✅ 已修复（见下） |
| 安装（CoreDeviceProxy） | ConnectionReset | devicecompute 服务在 WiFi/RSD 通道上硬重置连接（独占连接+重试均无效） | ✅ 整个 fresh-tunnel 模块已删除 |
| Apple ID / 续签 | 503 | 国内直连 gsa.apple.com 线路时通时断 + **复用上次失败的 idle 连接被 Apple 拒**（代理/TUN 切换后残留连接未关闭就被后续请求复用）。上游 iloader 2.3.3 同根因修复（isideload reqwest `.pool_max_idle_per_host(0)`） | ✅ 已加修复：altsign-mod `ALTAppleAPI.swift` 认证 session 设 `Connection: close`（登录/2FA GSA 请求每次走新连接）；叠加既有 3s/8s 自动重试。待随 AltSign fork 发版 + 真机回归 |

## 安装链路修复（2026-09-08 落地，OTA 同日下线）

### 根因与证据

官方两个在 iOS 17/18 真机上验证过的实现——jkcoxson 的 jas（`install_ipa`）与
SideStore 的 `IdeviceGateway`——共同不变量是：

> **AFC 上传与 installation_proxy 安装必须发生在同一条缓存的 RemotePairing
> TLS-PSK 隧道会话上**（一条 `adapter + RsdHandshake` 贯穿始终；jas 甚至在上传后
> `drop(afc)` 再安装也成功，证明暂存视图绑定会话而非单次连接）。

Seal 此前失败的两条自研路径都违反了这一不变量：

1. `stageViaCoreTunnel` / `installViaCoreTunnel`：每次 FFI 调用新建隧道
   （新 RemotePairingClient → 新监听 → 新 TLS-PSK → 新 RSD 握手），上传与安装
   必然跨会话 → `MissingPackagePath`；
2. 隧道内层 RSD 只暴露 `*.shim.remote` 服务名（pymobiledevice3 / Xcode 同款约定），
   代码里"真实服务名 `com.apple.afc` 优先"永远连接失败 → 静默回退 shim，
   把跨会话问题进一步掩盖。

而正确的形态（合并调用 `stage_and_install_rppairing`，走 `connect_to_rsd_services`
的**进程内缓存会话**）早已存在于代码中，只是被降级成了兜底路径。

### 修复内容（删除为主，零新增 Rust 逻辑）

| 层 | 改动 |
|---|---|
| Rust | 删除 `core_device_install.rs`（fresh-tunnel 模块）及其 FFI（`rust_bridge_idevice_*_via_core_tunnel` 三个）；`rsd.rs` 移除 `create_fresh_tunnel_context`/`get_rpp_raw`/`create_dedicated_rsd_connection` 死代码；`install.rs` 注释固化会话不变量。合并调用 `stage_and_install_rppairing` 成为主链路：缓存会话上传（含同连接回读大小校验）→ drop AFC → 同会话 instproxy 安装候选链（官方形态优先：`PublicStaging/<bid>/app.ipa` + 空 ClientOptions）→ 卸载残留重试 |
| Vendor Swift | `MinimuxerBridgeIdevice.swift`/`Minimuxer.swift` 删 CoreTunnel 三个包装；`Install.swift` 的 `RPInstall` 改为纯两段语义（yeet=仅暂存、install=仅安装，暂存文件名经 Rust `IPA_NAME_CACHE` 传递，不再跨 FFI 传字节重复上传） |
| App Swift | `MinimuxerInstallChannel.install()` 改为**合并调用主链路**：一次会话完成上传+安装，超时 = 上传预算（封顶 30 分钟）+ 安装 600s；失败按 MissingPackagePath（整体重跑=重新上传）与 socket 类（先 `Minimuxer.reset()` 重建）分类重试至多 3 次；`pushIpa`/`installPushedIpa` 保留为两阶段诊断路径（协议与测试 mock 不变）；`SigningCoordinator` 移除 OTA 分支 |
| OTA | `OtaInstallService.swift` 与 Rust OTA FFI 保留但零调用方（dormant，可日后恢复）；不再需要 `SealCA.mobileconfig` 信任引导 |

### 验证方法（需真机）

1. iOS 18.7 真机：导入 IPA → 签名并安装，全程不接电脑、不依赖 OTA/CA 信任；
2. 回归样本：微信 / 黄豆短剧 / LCSign / lanmanga（后三者含历史失败结构）；
3. 续签场景：已安装 App 到期前刷新，确认覆盖安装且沙盒数据保留；
4. 断连恢复：安装中途开关 LocalDevVPN，确认重试能自愈（MissingPackagePath → 整体重跑）。

## 二期（进行中）：签名加固（zsign 核心 + IPA 结构处理）

### 已落地（2026-09-08）：空 Frameworks/PlugIns 目录清理

真机日志闭环：黄豆短剧类 ESign 打包样本（空 Frameworks/ + framework 散落 .app 根 +
二进制声明 LC_RPATH @executable_path/Frameworks）在安装阶段被 installd 报
`APIInternalError("Failed to discover bundles in directory .../Frameworks")`。
iOS 18 installd 的 bundle discovery 枚举空的 Frameworks 目录即抛错；
两个目录均为可选目录，不存在时直接跳过。已实现：签名前移除空的
Frameworks/PlugIns（非空目录原样保留），同批次 LiveContainer 验证整链路通畅。

### 待做

现状：签名走 rork-sign（纯 Swift 流式），本身稳定；问题是**兼容性长尾**
（特殊 entitlements/插件/二进制形态的 App 偶发失败；另见已归档的《全链路排查报告》
P1–P5：ad-hoc 预处理层污染、symtab adjacency 修正、单/双 CodeDirectory——
P1–P5 均已修复落地）。

计划：
1. **进程内引入 zsign 核心**（C++ → 静态库，OpenSSL 复用 AltSign 的
   OpenSSL-Universal xcframework）：
   - CMS/CodeDirectory 签名（对齐 zsign 的 -z 流程）
   - entitlements 注入/改写（支持受管/非受管形态）
   - 多 arch（arm64/armv7 遗留）与 extension 全覆盖签名
   - C FFI：`zsign_sign(ipa_in, ipa_out, cert_pem, key_pem, provision, entitlements)`
2. **ZIPFoundation 重写 IPA 结构处理**：
   - 解包（保留 entry 顺序/压缩参数，修复中文名编码）
   - 重打包（确定性输出）
   - 与 SignedArtifactValidator 合并做签名前后双验证
3. 双签名器并存：zsign 失败自动回退 rork-sign，报错带签名器标识

里程碑验收：黄豆短剧/微信/企业微信等历史失败样本全部可签可装。

## 三期（待做）：二进制处理与注入（MachOKit / optool / ellekit）

1. **MachOKit**（已暂缓，swift-crypto<4.0 版本冲突待解）：MachO 解析
   - 架构列表 / LC 码签名段检查 / embedded entitlements 提取
   - `MachOInspector` 模块输出到签名前校验与日志
2. **optool 对齐**：二进制注入（insert_dylib）与 remove-provision 改写
3. **ellekit / TrollFools 对齐**：dylib 注入产品的完整化（依赖二期 zsign 重签）
4. UI：注入管理面板（选择 tweak dylib → 注入 → 重签 → 安装）

## 已知不可消除的限制（Apple 政策/环境，任何工具相同）

- 免费证书 7 天有效期：续签必须连 Apple 服务器
- gsa.apple.com 国内直连时通时断：503 自动重试已内置（3s/8s 间隔），持续 503 需梯子或等冷却
- 免费 App ID 上限 10 个 / 单证书 3 台设备
- 手机存储不足、iOS 偶发安装失败：重试可解
- 无线 AFC 传输速度跟随隧道带宽，1GB 包必然慢；代码层可做的是分块写与进度回读

## 一次性成本

- 零服务器、零域名、零费用
- OTA 下线后不再需要本地 CA 描述文件信任引导
