# Seal Debug 记录（问题排查与修复日志）

> 用途：每次查出并修改的问题在此登记，记录「现象 → 根因 → 修复 → 涉及文件 → 验证状态」，
> 避免同类问题重复发生。新条目追加到「历史记录」顶部（最新在前）。
>
> 关联文档：`REWRITE_ROADMAP.md`（链路取舍）、`OPTIMIZATION_PLAN_*.md`（优化计划）、
> `ERROR_COPY_AUDIT_*.md`（报错文案口径）。

---

## 一、常犯坑位（教训沉淀，动手前先看）

### 1. 证书序列号跨来源比对必须先归一化
- **现象**：同一份证书，一处比对通过、另一处误判成「证书已被轮换 / 不在授权列表」。
- **根因**：序列号存在两种来源，格式不一致——
  - **AltSign**（`ALTCertificate.serialNumber` / `ALTX509Certificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的前导 `0`（如 `E76A893…`）。
  - **Security 框架**（`ProvisioningProfileReader` 经 `SecCertificateCopySerialNumberData` 按 DER 字节 `%02X` 拼串）保留前导 `0`（如 `0E76A893…`）。
  - 直接 `caseInsensitiveCompare` 会把同一序列号当成两个不同值。
- **规矩**：凡是「AltSign 序列号 ↔ 描述文件/证书列表序列号」的比对，一律先过
  `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`（去前导 0、转大写、只留十六进制）。
  同一来源内部的比对（如 AltSign↔AltSign，两端都剥前导 0）无需归一化，不要画蛇添足。
- **涉及文件**：`SigningCertificateSelectionPolicy.swift`（方法定义）、`ApplePortalSigningService.swift`、
  `SigningCoordinator.swift`、`ProvisioningProfileBinding.swift`、`AppPresentation.swift`、`SettingsViewModel.swift`。

### 2. 进度条「卡在 100%」的根因是阶段切换时机，不是进度值本身
- **现象**：大 IPA（如微信 ~500MB）上传进度到 100% 后，进度条长时间停在「正在传输 100%」，
  几十秒后才变「正在安装」。
- **根因**：上传（AFC 分块写）结束 ≠ 安装开始。中间隔着 Rust 侧预检（lookup / afcd 快照）以及
  installd 的解压/复制。旧逻辑只在「上传完成=100」处刷新进度，之后直到 installd 返回才切阶段，
  于是 UI 干等。
- **规矩**：需要三个信号的区分，不能把「上传完成」和「安装开始」混为一谈：
  - `0–100`：上传阶段真实进度。
  - **哨兵 `101`**（`INSTALL_ISSUED_PCT`，Rust 侧）：表示预检结束、installd 安装命令**即将下发**。
  - Swift 侧 trampoline 把 u64 的 `101` 换算成 `1.01`（`Double(pct)/100.0`），
    `p > 1.0` 即触发阶段从 `.pushing` 切到 `.installing`（文案「正在安装」），进度归 `1.0` 收尾。
- **涉及文件**：Rust `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`、
  `bridge_idevice.rs`；Swift `MinimuxerBridgeIdevice.swift`（trampoline）、
  `MinimuxerInstallChannel.swift`（哨兵透传）、`AppsViewModel.swift`（`updateInstallProgress` 切阶段）。

### 3. rg 命令别用 `-r` 当行号标志
- `rg -rn` 里的 `-r` 是「替换」flag（会把匹配内容替换成 `n`），不是行号；行号用 `-n`。
  避免 `-r` 与 `-n`、`-l` 混用导致的输出错乱。

### 4. 云编译结果别用 `gh run watch --exit-status` 的退出码当「成败」信号
- `gh run watch` 后台任务返回非零 exit code，是命令自身/超时问题，**不代表工作流失败**。
  判断成败一律看 `gh run list` / `gh run view` 的 `completed success/failure` 状态；
  别拿后台任务的 exit code 反推「云编译失败」，否则会把成功的构建误报成失败。

### 5. 掉签根因别一上来就甩给「证书过期/描述文件来源」
- 「今天签、明天掉」不是证书过期（免费证书有效期一年），也不该先怀疑 `SelfAppRegistrar`
  用当前 bundle 的 `expirationDate` 写库（签名安装成功时 `installSignedIPA` 会用签名当时的
  profile 过期时间覆盖它）。
- 真正要查的是「签名/续签时 profile 是否被复用、有没有刷新有效期」：
  `fetchProvisioningProfile`（`ApplePortalSigningService.swift:1213-1215`）对免费账号
  删除 profile 失败会直接复用现有 profile，其过期时间就是签名后 App 的有效期。
  先把 `provisioningProfiles → fetchProvisioningProfile → expirationDate` 这条链追清，
  再决定改哪，别先动 UI/文案。

### 6. Swift 6 严格并发：新增「下载/回调」代码必踩的两个红线
- **确凿证据**：云编译日志里 `swift-frontend ... -target arm64-apple-ios16.0 ... -swift-version 6 -Onone`
  （Xcode 26.5 强制 **Swift 6 语言模式**，project.yml 未显式写但流水线/工具链默认按 6）。新增带回调的服务类时必踩两个红线：
  1. **非 Sendable class 暴露 `static let shared`** 直接报
     `static property 'shared' is not concurrency-safe because non-'Sendable' type 'UpdateIPADownloader' may have shared mutable state`，
     后跟 note：`class 'UpdateIPADownloader' does not conform to the 'Sendable' protocol`，
     并给两条修复建议 note：`add '@MainActor' to make static property 'shared' part of global actor 'MainActor'`
     / `disable concurrency-safety checks if accesses are protected ...`。
     → 无状态服务一律用 **`struct`**（不要 `final class` + 持 stored let），`FileManager`/依赖内联 `FileManager.default`，不挂 stored property。
  2. **`URLSessionDownloadDelegate` 在 iOS 26.5 SDK 里 `didFinishDownloadingTo` 是 required**：
     note 原话 `protocol requires function 'urlSession(_:downloadTask:didFinishDownloadingTo:)' with type
     '(URLSession, URLSessionDownloadTask, URL) -> Void'`。按 async `download(for:delegate:)` 的用法只需实现它（空实现即可，
     async 返回后再由调用方 `moveItem`），否则 `does not conform`。
  3. **`NSObject` 子类 = `@unchecked Sendable` → stored 闭包必须 `@Sendable`**：
     报 `warning: stored property 'onProgress' of 'Sendable'-conforming class 'ProgressDownloadDelegate' has non-Sendable type '(Double) -> ()'`，
     note：`a function type must be marked '@Sendable' to conform to 'Sendable'`。
     → 跨线程进度回调签名统一 **`@Sendable (Double) async -> Void`**（对齐 `InstallChannel.install(onProgress:)` 约定）；
     UI 侧闭包用 `@MainActor` 参数直接更新 `@State`，别内层再套 `Task`。
- **涉及文件**：`UpdateIPADownloader.swift`（本次正例）、`InstallChannel` / `SigningCoordinator.onInstallProgress`（既有约定）。

### 7. gsa.apple.com 对「复用上次失败的 idle 连接」返回 503，关键认证须关闭连接复用
- **现象**：Apple 认证（登录/2FA/团队查询）偶发 `HTTP 503 Service Temporarily Unavailable`，
  同一账号重试有时能过、有时一直卡 503；在代理/TUN 切换后更明显。
- **根因**：`gsa.apple.com` 对复用上一个倒下的连接敏感。一次失败请求残留的 idle 连接若被下一个
  请求复用，Apple 直接回 503；而失败后立刻重试往往又复用了同一失效连接 → 越重试越 503。
  这是**连接复用**问题，不是认证凭据/anisette 问题（因此 `retryOnApple503` 纯靠隔几秒重发
  效果不稳定，且 `SEAL-AUTH-107t` 超时/`SEAL-AUTH-107a` 文案会误导排查方向）。
- **上游佐证**：iloader 2026-09-10 用同样根因修复 503 ——
  `isideload/src/auth/grandslam.rs` 构造 reqwest client 加 `.pool_max_idle_per_host(0)`
  （禁用每 host idle 复用），iloader 因此发版 **2.3.3**（升级 isideload `#f2fd29ab`→`#f6a4d5d`）。
- **规矩**：GSA 认证请求走 New 连接，不复用 idle 连接。Swift/URLSession 下没有 reqwest 的一行 API，
  等价做法是给认证 session 设 `URLSessionConfiguration.httpAdditionalHeaders = ["Connection": "close"]`
  （或逐请求加 `Connection: close`）。注意这是**认证 session 专属**，不要全局扩散到所有请求。
- **涉及文件**：`Forks①` `altsign-mod/Sources/ALTAppleAPI.swift:71`（session 加 `Connection: close`，
  一条覆盖登录 init/complete + 2FA trusteddevice/phone/validate 全部 GSA 请求）。
- **注意（落地前置）**：Seal 通过 SwiftPM 用 `github.com/dmjorb/AltSign@868f0ff`，本地
  `.dev-workspace/forks/altsign-mod` 与该 remote 同源（HEAD=868f0ff），改动须随该仓库发版
  并更新 `project.yml` revision 才会进真机。尚未真机回归。

### 8. 编译错误会被「前序 module 错误」掩盖，别凭上一轮报错数判断已修完
- Swift 是**模块级**编译。若某文件在 `-emit-module` 阶段报错（尤其是并发/Sendable、跨文件类型推断这类
  会中止 module 生成的错误），后续文件的类型检查可能压根没跑，那些错误就不会出现在日志里。
- **表现**：修好 A 文件的 2 个错误后复跑，冒出 B 文件 1 个全新错误（本例 `UpdateIPADownloader` →
  `SealCommunityView` 缺 `title`），看起来像「越修越多」，实则是上一轮被掩盖、本轮才浮出。
- **规矩**：修完一轮编译错误后，**必须再完整编译到底**，直到日志 `** BUILD SUCCEEDED **` 或
  `error:` 行为 0，才能下「修完了」的结论；不要用「上一轮只有 N 个错」来推断本轮已解决全部。

### 9. 发布 release 前必须复核 IPA 版本，别复用目录里残留的同名 Seal.ipa
- **现象**：版本已发、`releases/latest` 也返回新 tag，用户下载更新却仍是旧版。
- **根因**：`gh run download` 把 artifact（`Seal-<run_number>` 内含 `Seal.ipa`）解压进 `--dir` 时，
  若目录已残留上次构建的同名 `Seal.ipa`，会同时出现「根目录旧 `Seal.ipa`」和「`Seal-<n>\Seal.ipa` 新产物」；
  发布误选了根目录残留旧文件（1.0.9 / build 59），而非新产物（1.0.10 / build 61），二者大小仅差 ~4KB。
- **规矩**：下载产物前先清空目标目录；发布前用 `python` 读 IPA 内 `Payload/Seal.app/Info.plist` 的
  `CFBundleShortVersionString` + `CFBundleVersion` 复核版本，别只凭文件名 `Seal.ipa` 判断。

---

## 二、历史记录

### 2026-09-12 · 云编译失败：部署目标断言过期 + 扩展 App ID 限额识别误用 `Self.` 引用不同类型
- **现象**：`9fed6f3` 把最低版本提升为 iOS 17 后，`iOS Fast IPA` 云编译先在「Verify Seal minimum
  deployment target remains iOS 16」步骤 `exit 1`（CI 断言仍写死 16.0，实际读到 17.0）；修掉断言
  重新触发后真正进入编译，又崩在 `ApplePortalSigningService.swift:1112/1114`：
  `type 'Self' has no member 'isAppIDRegistrationLimit'` / `'appIDFailure'`。
- **根因**：① `ios-fast.yml`/`ios.yml` 里 `test "$TARGET" = "16.0"` 是**写死的旧断言**，没人跟着
  `9fed6f3` 一起升 17，于是卡在编译前；② `appIDFailure`（95 行）与 `isAppIDRegistrationLimit`
  （150 行）定义在 **`enum ApplePortalSigningFailure`** 里的 `private static func`，但扩展 App ID
  限额识别的新调用点落在 **`actor ApplePortalSigningService`** 里，误用 `Self.` 前缀——`Self` 指向
  actor，根本没有这两个成员；且 `private` 在同文件跨类型也不可见。
- **修复**：① 两个 workflow 的部署目标断言 `16.0 → 17.0`（Seal 与 SealTunnel 各一处）；
  ② `appIDFailure` / `isAppIDRegistrationLimit` `private → fileprivate`；③ 调用点 `Self.` →
  `ApplePortalSigningFailure.`。另：`PacketTunnelProvider.swift` 的 Sendable capture 是 warning，
  不致命，未动。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（4 处）、
  `.github/workflows/ios-fast.yml`、`.github/workflows/ios.yml`。
- **验证状态**：本地 Windows 无法编译 Swift，待云编译复验。

### 2026-09-12 · 签名/续签进度条「直接跳」而非丝滑：根因 Rust chunk=total/20，改为 1% 粒度
- **现象**：签名/续签上传阶段进度条「一格一格跳、不丝滑」，小 IPA（几秒传完）尤其明显，
  几乎 0 一下蹦到 100；环形进度环看似平滑但线性条/百分比是瞬跳。
- **根因**：Rust `stage_via_afc`（`Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`）
  用 `let chunk = (total / 20).max(256 * 1024)` —— 整个 IPA 只切 **20 块**，配合
  `if pct > last_pct`（整数百分比递增才回调），整个传输只上报 **约 20 个点（每跳 +5%）**。
  这不是 UI 缺动画，而是**源头进度值本身就稀疏**。（UI 层线性 `ProgressView` 无 `.animation`、
  百分比 `Int(progress*100)` 截断，是次级加剧，非根因。）
- **修复**：chunk 改为 `(total / 100 + 1).max(64 * 1024).min(1024 * 1024)`，把进度粒度从 5% 提细到
  1%、回调点从 ~20 个增到 ~100 个；上限 1MiB 与底层 AFC 分块对齐（避免 FFI 回调过频），下限 64KiB
  保证小 IPA 也有足够回调点（不致 33% 一跳）。
- **涉及文件**：`Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`（`stage_via_afc`，1 行。
  纯进度反馈，不影响写入正确性——底层 AFC 本按 1MiB 自动分块、`written` 累加 + 回读
  `info.size == ipa_bytes.len()` 校验兜底）。
- **验证状态**：仅改 Rust、本机无法编译，待 Xcode 编译 + 真机回归（微信/黄豆短剧/抖音等大中小
  IPA 各验一次，确认体感丝滑且安装/续签成功不受影响）。

### 2026-09-12 · 抖音 addAppID 1100 根因查证：端点一致性确认非客户端 bug（无代码改动）
- **现象**：签名抖音时，同一 session 的 `fetchTeams` / `fetchCertificates` / `fetchAppIDs`（查询）
  均成功，唯独 `addAppID`（新建 `com.ss.iphone.ugc.Aweme…` Bundle）返回
  `Apple.APIError 1100 Your session has expired. Please log in.`。日志显示账号「5 个可用 App ID」、
  无 3013/1009 痕迹，排除「App ID 7 天 10 个限额」（另一个独立限制，抖音 1 主 + 8 扩 = 9 个
  App ID 会额外撞它，但本次卡点不是它）。
- **根因（查证结论）**：客户端层面 `addAppID` 与 `fetchAppIDs` **完全等价** —— 二者同走 AltSign
  `sendRequest`（`ALTAppleAPI.swift:205`），同一 `X-Apple-GS-Token`(authToken)、machineID、
  oneTimePassword、localUserID、deviceUniqueIdentifier、date 认证头，同一 `baseURL =
  developerservices2.apple.com/services/QH65B2/`，唯一区别是 action 名（`ios/addAppId.action` vs
  `ios/listAppIds.action`）与 `additionalParameters`（写参数 vs nil）。`1100` 是 Apple 在 plist
  `resultCode` 里返回的（`processResponse`），`addAppID` 的 `resultCodeHandler` 只认
  35/9120/9401/9412，1100 落 default 分支原样透传为 `NSError(code:1100, "Your session has
  expired...")`。→ **1100 单独落在 addAppID 是 Apple 服务端对「写操作 addAppId.action」的 session
  判定行为，非 Seal/AltSign 代码 bug，客户端无法通过改端点/认证头消除。**
  （注：`certificate→servicesBaseURL(v1 JSON)` 与 `AppID→baseURL(QH65B2 plist)` 是两套 API，但
  二者请求都发生在 addAppID 之前且已成功，与本结论不冲突。）
- **顺带确认（同轮）**：
  ① `reauthenticate`（1100 时自动重登，`AppleAccountClient.swift:140`）全仓库**零调用点**，
  `AppleServiceFailurePolicy` 注释「下次签名自动重登」与实际不符；但**不建议接线**——签名/续签是
  LocalDevVPN 环境、自动重登访问 gsa.apple.com 必败（`ApplePortalSigningService.swift:294`），且
  历史上「清指纹/换 anisette 重试」曾造成全部账号掉线回归（`AppleAccountClient.authenticate` 注释）。
  ② `removeIdentifier()` 零调用点；identifier 丢失只可能来自换 Team 重签名导致 Keychain access
  group 变化 → `loadIdentity` 静默重生成新 `deviceIdentifier`（`AnisetteClient.swift:332`），进而 1100。
- **涉及文件**：`.dev-workspace/forks/altsign-mod/Sources/ALTAppleAPI+Operations.swift`、
  `ALTAppleAPI.swift`（查证，未改）；`AppleAccountClient.swift`、`AnisetteClient.swift`（顺带确认）。
- **验证状态**：纯代码查证，**无代码改动**。可操作结论：抖音 addAppID 1100 客户端唯一缓解路径是
  「重新验证 Apple ID 拿新鲜 authToken 后立刻签抖音」（即 `SEAL-AUTH-107` 引导的方向）；其本质是
  免费账号 + Apple 写接口会话校验的硬约束，非 Seal 可修复缺陷。

### 2026-09-12 · 批量续签误拦已绕过 3-app 上限的用户 + 抖音签名 1100 会话过期分类错误
- **现象**：① 用户（Lara）已用「绕过 3-app 上限」装了 6 个应用，点「全部续签」时 6 个全部失败
  （提示「应用数量已达上限」/ `SEAL-APPID-DEVICELIMIT`），但逐个单独续签却能成功；
  ② 签名抖音时 Apple 返回 1100 会话过期，却显示误导性的「App ID 创建失败 / 检查网络」
  （`SEAL-APPID-303`），而非「会话已过期 / 重新登录」。
- **根因**：
  ① `RenewalCoordinator.refreshAll` 调用 `signingCoordinator.signAndInstall` 时漏传
  `bypassFreeAccountDeviceLimit`，导致已装 6 个应用的用户在批量续签时被
  `enforceFreeAccountInstallLimit` 预检（设备级跨 team，occupied=5≥3）全部误拦。单独续签能过
  是因为单签路径有「继续绕过」按钮走 `continueBypassingDeviceLimit` 传 true，批量路径没有该按钮、
  直接判失败。
  ② `ApplePortalSigningFailure.appIDFailure`（App ID 创建阶段）漏识别 1100 会话过期，落进通用
  「App ID 创建失败 / `SEAL-APPID-303`」分支误导排查（上轮曾做「全局归类」后回退，本次只在 App ID
  阶段精准补识别，不扩散到其他阶段）。
- **修复**：
  ① `RenewalCoordinator.swift` 续签调用补传 `bypassFreeAccountDeviceLimit: true` —— 续签是覆盖
  已装应用、不新增免费账号设备槽位，预检应跳过、交回 installd 裁决；单个应用续签仍走
  `runSigning`（默认 false），与既有「继续绕过」按钮行为保持一致。
  ② `ApplePortalSigningService.swift` `appIDFailure` 在 Bundle ID 占用 / 7 天限额判断之前，
  新增 `nsError.code == 1100 || normalized.contains("session has expired") ||
  diagnostic.contains("1100")` 识别，归类 `SEAL-AUTH-107`（「会话已过期 / 重新登录」），
  与 `.account` 阶段一致；随后会被 `signOnce` 既有 `SEAL-AUTH-107` catch 兜底提示「去我的页面
  重新验证 Apple ID」。
  ③ 补上 `RenewalCoordinator.isRetryable` 的确定性失败排除：`SEAL-APPID-DEVICELIMIT` /
  `SEAL-INSTALL-702l`（iOS 拒绝：3 应用上限/完整性校验）/ `SEAL-INSTALL-702s`（存储不足）
  返回不可重试，与单签路径 `SigningProgressView.isNonRetryableFailure` 对齐——绕过上限后批量
  续签若真正超限会被 installd 拒绝为 `702l`，若不排除会完整重签+上传+等待 3 次，且违反
  「确定性失败立即终止、不做无效重试」硬约束。
- **涉及文件**：`Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：① 绕过 3-app 上限装 6 个应用后
  「全部续签」不再被设备上限误拦；② 免费账号 authToken 过期（几小时后）签名抖音时提示
  「会话已过期 / 重新登录」而非「App ID 创建失败 / 检查网络」。注：1100 根因是免费账号
  authToken 仅几小时有效（Apple 硬限制），Seal 只能过期后正确引导重新登录，无法延长会话；
  ③ 设备状态与记录不一致（`lastInstalledAt` 残留）触发真正超限时，批量续签立即终止不再转圈。

### 2026-09-12 · 免费账号 App ID 7 天限额误报：3013 未被识别（iPhone17 / iOS27 beta3 用户日志）
- **现象**：用户（iPhone 17, iOS 27 beta3）签名 LiveContainer 报「App ID 创建失败 / 检查网络后
  重试」（`SEAL-APPID-303`）；续签 Seal 报「扩展无法创建 App ID / 移除扩展后重试」
  （`SEAL-EXT-401`）。日志关键行：`[AltStore.AppleDeveloperError 3013] You may only register
  10 App IDs every 7 days.`，且 07:49:42「Apple App ID 已同步：2 个可用 App ID」。
- **根因**：**Apple 免费账号「7 天内最多注册 10 个 App ID」限额触发**，与 iOS 27 beta3 / iPhone 17
  本身无关（任何系统都会触发）。Seal 有两个分类 bug 导致误报：
  ① `appIDFailure` 只匹配 AltStore 老错误码 `1009`，漏了新一代 AltSign 的 Apple 原生码 `3013`，
  于是 3013 落进通用「App ID 创建失败」分支 → 误导「检查网络」；
  ② 扩展 App ID 创建失败被外层 catch 笼统包成 `SEAL-EXT-401`「移除扩展后重试」，把全局限额
  掩盖成「扩展有问题」——但限额是全局的，移除扩展也救不了，且 Seal 自身必须保留 SealTunnel 扩展。
  **关键认知**：该限额是「7 天滚动注册总数」，不是「当前存活的 App ID 数量」，所以本地预检里
  `availableAppIDs = 10 - existing.count`（existing.count=2）放行后，真实 `addAppID` 才报 3013。
- **修复**：
  - 新增 `ApplePortalSigningFailure.isAppIDRegistrationLimit(_:normalized:)`，统一识别 1009/3013
    + 「every 7 days / 10 app ids / register / maximum / limit」等关键词。
  - `appIDFailure` 改用该共享函数 → 3013 正确归类 `SEAL-APPID-304`「7 天内最多注册 10 个 App ID」。
  - 扩展创建失败（`allowDroppingExtensions==false` 分支）先识别限额，命中则透传 `appIDFailure`
    的真正结果，不再包成误导性的「移除扩展」；非限额才走 `SEAL-EXT-401`。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`
  （`appIDFailure`、新增 `isAppIDRegistrationLimit`、扩展 catch 分支）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：免费账号 7 天名额满后签名任意
  应用（主 App 或扩展）均提示「7 天内最多注册 10 个 App ID」而非「检查网络 / 移除扩展」。
  **用户侧根治**：等 7 天过期、改用其他 Apple ID、或用付费账号；Seal 无法绕过 Apple 硬限制。

### 2026-09-12 · 全项目文案审计：3 处新发现问题修复
- **现象**：对 v1.0.13 全项目流程链 → 文案做精准匹配审计，发现 3 处与逻辑行为不匹配的文案。
- **根因**：①「注册开发者账号」措辞易让免费账号用户误以为需付费注册（免费账号登录 + 同意
  Apple 开发者协议即有 Personal Team）；②续签兜底（SEAL-RENEW-500）点名「检查 LocalDevVPN」，
  该兜底仅处理非 ImportFailure，隧道错误已有 701 等专码，且免费账号无外部 LocalDevVPN 可操作；
  ③SEAL-APPID-303 的 recovery 未覆盖 1100 会话过期场景（1100 会落入此分支，换 Bundle ID 无用）。
- **修复**：
  - `SettingsViewModel.swift:1134`（SEAL-AUTH-114）：「已注册开发者账号（免费账号即可）」→
    「可正常登录且已同意 Apple 开发者协议（免费账号即可）」。
  - `RenewalCoordinator.swift:96`（SEAL-RENEW-500）：「检查网络与 LocalDevVPN 后重试」→
    「检查网络后重试」。
  - `ApplePortalSigningService.swift:130`（SEAL-APPID-303）：recovery 前置「若提示会话已过期，
    请先前往「我的」页面重新验证 Apple ID」，再回退网络/Bundle ID 引导。
- **涉及文件**：`Seal/Features/Settings/SettingsViewModel.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：代码已改，未云编译、未真机回归。注：1100 归属仍走 SEAL-APPID-303 分支
  （上轮把 1100 全局归类修复回退了），本次仅从文案侧给出「先重新验证」引导兜底。

### 2026-09-12 · 隧道类报错文案口径修订（免费/付费账号区分 + 统一「检查是否打开 LocalDevVPN」）
- **现象**：v1.0.13 及更早的安装/配对报错文案中，隧道类错误（701/705/706b/706t/708/710/702t）
  一律让用户「打开 / 重连 / 确认 LocalDevVPN」，对两类用户都不精准：① 免费账号签名的 Seal
  内置隧道（SealTunnel）因缺 `networkextension` entitlement 起不来（必须装外部 LocalDevVPN
  软件），文案未告知；② 付费账号的隧道由 Seal 自动拉起（同名内置 VPN），没有可手动「打开」的
  外部软件入口。另有 708 文案「与电脑处于同一 Wi-Fi」纯错误——安装链路在手机端（本地隧道连本机），
  与电脑无关（历史遗留）。
- **根因**：文案起草时按「隧道=外部软件」的旧模型；且漏了「内置隧道需付费账号签名」这一关键约束。
- **修复**：隧道类报错 recovery 统一为「检查是否打开 LocalDevVPN」（对免费/付费两种账号都可操作）；
  reason 区分两种情况——免费账号签名的 Seal 需「先安装并打开外部 LocalDevVPN 软件」，
  付费账号「自动拉起内置隧道，检查 VPN 是否开启」；708 去掉「与电脑处于同一 Wi-Fi」；
  702d「WiFi」统一为「Wi-Fi」；709（隧道已通、握手失败）保持「保持前台后重试」不变。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`（701/705/706b/706t/
  708/710/702t 共 7 处文案）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：免费账号用户卡在「准备环境」时看到
  「免费账号需安装并打开外部 LocalDevVPN 软件」引导；付费账号行为不变。

### 2026-09-12 · Seal 内部更新后 Apple ID 失效需重新添加（覆盖安装签名 Team 变化 → iOS 判为新应用清空数据）
- **现象**：通过 Seal 内部更新（自更新 / 自续签）升级到新版本后，打开新版时已添加的 Apple ID 全部失效，
  需重新添加；已安装应用列表也一起丢失。
- **根因**：Seal 覆盖安装自己时，签名身份 = `application-identifier` = `TeamID + Bundle ID`。Bundle ID
  在自更新路径里由 `isSeal` 分支复用保留（`SelfAppRegistrar` / `BundleIDPolicy.targetBundleIdentifier`），
  但 **TeamID 取决于用哪个 Apple ID 签这次更新**。一旦 Team 变化，iOS 把覆盖安装判成全新应用：
  全新空容器（`Accounts.json`、`Seal.sqlite` 清空）+ Keychain 访问组失配（凭据读不到）→
  表现为「Apple ID 失效、需重新添加」。而 `beginSigning` 里 `resolvedAccountID =
  (isRenewal ? app.accountID : nil) ?? accountID` 依赖**落库的 `app.accountID`**，它一旦过期/为空
  就退回用抽屉所选账号，可能选到不同 Team 的账号触发数据清空。
- **修复**：`AppsViewModel.beginSigning` 对 `app.isSeal` 增加基于**当前运行 Seal 的真实签名 Team**
  （`SelfAppMetadata.current().signingTeamIdentifier`，读 embedded.mobileprovision）的账号纠正：
  优先改用同 Team 账号保住签名身份（并记日志）；只有找不到同 Team 账号（如首次从他人账号切到自己账号）
  才允许切换，并弹「更新将重置本地数据」提示（`SEAL-AUTH-105c`）。免费账号无 App Group，
  跨 Team 无任何可持久化路径（容器与 Keychain 访问组都随 Team 变），故只能「保身份 + 提示」，
  无法做到跨 Team 无损迁移。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`（`beginSigning`）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：用同一 Apple ID 自更新后 Apple ID 列表、
  已安装应用完好；换用不同 Team 账号时出现「更新将重置本地数据」提示。

### 2026-09-12 · 签名特定 IPA 时 Seal SIGTRAP 闪退（rork-sign 符号表邻接缩限产生负数 Data count）
- **现象**：签名/安装 SollinPlayer（Flutter + 大量 dylib，多数二进制为无 `LC_CODE_SIGNATURE`
  的 thin arm64）时 Seal 自身崩溃。两份 `.ips`（1.0.9 build59 与 1.0.11 build64，均 iOS 18.7.8）
  一致显示 `EXC_BREAKPOINT / SIGTRAP`，栈：`Data.init(repeating:count:) ←
  prepareThinMachOCMSCodeDirectories(_:options:) ← MachOSigner.prepareCMSCodeDirectories ←
  RorkSigner.signMachOWithIdentity ← BundleSigner.signCode`。
- **根因**：`MachOSigner.swift` 三处（`thinSigningCacheInput`、finalize 分支、
  `prepareThinMachOCMSCodeDirectories`）对「无既有 `LC_CODE_SIGNATURE`、全新追加签名」分支也套用了
  `layout.adjustedCodeLimit(rawCodeLimit)`（ldid 符号字符串表邻接缩限）。当某二进制的 LC_SYMTAB
  字符串表恰好落在文件末尾 16 字节内时，缩限把 `codeLimit` 压到比 `output.count` 还小，
  `Data(repeating: 0, count: Int(codeLimit) - output.count)` 的 count 为负 → `Data.init(count:)` 陷阱死亡。
- **修复**：三处改为 `hasExistingSignature ? layout.adjustedCodeLimit(rawCodeLimit) : rawCodeLimit`
  ——符号表邻接缩限只作用于「已有签名」分支；全新签名分支 `codeLimit` 直接取
  `alignUp(output.count, 16)`（≥ output.count，append 非负）。对正常二进制行为不变
  （原本 `adjustedCodeLimit` 在非邻接时本就返回 `rawCodeLimit`）。
- **涉及文件**：`Vendor/rork-sign/Sources/RorkSign/MachO/MachOSigner.swift`（3 处）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：签名 SollinPlayer 不再崩溃、产物可安装。

### 2026-09-12 · 证书/AppID 库存同步把任务取消误报为失败（SEAL-INVENTORY-900/900a 刷屏）
- **现象**：添加 Apple ID / 批量签名续签时，「诊断日志」里 `SEAL-INVENTORY-900`/`900a`
  「xxx 同步失败 [Swift.CancellationError 1]」反复刷屏，并连带污染证书健康状态。
- **根因**：`refreshAppIDInventory` 与 `refreshCertificateInventory` 的兜底 `catch {}` 把所有异常
  （含 `Swift.CancellationError`）都当普通错误转成 `SEAL-INVENTORY-900/900a`，并写入
  `certificateInventoryFailures` / `certificateHealthStatuses`。当外层 Task 被取消（切团队、
  并发刷新、页面 `.task` 重入）时，`fetchInventory` / `keychain.load` 抛 `CancellationError`，
  被误判为「证书同步失败」。
- **修复**：两个方法在 `catch {}` 前新增 `catch is CancellationError { return }`，取消时静默返回、
  不写失败标记、不污染健康状态（与本文件 `authenticateAndPersistAccount` 处既有
  `catch is CancellationError` 范式一致）。
- **涉及文件**：`Seal/Features/Settings/SettingsViewModel.swift`（`refreshAppIDInventory`、
  `refreshCertificateInventory`）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：切团队 / 批量续签时日志不再出现
  `Swift.CancellationError` 误报，证书健康状态不被污染。

### 2026-09-12 · 安装卡「正在连接设备」：内置 SealTunnel 从未激活，被迫依赖外部 LocalDevVPN 软件
- **现象**：真机不打开外部 LocalDevVPN 软件，签名/续签后的安装环节一直卡在「正在连接设备」，
  隧道始终连不通；手动打开 LocalDevVPN 软件后才可继续。
- **根因**：Seal 自带 `SealTunnel` Network Extension（`NEPacketTunnelProvider`，10.7.0.0/24
  反射隧道，bundle `com.mjorb.seal.TunnelProv`）此前**从未被激活**。`MinimuxerInstallChannel`
  安装流程只对 `10.7.0.1` 做 TCP `probeTunnel()` 探测，不通就直接放行/卡住，从不「按需拉起」隧道；
  由此本应等价于外部 LocalDevVPN 软件的扩展形同虚设，实际被外部软件代建隧道。
- **修复**（三层联动，纯本地 Swift、零新增 Rust）：
  1. `SealTunnelManager` 加 `static let shared` 单例 —— 让设置页与安装流程共用同一隧道实例状态
     （`@MainActor` 隔离，满足 Swift 6 并发，非「非 Sendable class 暴露 shared」红线）。
  2. `LocalDevVPNOnDemandActivator.activate()` 从「仅 probe + sleep」改为**真正调用
     `SealTunnelManager.shared.start()`** 拉起内置扩展（建 `com.mjorb.seal.TunnelProv` 虚拟网卡），
     等待由 900ms 延长到 1500ms 再探测。
  3. `MinimuxerInstallChannel` 安装链路：首次探测隧道不通时自动 `onDemandActivator.activate()`
     拉起 SealTunnel，再二次探测，通了才 `pass(.vpnTunnel)`。
  4. `LocalDevVPNSettingsView` 改用 `.shared`；`SettingsRootView` 签名分组新增「本地隧道」入口
     （`SettingsRoute.localDevVPN`），可手动启动/停止/重检。
- **涉及文件**：`SealTunnelManager.swift`、`LocalDevVPNOnDemandActivator.swift`、
  `MinimuxerInstallChannel.swift`、`LocalDevVPNSettingsView.swift`、`SettingsRootView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 不装外部 LocalDevVPN 软件，
  签名/续签后安装应自动拉起内置隧道并走「正在安装」成功；② 「我的 → 本地隧道」可手动启动/停止，
  状态与安装流程一致；③ 签名/续签环节（走 Apple 外网服务）全程不受该改动影响。
- **配置核对（已过）**：`project.yml` 里 SealTunnel `PRODUCT_BUNDLE_IDENTIFIER=com.mjorb.seal.TunnelProv`
  与 `SealTunnelManager` 的 `.TunnelProv` 后缀精确匹配；主 app 与扩展两份 entitlements 均含
  `packet-tunnel-provider`；扩展 `NSExtensionPrincipalClass=$(PRODUCT_MODULE_NAME).PacketTunnelProvider`、
  `embed: true` 确保进 IPA。

### 2026-09-12 · 更新检测正常但下载到旧版（发布 release 误用残留 IPA）
- **现象**：v1.0.10 已发布、`releases/latest` 返回 `v1.0.10`、编译 run headSha 与编译产物均正确，
  但用户反馈「点下载更新出来的续签页是 1.0.9 版本」。
- **根因**：发布 v1.0.10 时误用了 `.release_build` 目录里**残留的 1.0.9 IPA**（build 59，26,726,320 bytes），
  而非新编译产物 `Seal-61\Seal.ipa`（1.0.10 / build 61，26,730,549 bytes）。下载时目录未清空，根目录旧
  `Seal.ipa` 与新 `Seal-61\Seal.ipa` 并存，发布时只凭文件名选了旧的。
- **修复**：删除错误附件（asset id `557846624`），用正确产物重新 `gh release upload` v1.0.10。
- **涉及文件**：无代码改动；流程问题，见常犯坑位第 9 条。
- **验证状态**：release 附件现为 build 61（1.0.10，26,730,549 bytes）。用户重新检查更新应能正确下载 1.0.10。

### 2026-09-12 · 免费账号 3 应用上限：按钮文案/行为失配修复 + 支持 Lara 3-App Bypass 跳过预检
- **现象一（按钮文案与行为不一致）**：免费账号装第 4 个自签应用触发 `SEAL-APPID-DEVICELIMIT` 时，
  失败态主按钮显示「重试」，但 `performPrimaryRecovery` 里 `isNonRetryableFailure` 优先命中直接
  `dismiss`，点了并不会真重试；`SEAL-INSTALL-702l/702s` 同理显示「重新安装」但实际也是 dismiss。
- **根因一**：`primaryRecoveryTitle` 判断顺序里 `isNonRetryableFailure`（DEVICELIMIT/702l/702s）未提前，
  被 `isInstallChannelFailure`→「重新安装」、`isAppIDFailure`→「重试」先命中；而 `performPrimaryRecovery`
  第一分支就是 `isNonRetryableFailure → dismiss`，两处顺序不一致。
- **修复一**：`primaryRecoveryTitle` 顶部提前 `if isNonRetryableFailure(failure) { return "知道了" }`，
  三个确定性失败统一「知道了」并关闭（落实既有约束）。
- **现象二（无法配合 Lara 绕过）**：Lara 3-App Bypass 在设备本地移除免费 profile 3 应用上限检查
  （DarkSword 内核 exploit；仅 iOS 17.0–18.7.1 / 26.0.x，M5/A19 不支持，且不增加 10-App ID 服务器上限），
  但 Seal 的 `enforceFreeAccountInstallLimit` 是签名前客户端硬预检，≥3 直接抛 DEVICELIMIT、到不了
  installd，导致 Lara 绕过对 Seal 用户无效。
- **修复二**：引入 `bypassFreeAccountDeviceLimit: Bool = false` 默认参数，链路
  `SigningProgressView`（DEVICELIMIT 失败态双按钮：主「已用 Lara 绕过，继续安装」+ 次「知道了」）
  → `AppsViewModel.continueBypassingDeviceLimit()` → `restartSigning`/`runSigning` →
  `SigningCoordinator.signAndInstall` → `enforceFreeAccountInstallLimit`（`guard bypass... == false else return`）
  跳过预检，交回 installd 最终裁决：未真正绕过时 installd 仍回 `ApplicationVerificationFailed`
  （落到既有 `SEAL-INSTALL-702l` 分支）。默认参数隔离，付费账号 / 免费账号 <3 / 续签
  （`RenewalCoordinator` 不传 → false）/ 重试 / Bundle ID 检查等原链路零影响。
- **涉及文件**：`SigningCoordinator.swift`、`AppsViewModel.swift`、`SigningProgressView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 付费账号、免费账号第 3 个照常签名；
  ② 超限失败态为「已用 Lara 绕过，继续安装」+「知道了」；③ 已 bypass 点主按钮可装第 4 个，未 bypass
  点主按钮落到 iOS 拒绝（702l）。

### 2026-09-11 · 添加 Apple ID 报 503 Service Temporarily Unavailable（客户端标识被 Apple 封禁）
- **现象**：9 月 10 日全天 iloader 所有用户（含 Seal）添加 Apple ID 均失败，报
  `HTTP 503 Service Temporarily Unavailable`，来自 `https://gsa.apple.com/grandslam/GsService2`。
- **根因**：Apple 的 GSA 网关自 2026 年 9 月初起，对任何 `X-MMe-Client-Info` 头里含
  `com.apple.dt.Xcode` 的请求**在验证凭据之前**直接返回 503。这是服务端硬编码封禁，与账号/
  密码/连接复用/代理无关，所以「所有人、所有版本」同时中招。**推翻了此前「连接复用导致 503」的判断**
  （一次性 session 只是掩盖，不是根治）。
- **上游修法（对齐）**：iloader 提交 `a19f5f0`（"Fix GSA 503: replace blocked Xcode client
  identifier with akd"）把 `com.apple.dt.Xcode/x.y.z` 换成 `com.apple.akd/1.0`；同根同修的还有
  AltStore#1790、SideStore、xtool、coffer。共识：**client-info 用 akd，User-Agent 保留 Xcode 不动**
  （503 只由 `X-MMe-Client-Info` 头触发，与 User-Agent 无关）。
- **Seal 修复**：`AnisetteV3Client.fetchLocal` 硬编码的 clientInfo（经 `fetchAnisetteData(clientInfo:)`
  → `deviceDescription` → `ALTAppleAPI` 各请求的 `X-MMe-Client-Info` 头）由
  `<...com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>` 改为
  `<...com.apple.AuthKit/1 (com.apple.akd/1.0)>`。
- **未改动项（有意）**：
  - AltSign `ALTAppleAPI+Authentication.swift` 的 `User-Agent` 仍含 Xcode——按社区共识 User-Agent
    保留 Xcode，仅 client-info 用 akd。
  - AnisetteKit `LocalAnisetteProvider.defaultClientInfo` 仍是 Xcode——它是 `fetchAnisetteData` 等
    的**默认参数**，认证链路（`AppleAccountClient.authenticate → fetchForAuthentication →
    fetchLocal`）每次都显式传 clientInfo，永不落到该默认值，属死默认，无需改动。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：添加 Apple ID（本地 anisette）
  应不再 503，正常进入 2FA/完成登录。

### 2026-09-11 · 已安装 Seal 版本显示旧号 + 下载按钮卡 0 字节 + 更新弹窗样式统一（公告系统撤销）
- **现象一（版本不一致）**：已安装列表里 Seal 显示 `1.0.6`，「我的 → 关于 Seal」显示 `1.0.7`
  （两处读的是不同来源：列表读 `AppRecord.version`，关于页读运行中 `Bundle.main` 的
  `CFBundleShortVersionString`）。
- **根因一**：`SelfAppRegistrar.ensureRegistered` 的「待安装自更新源」早退分支
  （`hasPendingSelfUpdateSource == true` 且 ipa 文件仍在）直接 `return`，不做版本对账。
  若该标记残留（上次自更新中断、或外部方式装新包后未清），记录版本会**永久停旧值**，
  即使运行中的 Bundle 已经更新（外部云编译直装 1.0.7）也不会被纠正。
- **修复一**：早退分支加版本守卫——`Version.compare(existing.version, metadata.version) != .orderedAscending`
  才保留待安装源；记录版本低于运行版本（残留标记、已被外部更新取代）时落到原子更新，
  用运行中 Bundle 重打包并写回新版本号。既有的「运行旧版、待装新版」保护不受影响
  （待装源版本 ≥ 运行版本仍早退保留）。`Version` 工具随之移入独立文件
  `Seal/Infrastructure/Version.swift`（原定义在公告服务内）。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Infrastructure/Version.swift`（新）。
- **现象二（下载按钮没反应）**：更新弹窗点「下载更新」后卡住、按钮显示「已下载 Zero kB」且点不动
  （`byteCount(.binary)` 对 0 字节输出 "Zero kB"；下载中被 `.disabled(isDownloading)` 锁死，无法取消重试）。
- **修复二**：① `UpdateIPADownloader` 自定义 session：请求空闲超时 15s + 资源总时长 90s + 支持外部取消
  （`withTaskCancellationHandler`），卡死 30s 内必然报错或可手动取消；② 下载中再点按钮 = 取消，回到可重试态；
  ③ `received == 0 && total == nil` 时显示「正在连接…」，不再出现「Zero kB」。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`。
- **样式统一（更新弹窗）**：经用户澄清「公告弹窗」即更新弹窗，`UpdateNoticeView` 主卡片由毛玻璃
  `.ultraThinMaterial` 改为主题背景 `Color.sealSurface`、取消按钮 `sealSurfaceElevated`、描边
  `sealHairline.opacity(0.6)`，圆角/阴影/布局排版不变；独立的远端公告系统按用户确认**已撤销**
  （`AnnouncementView`/`AnnouncementService` 删除、`RootTabView`/`AppConfiguration` 还原、
  远端 `announcements.json` 已从 Releases 仓库删除）。
- **涉及文件**：`Seal/Features/UpdateNoticeView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 直装 1.0.7 云编译包后重启，
  已安装列表版本应自愈为 1.0.7；② 更新下载在弱网下 15s 内报「网络下载超时」或可点按取消；
  ③ 更新弹窗为不透明主题背景（非毛玻璃），布局与之前一致。

### 2026-09-11 · 下载进度显示真实字节数 + 赞赏码 tab 点击区修复 + 503 未落地说明
- **现象 A（下载进度卡住/假进度）**：真机「WiFi 一直转圈、挂梯子后 0% 突然跳到正在续签」。代码层面
  `UpdateIPADownloader.download` 的 onProgress 已改成 `(Int64, Int64?)`，但 `ProgressDownloadDelegate`
  仍是 `@Sendable (Double) async -> Void` —— **类型不匹配、编译过不了**，是上轮只改入口、没改 delegate 的中间态。
  且总大小未知（无 Content-Length）时 UI 拿不到真实字节数，只能干等或发假百分比。
- **根因 A**：progress 回调链「入口签名 ↔ delegate 属性/init/回调 ↔ UI enum」没一起改；`didWriteData`
  在 expected ≤ 0 时直接 `return`，总大小未知时进度永远不推进。
- **修复 A**：`ProgressDownloadDelegate` 全链改 `(Int64, Int64?)`；`didWriteData` expected ≤ 0 时 total 传 nil；
  `UpdateNoticeView.DownloadPhase` 改 `.downloading(Int64, Int64?)`，total 已知走线性进度条+百分比，
  total 为 nil 时显示「已下载 X」（`byteCount(style: .binary)`），消除「0% 突然跳续签」的假进度观感。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`。
- **现象 B（赞赏码 tab）**：抽屉顶部横杠与 tab 贴太紧；tab 只有「微信/支付宝」文字本身可点，整块区域点不动。
- **修复 B**：`rewardCodeSheet` 顶部 padding 20→32；tab 按钮 label 改 `.frame(maxWidth: .infinity, minHeight: 40)`
  + `.contentShape(Rectangle())`，整块可点、命中区约 44pt。
- **涉及文件**：`Seal/Features/Settings/SealCommunityView.swift`。
- **503 状态说明**：`Connection: close` 修复已 lock 进 `project.yml`（AltSign@87f61ce）且
  `AnisetteClient.appleRequest` 亦补齐；云编译 #34563251634（c7927b5）已成功。但发布出去的
  v1.0.4/v1.0.5 未让用户真正装上含修复的包（下载链路坏 + 未走签名安装），真机仍停在旧 1.0.3 IPA，
  所以「添加 id 还是 503」。另有 IP 限流分支（见常犯坑位 7）：`Connection: close` 只治「连接复用」类 503，
  换网络/热点后仍 503 多为 Apple 按 IP 封，客户端无法根治。
- **下一步待办**：bump MARKETING_VERSION → 1.0.6、push、云编译、发布 v1.0.6，真机回归下载进度 + 添加 id。
- **验证状态**：代码已改，**未云编译、未真机回归**。

### 2026-09-11 · About「检查更新」弹窗跳浏览器而非应用内安装 + gsa provisioning 路径补 Connection: close
- **现象一**：关于 Seal →「检查更新」→ 弹窗点「下载更新」，跳到 GitHub Release 网页，而非 Seal 内部下载+签名安装。
- **根因一**：`AboutView` 把 `UpdateNoticeView(onInstall:)` 传了 `nil`；`handleUpdate` 里 `guard let ipaURL, let onInstall`
  命中缺省分支走 `openURL(html_url)`。启动弹窗（RootTabView）有 onInstall（应用内），About 弹窗没有 → 两条入口行为不一致。
- **修复一**：RootTabView 抽出 `installSelfUpdate(_:)`（切 Apps tab + `importSelfUpdateFile` + 清理），
  经 `SettingsRootView.onSelfUpdateInstall` 下传到 `AboutView(onInstall:)`；About 弹窗下载完成后先收弹窗再导入安装，与启动弹窗一致。
- **涉及文件**：`Seal/App/RootTabView.swift`、`Seal/Features/Settings/SettingsRootView.swift`、`Seal/Features/Settings/AboutView.swift`。
- **现象二**：`AnisetteClient.appleRequest`（本地/远程 provisioning 打 `gsa.apple.com/grandslam/GsService2/lookup`
  及 midStart/midFinish）用默认 `.shared` session、未禁连接复用，与 AltSign 认证层（`Connection: close`）不一致，仍可能被 Apple 回 503。
- **修复二**：`appleRequest` 加 `Connection: close` 请求头，对齐 AltSign 认证 session 与 iloader `.pool_max_idle_per_host(0)`。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`（`appleRequest`）。
- **附加**：`UpdateIPADownloader.download` 加 `request.timeoutInterval = 30`，GitHub 资产域无响应时快速抛
  `transport` 错误显示「重试」，避免卡 0% 不报错。
- **验证状态**：代码已改，**未云编译、未真机回归**。
- **注意**：`Connection: close` 只能解决「连接复用」类 503；若仍有 503，多为 Apple 按 IP 限流（同 IP 请求过多被暂封），
  需换网络/热点或等 `Retry-After`，非客户端能根治。

### 2026-09-11 · Seal 更新下载进度卡 0%（totalBytesExpectedToWrite 为 -1 时被静默丢弃）
- **现象**：真机点「下载更新」，进度一直停在 0%，下载实际在走但 UI 不刷新。
- **根因**：`ProgressDownloadDelegate.didWriteData` 里 `guard totalBytesExpectedToWrite > 0 else { return }`。
  `totalBytesExpectedToWrite` 在响应无 `Content-Length`（GitHub 的 `browser_download_url` 302 重定向到
  `objects.githubusercontent.com`、chunked transfer）时为 `NSURLSessionTransferSizeUnknown`(-1)，guard 直接把回调
  丢掉 → 进度永远 0 也不报错。
- **修复**：改用任务的 `downloadTask.countOfBytesExpectedToReceive` 作首选锚点（重定向后跟随到真实长度，
  通常 >0 且准确），仅当它也不可用时才回退 `totalBytesExpectedToWrite`，避免依赖「首个响应的 -1」。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`（`didWriteData`）。
- **验证状态**：代码已改，主仓库 worktree 有改动，**未云编译、未真机回归**。
- **注意**：本项与「下载走代理/连接复用」是不同的两个问题；若下载源本身连不通（`SEAL-UPDATE-DL-503`），
  进度 0% 是表象、根因在网络，勿纠缠进度回调。

### 2026-09-11 · gsa.apple.com 503：关闭认证 session 的连接复用（对齐 iloader 2.3.3）
- **现象**：真机 Seal 添加 Apple ID 报 `503 Service Temporarily Unavailable`，
  重试时好时坏；iloader（Windows，同一 Apple 服务）今日开发者修好同类 503 并发版 2.3.3。
- **根因**：`gsa.apple.com` 对「复用上次失败的 idle 连接」敏感，代理/TUN 切换后残留连接被下一请求复用
  会被 Apple 拒 503；纯靠隔几秒重发不稳定，还会复用一个失效连接。
- **上游佐证（已核实）**：iloader 2026-09-10 提交 `348eefd` 升级 `isideload` `#f2fd29ab`→`#f6a4d5d` 并发 2.3.3；
  isideload commit `f6a4d5d` 标题 **"Disable pooling on reqwest client"**，在 `grandslam.rs` 构造 reqwest client 加
  `.pool_max_idle_per_host(0)`（禁用每 host idle 复用）。
- **修复**：altsign-mod `ALTAppleAPI.swift` 认证 `URLSessionConfiguration.ephemeral` 加
  `configuration.httpAdditionalHeaders = ["Connection": "close"]`（一条覆盖登录 init/complete +
  2FA trusteddevice/phone/validate 全部 GSA 请求），叠加既有 `retryOnApple503`(3s/8s)。
- **涉及文件**：`.dev-workspace/forks/altsign-mod/Sources/ALTAppleAPI.swift:71`（独立 git repo dmjorb/AltSign，HEAD=868f0ff）。
- **落地前置**：Seal 经 SwiftPM 依赖 `github.com/dmjorb/AltSign@868f0ff`，此改动须 commit+push
  更新 revision 才进真机。
- **2026-09-11 已落地**：AltSign fork 已迁至 `github.com/sunuannian1/AltSign`（保留上游
  SideStore/AltSign），修复 commit `87f61ce` 已推送；`project.yml` 的 AltSign url 改 `sunuannian1`、
  revision 锁 `87f61ce`，AnisetteKit 同步迁至 `sunuannian1/AnisetteKit`（revision 保持 `081200e`）。
  云编译将自动拉取含修复的依赖。**待真机回归**。

### 2026-09-10 · 二次编译暴露 SealCommunityView 漏传 title（错误被前序 module 错误掩盖）

- **现象**：修复 `UpdateIPADownloader` 两处并发错误后，复跑云编译 **run #34459031904** 仍失败
  （`Build fast unsigned IPA`，exit 65），但错误只剩 1 行、且换成了别处：
  `SealCommunityView.swift:104:49: error: missing argument for parameter 'title' in call`。
- **根因**：
  1. 直接根因：`SealCommunityView.qqCard` 调用 `communityCard(icon:subtitle:value:action:)`
     漏传 **required 参数 `title`**（`communityCard` 第 236 行 `title: String` 无默认值）。
     这是此前「QQ 群按钮不写群号」改动时误删了 `title:`，属遗留 bug。
  2. **为何上一轮 run #42 没报**：Swift 是模块级编译，run #42 在 `-emit-module` 阶段被
     `UpdateIPADownloader` 的 2 个并发错误中止，`SealCommunityView` 的类型检查未完成，
     此错被**掩盖**。修好前者、重新完整编译后它才浮出。
- **修复**：`qqCard` 补 `title: "加入 QQ 群"`（与 `telegramCard` 的「加入 Telegram 频道」对称，
  群号仍不展示）。
- **涉及文件**：`Seal/Features/Settings/SealCommunityView.swift`。
- **验证状态**：待云编译（run #34459031904 之后的下一次）+ 真机社群页 QQ 卡显示。
- **教训（沉淀为常犯坑位 7）**：**「编译只剩这几个错误」不成立**——module emit 阶段的前序错误
  会中止后续文件的类型检查，修复后必须重新完整编译才能看全剩余错误，别凭上一轮报错数判断已修完。

### 2026-09-10 · 应用内更新首次云编译失败（Swift 6 并发红线）→ 已修复

- **现象**：应用内更新方案（下载 → 导入 → 覆盖安装 Seal）首次提交云编译 **run #34456273529**
  报 `BUILD_FAILED: failure`。全量日志里真实 `error:` 行**仅 2 行**，均落在新增的
  `UpdateIPADownloader.swift`：
  1. `:6:16 error: static property 'shared' is not concurrency-safe because non-'Sendable'
     type 'UpdateIPADownloader' may have shared mutable state`
     （note：`class 'UpdateIPADownloader' does not conform to the 'Sendable' protocol`
     + 建议 `add '@MainActor'` / `disable concurrency-safety checks`）。
  2. `:90:21 error: type 'ProgressDownloadDelegate' does not conform to protocol
     'URLSessionDownloadDelegate'`
     （note：`protocol requires function 'urlSession(_:downloadTask:didFinishDownloadingTo:)'`）。
- **根因**（编译器命令行确凿 `-swift-version 6`，Xcode 26.5 强制 Swift 6 语言模式）：
  ① 下载器写成 `final class` 且持有 `let fileManager`（非 Sendable），却暴露 `static shared`；
  ② iOS 26.5 SDK 里 `didFinishDownloadingTo` 是 required，delegate 未实现；
  ③ `ProgressDownloadDelegate` 继承 `NSObject`（`@unchecked Sendable`），stored 闭包
     `onProgress` 是非 `@Sendable`，触发 `warning: ... has non-Sendable type '(Double) -> ()'`。
- **修复**：
  - `UpdateIPADownloader` 由 `final class` 改为 **`struct`**（去实例可变状态），`fileManager`
    改为内联 `FileManager.default`；`shared` 因此并发安全。
  - `ProgressDownloadDelegate` 补 `didFinishDownloadingTo` 空实现；`onProgress` 改
    `@Sendable (Double) async -> Void`，对齐项目既有 `InstallChannel` 进度约定；
    调用侧 `UpdateNoticeView.handleUpdate` 用 `@MainActor` 参数直接更新 `phase`。
- **涉及文件**：`UpdateIPADownloader.swift`、`UpdateNoticeView.swift`。
- **验证状态**：待云编译（run #34459031904 复跑）+ 真机下载进度 / 自动弹签名抽屉验证。
  教训已沉淀为「常犯坑位 6」。详见 `SEAL_INAPP_UPDATE_PLAN_20260910.md` §7。

### 2026-09-10 · 定位「今天签 Seal、明天掉签」根因

- **现象**：用户报告「今天签名安装 Seal，明天就掉签、闪退打不开」；真机日志另有
  TLS 握手失败（NSURLErrorDomain -1200）与设备存储满（No space left / errno 28/ENOSPC）。
- **排查过程（含两次误判，均已纠正）**：
  1. 误判一：把 `gh run watch --exit-status` 的后台任务返回非零 exit code 当成「社群页
     云编译失败」，实际 `gh run list` 显示 `completed success`（8m55s）。教训见「常犯坑位 4」。
  2. 误判二：一度把 `SelfAppRegistrar`（`expiryDate: metadata.expirationDate`，
     `SelfAppRegistrar.swift:161/165`）当掉签根源。深读后发现签名安装成功时
     `installSignedIPA`（`SigningCoordinator.swift:608`）会用签名当时的 profile 过期时间
     覆盖 `expiryDate`，该写法语义正确，不是根因。
- **决定性根因（2026-09-09 20:37 crash 报告 `diskwrites_resource` 一锤定音）**：
  **这不是「掉签」，也不是「存储满」——是 iOS「磁盘写入资源保护」终止。**
  - 报告数据：`Event: disk writes`；29 分钟（1745s）写 **1073.76 MB**（615 KB/s 平均），
    超过系统 86400s 周期限额 1073.74 MB；`Free disk space: 19.48 GB`（磁盘未满，
    「存储满」判断被推翻）。
  - 栈证据：栈顶 `libswift_Concurrency`（一个 Task 持续 active）→ Seal 函数 →
    `Foundation`（Data 写文件）→ `libsystem_c` → `libsystem_kernel write`。
    即 SealLogStore.append 的「全量重写 + atomic 写」在某个高频日志任务下放大成 1GB 写入。
  - 真正代码缺陷：`SealLogStore.append`（`SealLogStore.swift:23-44`）**每条日志都做**
    ① `read()` 全量读 + JSON decode 200 条 → ② 全量 JSON encode + `write(to:.atomic)`
    （临时文件+rename 双写）+ `fileProtector.protect` → ③ error 级别再 `mirrorToDocuments()`
    （全量 exportText + 写整个 Seal-log.txt）。任意高频日志（每秒几条）都会被放大成
    615 KB/s 的持续磁盘写入，最终触发 iOS 磁盘写保护被杀。
- **已排除的假设（记录防回头重复推理）**：
  - 免费账号 profile 复用（`fetchProvisioningProfile` 删除失败 `return profile`）——被「7 天」推翻。
  - `SelfAppRegistrar` 用 `metadata.expirationDate` 写库——语义正确，非根因。
  - 证书序列号归一化——已修（`34e6ae7` + rork-sign `formattedSerialNumberHex` 已剥前导零）。
  - 设备存储满（ENOSPC）、证书过期、TLS 中断——均非本次「闪退」直接根因。
- **修复方向**：根治 `SealLogStore` 的 O(n) 全量重写放大问题——
  (1) append 改为内存缓冲 + 节流批量落盘（debounce，去掉每条日志的全量读/写）；
  (2) 落盘用非 atomic 覆盖写，去掉 `protect` 的每次调用（或大幅降低频率）；
  (3) error 镜像 `mirrorToDocuments` 节流。同时定位「高频打日志」的任务源头一并收敛。
- **涉及文件**：`SealLogStore.swift`（核心）；`AppsViewModel.swift` / `SettingsViewModel.swift`
  （高频 append 调用点）。
- **验证状态**：待修复后真机复验（观察 crash 是否消失 + 日志是否仍可读/导出）。

### 2026-09-09 · 修复 Seal 无法自续签

- **现象**：Seal 自续签失败，日志/报错指向「证书已被轮换 / 不在授权列表」，
  但用户并未更换证书。更换 Apple ID、清缓存后依旧。
- **根因**：证书序列号跨来源比对未归一化（见「常犯坑位 1」）。AltSign 返回的本地证书序列号
  剥掉了前导 0，描述文件 `certificateSerialNumbers` 保留前导 0，同一证书被判成两个，
  触发「证书已轮换」误报 → 续签链路中断。
- **修复**：新增 `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`，
  统一「去前导 0、转大写、只留十六进制」；在 5 个跨来源比对点全部改用该方法：
  - `ApplePortalSigningService.swift`：签名前证书授权校验（`chosenSerial` vs 描述文件授权序列号清单）。
  - `SigningCoordinator.swift`：安装前描述文件授权证书匹配校验。
  - `ProvisioningProfileBinding.swift`：描述文件绑定校验（`normalizedSerial` 委托复用）。
  - `AppPresentation.swift`：证书匹配展示状态（`.mismatch` 误判）。
  - `SettingsViewModel.swift`：证书健康状态 / 关联应用计数。
- **涉及文件**：上述 5 个 + `SigningCertificateSelectionPolicy.swift`。
- **验证状态**：本机 Windows 无法编译 Swift，待 Xcode 编译 + 真机回归样本
  （微信 / 黄豆短剧 / LCSign / lanmanga）验证自续签与「本地证书复用前与 Apple 生效列表比对」路径。

### 2026-09-09 · 修复签名微信进度卡在 100%

- **现象**：签名微信时（约 500MB+），上传到 1 分 30 秒显示 100%，进度条一直停到 2 分 20 秒
  才消失、才变「正在安装」，进度不精准。附带观察：此前报「内存不足」（清理设备空间后重试可见
  进度问题）。
- **根因**：见「常犯坑位 2」。上传完成（=100）后 UI 仍停在「正在传输」，直到 installd 完成
  安装才切换阶段，中间几十秒的解压/复制被误显示为「传输中」。
- **修复**：Rust 侧在本轮之前已新增 `INSTALL_ISSUED_PCT = 101` 哨兵，在 `run_install_chain`
  即将向 installd 下发安装命令时回调。本轮补齐 Swift 侧消费逻辑：
  - `MinimuxerInstallChannel.swift`：`syncProgress` 收到 `p > 1.0` 时统一转发 `1.01` 给上层
    （普通安装也消费该哨兵，不再像旧逻辑直接 `return` 丢弃）。
  - `AppsViewModel.swift`：`updateInstallProgress` 收到 `progress > 1.0` 时把 `installProgress`
    归 `1.0`，并把阶段从 `.pushing` 切到 `.installing`。
  - UI 层 `SigningProgressView` 只在 `.pushing` 且 `0 <= progress <= 1` 显示进度条，
    `.installing` 显示「正在安装」，故哨兵触发后进度条立即消失、文案切换。
- **涉及文件**：`MinimuxerInstallChannel.swift`、`AppsViewModel.swift`（Rust 侧已在此前提交）。
- **验证状态**：待 Xcode 编译 RustBridge + 真机回归样本验证「上传 100% → 正在安装」切换是否及时、无闪烁。

### 附注（待真机核实，暂未改代码）

- 微信签名期初的「内存不足」：代码库中无字面「内存不足」文案，存储类错误已统一分类为
  「设备存储空间不足」（`SEAL-INSTALL-702s`，识别 `No space left / ENOSPC / errno 28 / code 28 /
  空间不足 / 储存空间 / 存储空间`）。该现象疑似 = 设备存储不足（已被现有分类覆盖）或设备侧瞬时
  RAM 压力，待真机日志复核，暂不新增代码。