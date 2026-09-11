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

---

## 二、历史记录

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