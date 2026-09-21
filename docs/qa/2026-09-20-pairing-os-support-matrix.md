# 远程配对（RPPairing）支持的系统版本 —— 精确到小版本

> 查证日期 **2026-09-20**；结论有效期取决于 Apple 是否改变 `CoreDeviceProxy` 的可用版本。
> 复核方法见第六节 —— **别把它当永久真理**。
> **2026-09-21 追加**：§5.2 的 Lockdown 通道**已真机验证通过**（构建 190）；
> 新增 **§8「iOS 16 能不能走同一条路」**（链路同构审计 ＋ 降级门槛审计）。
> **2026-09-21 再追加**：§8 的结论**已落地** —— 部署目标 17.0 → **16.0**（**9 处**声明 =
> 6 处 Xcode 声明 ＋ 3 份 workflow 的 CI 断言），
> 见 **§8.5 落地记录**。⚠️ **iOS 16 真机仍未验**（见 §8.6）。

## 一、结论

**远程配对（RPPairing）需要 iOS / iPadOS 17.4 或更高版本。**

分界线的成因：远程配对要走 Apple 的 **`CoreDeviceProxy`** lockdown 服务，**这个服务是 iOS 17.4 才引入的**。
iOS 17.0–17.3.1 上没有它，userspace 隧道只能经 Wi-Fi/bonjour 走 RemotePairing
⇒ **配对助手在 USB 上生成不了远程配对文件**（这正是 Seal 的唯一用法）。

## 二、判据来源（两处互相独立）

| # | 来源 | 原文 / 要点 |
|---|---|---|
| 1 | 固定上游 `idevice_pair` **0.1.14**（commit `e3abb34`）README | *"Select pairing mode, `RPPairing` for **iOS 17.4+**, `Lockdown` for older verions"*（拼写是上游原文） |
| 2 | pymobiledevice3 文档《iOS 17+ tunnels》 | *"iOS 17.4+ … uses the CoreDeviceProxy lockdown service"*；17.0–17.3.1 *"predate the CoreDeviceProxy service"* |

代码级佐证：上游 `src/main.rs` **没有任何版本判断** —— 配对类型由用户手动单选
（`PairingMode::Lockdown` / `PairingMode::RemotePairing`），默认值是硬编码的 `RemotePairing`。

## 三、逐个小版本（截至 2026-09-20）

| 设备系统 | 远程配对 | 具体版本 |
|---|---|---|
| iOS / iPadOS 17.0 – 17.3.1 | ❌ | 17.0、17.0.1、17.0.2、17.0.3、17.1、17.1.1、17.1.2、17.2、17.2.1、17.3、17.3.1 |
| iOS / iPadOS 17.4 – 17.7.2 | ✅ | 17.4、17.4.1、17.5、17.5.1、17.6、17.6.1、17.7、17.7.1、17.7.2（17.x 收尾） |
| iOS / iPadOS 18.x | ✅ | 18.0、18.0.1、18.1、18.1.1、18.2、18.2.1、18.3、18.3.1、18.3.2、18.4、18.4.1、18.5、18.6、18.6.1、18.6.2、18.7 – 18.7.10 |
| iOS / iPadOS 26.x | ✅ | 26.0、26.0.1、26.1、26.2、26.2.1、26.3、26.3.1、26.4、26.4.1、26.4.2、26.5、26.5.1、26.5.2、26.6、26.6.1、26.6.2、26.7 |
| iOS / iPadOS 27.x | ✅ | 27.0（2026-09-14 发布） |
| iOS 16.x 及以下 | ❌ | 无 CoreDevice / RSD 链路（**而且 Seal 装不上**，见第五节；**但配对链路本身与版本无关** ⇒ 见 §8） |

## 四、其他平台与主机

| 对象 | 状态 |
|---|---|
| **tvOS**（Apple TV） | 上游 **master 2026-08 才新增**（PR #79），需手动进「遥控器与设备 → 远程 App 与设备」配对模式；**上游未标注最低版本** ⇒ 未确认 |
| **visionOS** | 上游只写 *"visionOS devices"*，**没给版本号** ⇒ 未确认 |
| **watchOS** | 上游没有这条链路（配对文件 / RPPairing 均未提及）⇒ 不支持 |
| **电脑（主机）** | 上游出 macOS / Windows / Linux 三平台；**Seal 只构建 `windows-x64`**（`.github/workflows/pairing-assistant.yml` 的 `windows-2025` job） |
| **设备主动发起配对**（`_remotepairing-pairable-host._tcp`） | 上游 master README：需 **iOS 27 或更高**；**不在 Seal 固定的 0.1.14 里** |

## 五、对 Seal 意味着什么

1. **Seal 自己的部署目标是 iOS 17.0**（`project.yml` **5 处**：`options` 全局 ＋
   `Seal` / `DeviceSupport` / `SealTests` / `SealUITests` 四个 target）
   ⇒ **iOS 16.x 及以下无法安装 Seal**，与配对方式无关。
   ⚠️ 但**这只是声明，不是技术依赖** —— 门槛有多低见 **§8**。
2. **iOS 17.0–17.3.1**：Seal 能跑，但**只能走 Lockdown（本机配对）**。minimuxer 里这条链路是完整的
   （`Muxer.start` 按 `UDID` / `private_key` 分流；`LockDownInstall` 的 AFC 暂存 + instproxy 安装）。
   **配对助手自 run#185 起会按设备版本自动选**（`seal_mode_for_ios`）。
   ✅ **2026-09-21 真机验证通过 —— 全流程通**（**构建 190**）：助手写入配对文件 → Seal 导入 →
   通道验证 → 装 App → 点开 → **续签（含批量）全部走通** ✓
   ⇒ 见 `device-regression-checklist.md` 第 15 项（已结案）。
3. **iOS 17.4 及以上**：远程配对，助手按原样生成 RPPairing 文件。

## 六、怎么复核（结论过期时照这个来）

1. 上游 README（**先看 Seal 固定的那个 commit**，再看 master）：
   `https://github.com/jkcoxson/idevice_pair` —— 搜 `RPPairing for iOS`。
2. pymobiledevice3 的《iOS 17+ tunnels》指南 —— 搜 `CoreDeviceProxy`。
3. 版本清单：Wikipedia 的 `iOS 17` / `iOS 18` / `iOS 26` / `iOS 27` 各词条的 Version history 表。
4. 想确认「设备端到底有没有这个服务」，比读文档更硬的办法是**真机连一次**：
   `idevice_pair` 生成远程配对文件成功 ⇒ 该版本有 `CoreDeviceProxy` ✓。

## 七、完整性审计：Seal 里还有别的地方要求 17.4 吗？

**动机**：只把配对助手修好还不够 —— 如果 Seal 别处也硬性假设 17.4，那 17.0–17.3.1 拿到
Lockdown 文件照样会卡住。所以做了一次全仓审计（2026-09-20）。

**审计方法**：全仓 `grep` 这几个模式 —— `17.4` / `17_4` / `17.3` / `CoreDeviceProxy` /
`isRemotePairing` / `remotePairing` / `RPPairing`，覆盖 `Seal/**`、`Vendor/Minimuxer/Sources/**`、
`Vendor/Minimuxer/RustBridge/src/**`。

**结论**：

| # | 查了什么 | 结果 |
|---|---|---|
| 1 | `Seal/**` 与 `Minimuxer/**` 里有没有 `17.4` 闸门 | **一处都没有** ✓ —— 全仓唯一的 17.4 判据就在配对助手（本轮已修） |
| 2 | 版本分支的判据是什么 | 一律是 **`major < 17`**（pre17 / post17），**与 17.4 无关** ✓<br>`Mounter.swift:119`（DDI 挂载）、`Jit.swift:68`（调试）都是这个判据 |
| 3 | 装 App 走哪条路 | `Install.swift:26` 按 **配对文件类型**分流：`Muxer.isrppairing ? RPInstall : LockDownInstall` ✓<br>⇒ Lockdown 文件自动选 `LockDownInstall`；其注释写明**沿用 SideStore minimuxer 真机验证过的布局** ✓ |
| 4 | 个性化 DDI 挂载要不要 `CoreDeviceProxy` | **不要** ✓ —— `mount_personalized_ddi`（`post17.rs:193`）走 `TcpProvider`（usbmuxd TCP socket）+ `LockdownClient` + `ImageMounter`<br>✅ **2026-09-21 补强**：**Seal 根本不挂 DDI**（从不调用 `Minimuxer.startAutoMounter`）⇒ 这条与 Seal 的装 App 无关，见 §8.2 |
| 5 | 全仓哪里用了 `CoreDeviceProxy` | **只有一处**：`post17.rs:100` 的 `debug_app_post17`（**JIT / 调试启动**） |

**第 5 条的推论（已知缺口，但对 Seal 用户无影响）**：
`Jit.swift` 的分支是 `major < 17 ⇒ debugPre17`、否则 ⇒ `rustBridgeDebugAppPost17`（需要 `CoreDeviceProxy`）
⇒ **iOS 17.0–17.3.1 上「启用 JIT / 调试启动」无路可走**，会以 `CreateCoreDevice` 失败。
⚠️ **但 Seal 根本没有暴露 JIT 功能** —— 全仓只有 `CertificateExportHandler.swift:47` 一处注释
提到 LiveContainer 的「免 JIT 模式」✓ ⇒ 该缺口与 Seal 的「装 App / 续签」无关 ✓，本轮不改代码。

**因此**：iOS 17.0–17.3.1 的**安装与续签不依赖 17.4 的任何能力** ✓；
剩下的风险只在**运行时**（这条通道在 Seal 里从未跑过真机）⇒ 见
`device-regression-checklist.md` 第 15 项。

> ✅ **2026-09-21 更新**：运行时风险**已消除** —— 构建 190 在 iOS 17.0–17.3.1 上**全流程真机通过**
> （写入 → 导入 → 通道验证 → 装 App → 点开 → 续签含批量）⇒ §7 的静态审计结论**已由真机确认** ✓

---

## 八、iOS 16 能不能走同一条路？（2026-09-21 追加审计）

**动机**：Seal 的部署目标是 17.0 ⇒ iOS 16 装不上。但「装不上」是**声明**还是**技术依赖**？
以及 §5.2 那条已被真机验证的 Lockdown 通道，**在 iOS 16 上是不是同一条**？

**结论：是同一套代码，零版本分流** ✓ —— 不是「相似」，是**逐行相同**。

### 8.1 逐环节对照（全部读源码核对）

| 环节 | 判据（文件:行） | iOS 16 vs 17.0–17.3.1 |
|---|---|---|
| 配对类型分流 | `Muxer.start`：配对文件里有 `private_key` ⇒ RPPairing；有 `UDID` ⇒ Lockdown（`Muxer.swift:68-73`） | **与系统版本无关** ✓ 两边都落 `UDID` 分支 |
| 安装器选择 | `Muxer.isrppairing ? RPInstall : LockDownInstall`（`Install.swift:26`） | 两边都是 `LockDownInstall` ✓ |
| 暂存 + 安装 | AFC ＋ instproxy，`PublicStaging/<bundleId>/app.ipa`（`Install.swift:51/112`） | 同 ✓ |
| 设备 IP | `DeviceEndpoint` 从 `utun` 取对端 | 同 ✓ |
| 配对文件解析 | plist（Lockdown 格式）（`PairingStore.swift`） | 同格式 ✓ |

**Seal 侧全仓没有任何运行时版本分流** —— `grep 'ProductVersion|iosVersion|systemVersion' Seal/**`
只命中 `AboutView.swift:92` 的一行**展示文案**；`Seal/` 里 `major < 17` **零命中**（版本判断全在
`Vendor/Minimuxer`）✓

### 8.2 🔴 更正：DDI 挂载这条「差异」对 Seal 不成立

原先容易推错：**iOS 16 走 `handlePre17Mount`、iOS 17 走 `handlePost17Mount`，所以两者不同** ✗
——**Seal 根本不挂载 DDI**：

- `Mounter.handlePre17Mount`（`major < 17`）/ `handlePost17Mount` 是 **SideStore 的 JIT / 调试功能**；
- 把 `Seal/` 调用的 Minimuxer API **全列一遍** —— `reset` / `stageAndInstall` / `isAppInstalled` /
  `lookupApp` / `installIpa` / `yeetAppAfc` / `ready` / `fetchUDIDDetailed` / `start` /
  `isRemotePairing` / `describeError` / `bindTunnelConfig` ⇒ **没有 `startAutoMounter`、
  也不读 `Mounter.dmgMounted`** ✗
- ⇒ **DDI 挂载在 Seal 里从不执行** ⇒ pre17 / post17 的分岔 Seal 压根走不到 ✓
- 装 App 走 AFC ＋ instproxy，**不依赖 DDI** ✓（这与 §7 第 4 条的结论一致，且更强）

> ⚠️ **将来若要启用 DDI 挂载**（例如为 LiveContainer 加 JIT），pre17 那条路本身有两处坏味道，
> 启用前必须先修：① 它从 `raw.githubusercontent.com/jkcoxson/JitStreamer/master/versions.json`
> 取 DDI 下载地址（**第三方源**；post17 用的是 Apple 官方 URL）；② `downloadPre17Image` 用
> `try Data(contentsOf:)` 把 zip ＋ dmg **整块读进内存** ⇒ 违反 `AGENTS.md` §2「500MB+ 只流式处理」✗

### 8.3 「降到 iOS 16」的真实门槛（依赖审计）

| 查了什么 | 结果 |
|---|---|
| 7 个依赖的最低平台 | Minimuxer **13**；AltSign / CodeSignKit / GSACryptoKit / libdeflate **14**；AnisetteKit / SideSign **15** ⇒ **无一要求 17** ✓ |
| 主代码 iOS 17+ 专属 API | `@Observable` / `import Observation` / SwiftData / `symbolEffect` / `scrollTargetBehavior` / `scrollPosition` / `containerRelativeFrame` / `ContentUnavailableView` / `PhaseAnimator` / `KeyframeAnimator` / `sensoryFeedback` / `geometryGroup` / `visualEffect` / `scrollBounceBehavior` / TipKit / `onGeometryChange` / `defaultScrollAnchor` ⇒ **全部 0 命中** ✓ |
| 仅剩两处 | ① `GlassSurface.swift:19` 的 `.glassEffect` **已在 `#available(iOS 26.0, *)` 内** ✓ 安全；② `onChange(of:)` 的**双参数闭包写法**（iOS 17 才有的重载）⇒ **已改为单参数**（见 §8.5）|
| 外部依赖 | 上游 **SideStore README 明写 iOS 14+**（xcodeproj 15.0）—— Seal 的安装链路来源；**LocalDevVPN 要求 iOS 14.0+**（官方 README）⇒ 都覆盖 iOS 16 ✓ |

⇒ **「装不上 iOS 16」纯粹是 9 处声明（`Config/Base.xcconfig` 1 处 ＋ `project.yml` 5 处
＋ 三份 workflow 各 1 处 CI 断言），不是技术依赖** ✓
（`SWIFT_VERSION = 6.0` ＋ strict concurrency 是**编译期**设置，与运行时最低版本无关。）

### 8.4 把握度与剩余未知

**已消除的风险**：§5.2 那条 Lockdown 通道**已由构建 190 在 iOS 17.0–17.3.1 上全流程真机验证通过**
⇒ 由于 8.1 已证「两条路是同一套代码」，iOS 16 的推理基础从「理论上应该行」升级为
**「同一条路已验证」** ⇒ **配对能成功的把握：高** ✓

**仍只能靠真机回答的三个未知**：

1. 上游 `idevice_pair` 的 **Lockdown 模式没有版本下限、也没有 iOS 16 的验证记录**
   （README 只写 *"Lockdown for older versions"*）；
2. iOS 16 的 lockdownd：需设备上点「信任」，且 **iOS 16 起强制开发者模式**
   （Seal 有 onboarding 引导 `enableDeveloperMode`，但从未在 16 上跑过）；
3. iOS 16 的 installd 对开发者签名包的校验行为。

**结论**：要支持 iOS 16，改动面很小（**9 处部署目标声明 ＋ 1 处 `onChange` ＋ 2 处版本文案**），
**但验收只能靠真机** —— 不能拿 17.0–17.3.1 的通过去替 iOS 16 背书。

### 8.5 落地记录（2026-09-21）

**部署目标 17.0 → 16.0**，共 **9 处** —— 漏掉任意一处，要么那个 target 仍按 17.0 编译
（装到 iOS 16 设备上起不来），要么 **CI 自己把已降级的构建判为失败**（本机无 Swift 工具链，
两类问题都只能靠云 CI 暴露）：

| # | 位置 | 原值 | 现值 |
|---|---|---|---|
| 1 | `Config/Base.xcconfig` | `IPHONEOS_DEPLOYMENT_TARGET = 17.0` | `16.0` |
| 2 | `project.yml` → `options.deploymentTarget.iOS` | `"17.0"` | `"16.0"` |
| 3–6 | `project.yml` → `Seal` / `DeviceSupport` / `SealTests` / `SealUITests` | `"17.0"` | `"16.0"` |
| 7 | `.github/workflows/ios.yml` → `Verify deployment targets` | `test "$SEAL_TARGET" = "17.0"` | `"16.0"` |
| 8 | `.github/workflows/ios-fast.yml` → `Verify Seal minimum deployment target …` | `test "$TARGET" = "17.0"` | `"16.0"` |
| 9 | `.github/workflows/ios-release.yml` → `Verify Seal minimum deployment target …` | `test "$TARGET" = "17.0"` | `"16.0"` |

> ⚠️ **`Config/Base.xcconfig` 那一处最容易漏** —— `Debug.xcconfig` / `Release.xcconfig` 都
> `#include "Base.xcconfig"`，只改 `project.yml` 等于两个配置一起漏。
> 守卫 **R68** 钉住这 9 处（含「`project.yml` 里不许再出现 `17.0`」＋ 5 个变异锚点）。

#### 🔴 第 7–9 处是**漏过一次**才补上的（2026-09-21，白烧一轮 CI）

第一版只改了 1–6，推上去 `build-package` 在 `Verify deployment targets` 步骤红 ✗。
根因**不是没查**，而是**查法有洞**：

- `AGENTS.md` 里本来就写着「CI 校验 `IPHONEOS_DEPLOYMENT_TARGET=17.0`；**改部署目标时同步查
  三份 workflow 的断言**」—— 我上轮核对 `AGENTS.md` 时的结论是「无最低版本相关表述」✗，
  **把最该看的那一行漏了**。
- 更关键的是**守卫当初只钉 Xcode 声明、没钉 CI 断言** ⇒ 本地守卫**全绿**，
  却拦不住 CI 红。⇒ **教训：「守卫绿」≠「判据完整」**；「CI 里有没有反向断言」必须自己
  去 grep，不能假设守卫覆盖了。

这三处断言的**强度其实比读 `project.yml` 更高**：它们跑 `xcodebuild -showBuildSettings`
断言**生成产物**里的 `IPHONEOS_DEPLOYMENT_TARGET`，验证的是「XcodeGen 真的把它写进工程了」。
⇒ 不能删，只能跟着改。现守卫 R68 已覆盖全部 9 处，并各配变异锚点。

**代码侧**：`Seal/Features/Apps/SigningProgressView.swift` 的 `onChange(of:)` 从
**双参数闭包**改为**单参数** —— `onChange(of:) { old, new in }` 是 iOS 17 才引入的重载，
降到 16 直接编译失败。语义等价（原本就没用旧值）。
复核：`Seal/` 里 **13 处** `onChange(of:)` **全部是单参数形式，零双参数残留** ✓

**文案**：`AboutView` 的「最低支持」→ `iOS 16.0`；`PairingSettingsView` 的配对说明改为
「远程配对需要 iOS 17.4 及以上；iOS 17.0–17.3.1 与 iOS 16 会改用「本机配对」（Lockdown）」。

#### 更硬的那道门槛：预编译 RustBridge 已经过关

「改声明就够了吗」的答案在这里：`Vendor/Minimuxer/RustBridge/lib/RustBridge.xcframework`
是**预编译静态库**，自带 Mach-O 最低系统版本 —— 它比 Xcode 声明高时，改 `project.yml` 也没用。
直接解析二进制实测（Windows 上无 `vtool`，走 ar 归档 ＋ `LC_BUILD_VERSION`）：

| slice | 对象数 | minOS |
|---|---|---|
| `ios-arm64/librust_bridge.a` | 819 | **16.0.0** |
| 同上（Rust 运行时助手对象） | 390 | 10.0.0 |
| `ios-arm64-simulator` | 819 / 390 | 16.0.0 / 14.0.0 |

⇒ **已是 iOS 16 可用，不需要重编** ✓，且该二进制**已提交在远端**。

仓库还已有全套兜底设施，`ios.yml` **每次 CI** 都会跑：
`Vendor/Minimuxer/RustBridge/Makefile`（`IPHONEOS_DEPLOYMENT_TARGET ?= 16.0`）／
`Scripts/ensure-rustbridge.sh`（默认 16.0，指纹不符当场重编）／
`Scripts/verify-rustbridge-minos.sh`（默认 `MAX_IOS_VERSION=16.0`）／
`.github/workflows/rebuild-rustbridge-ios16.yml`（手动重编 ＋ artifact）。
⇒ 有人把库编高了会**当场红** ✓。

#### 配对助手侧：它本来就不拒绝 iOS 16

助手的判据只有一条 —— `major > 17 || (major == 17 && minor >= 4)`：

| 设备 iOS | 助手选的配对类型 | 会生成配对文件吗 |
|---|---|---|
| 17.4 及以上 | 远程配对 RPPairing | ✅ |
| 17.0 – 17.3.1 | 本机配对 Lockdown | ✅ |
| **16.0 – 16.7.x** | **本机配对 Lockdown** | **✅** |
| 15.x 及以下 | 本机配对 Lockdown | ✅（但见下） |
| 读不出版本（`—` / 空 / 乱码） | — | ❌ 禁用生成 |

**没有 `major < X` 这类拒绝分支** ⇒ 助手**一个版本都不拒绝**。
本次给它补了**两道独立闸门**的 iOS 16 标记：`patch_upstream.py` 的注入单测 ＋
`pairing-assistant.yml` 的 `required` 清单（守卫 **R69** 同时钉住两者 ——
只留一道就是自洽判据，实现与判据一起被改掉照样绿）。

> 🔴 **「助手能生成」≠「能用」**：配对文件必须写入设备上**已装的 Seal**（`install_pairing_file_to_seal_if_ready`）
> ⇒ **实际可用下限由 Seal 的部署目标决定，不是由助手决定**。
> **iOS 15.x 及以下**：助手照常生成文件，但 Seal 装不上 ⇒ **无处可写**。

### 8.6 仍未验证的部分（**验收只能靠真机**）

🔴 **iOS 16 的 Lockdown 通道从未跑过真机。** 本文档 §8.1–§8.5 全部是**静态判据**，
不能替代真机；构建 190 验的是 **iOS 17.0–17.3.1**，**不能替 iOS 16 背书**。

| 待验项 | 为什么只能真机 |
|---|---|
| 助手对 iOS 16 生成 Lockdown 配对文件 | 上游 `idevice_pair` 的 Lockdown 模式**无版本下限、也无 iOS 16 验证记录**（README 只写 *"Lockdown for older versions"*） |
| 写入 Seal → 导入 → 通道验证 | iOS 16 的 lockdownd 需设备上点「信任」，且 **iOS 16 起强制开发者模式**（Seal 有 onboarding 引导，但从未在 16 上跑过） |
| 装 App → 点开 | iOS 16 的 installd 对开发者签名包的校验行为未验 |
| 续签（含批量） | 同上 |

**前置条件**：设备需能装 **LocalDevVPN**（要求 iOS 14.0+ ✓），且 Lockdown **同样需要隧道** ——
设备 IP 来自 `utun` 对端，「本机配对」≠「不需要隧道」✓

**有意未做**：`MARKETING_VERSION` **未 bump** —— 用户明确「先不发更新版本」。
⚠️ 将来要让用户**检测到**这次支持范围的变化，必须 bump（内置更新只比版本串）。
