#!/usr/bin/env python3
"""Small source-regression guard. This is NOT compilation or a runtime test."""
from pathlib import Path
import re
import sys
import runpy

HANDOFF_GUARD = runpy.run_path(str(Path(__file__).with_name("verify-certificate-handoff.py")))

ROOT = Path(__file__).resolve().parents[1]

def read(path):
    return (ROOT / path).read_text(encoding="utf-8-sig")

def section(text, start, end):
    # 标记找不到时必须报错，不能静默退化成「返回整段」—— 那会让守卫悄悄失去约束力，
    # 而且表现是「检查全绿」，比直接失败危险得多（2026-09-14 真实踩到一次）。
    if start not in text:
        raise AssertionError("section start marker not found: " + start)
    tail = text.split(start, 1)[1]
    if end not in tail:
        raise AssertionError("section end marker not found after " + start + ": " + end)
    return tail.split(end, 1)[0]

def section_or_empty(text, start, end):
    """`section()` 的**断言专用**变体：标记找不到时返回空串。

    为什么需要它（2026-09-17 实际踩到）：变异检查会对**每一个**变异重跑
    `violations()`。如果某个变异恰好删掉了某条 `section()` 的标记，`section()`
    就会 `raise` ⇒ **整轮守卫崩掉**，一条失败都报不出来，而真实原因是
    「那个变异确实破坏了被断言的结构」。

    返回**空串**（而不是整段）是关键：调用处一律写成 `"片段" in body` 的形式，
    空串会让断言**失败**。所以它既不会静默通过、也不会把整轮守卫带崩。

    ⚠️ 不要用它替换 `section()` 本身：`section()` 在「读源码做判断」的场合
    必须响亮失败，静默返回整段会让断言假通过。
    """
    try:
        return section(text, start, end)
    except AssertionError:
        return ""

def squash(text):
    """把连续空白（含换行与缩进）压成单个空格。

    多行代码的断言写成 `"case .inactive: return .waitForForeground"` 这种一行式，
    比在守卫里拼换行符 + 数缩进空格可靠得多 —— 缩进一改守卫就会莫名其妙地红。
    """
    return " ".join(text.split())

def strip_comments(text):
    """去掉 // 与 /* */ 注释，保留字符串字面量原样（字符串里的 // 不是注释）。"""
    out = []
    i = 0
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < len(text):
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "/":
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        if ch == "/" and i + 1 < len(text) and text[i + 1] == "*":
            i += 2
            while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)

_SIMULATOR_POSITIVE = re.compile(r"^targetEnvironment\s*\(\s*simulator\s*\)$")
_SIMULATOR_NEGATIVE = re.compile(r"^!\s*targetEnvironment\s*\(\s*simulator\s*\)$")

def simulator_activity(condition):
    """该条件在**模拟器切片**下的真假；不认识的写法返回 None（= 两片都算编译）。

    只认识 `targetEnvironment(simulator)` 这一种条件，是刻意的：`#if DEBUG`、
    `#if os(iOS)` 之类的取值不取决于目标平台，把它们当成「两片都编译」既不会漏掉
    真正的问题，也不会制造误报。
    """
    condition = condition.strip()
    if _SIMULATOR_POSITIVE.match(condition):
        return True
    if _SIMULATOR_NEGATIVE.match(condition):
        return False
    return None

def mask_inactive_on_simulator(text):
    """把「模拟器切片不编译」的行抹成等长空白，返回 (抹后文本, 被抹掉的行号集合)。

    为什么要连 `#if targetEnvironment(simulator)` 的 `#else` 分支一起抹掉：那段同样
    不在模拟器上编译。第一版只认 `!targetEnvironment(simulator)`，于是
    `bindTunnelConfiguration()`（定义在 `#if !simulator` 里、调用点却在
    `#if simulator` 的 `#else` 里）被误报成「模拟器缺符号」—— 两处都是设备专属，
    根本没有问题。误报比漏报更坏：它会逼着后来的人把守卫删掉。
    """
    out = list(text)
    frames = []
    blanked = set()
    offset = 0
    for index, line in enumerate(text.splitlines(keepends=True), start=1):
        stripped = line.strip()
        if stripped.startswith("#"):
            head = stripped.split(None, 1)[0]
            if head == "#if":
                frames.append(simulator_activity(stripped[3:]))
            elif head == "#elseif" and frames:
                frames[-1] = simulator_activity(stripped[len("#elseif"):])
            elif head == "#else" and frames:
                frames[-1] = None if frames[-1] is None else (not frames[-1])
            elif head == "#endif" and frames:
                frames.pop()
        if any(frame is False for frame in frames):
            blanked.add(index)
            for k in range(offset, offset + len(line)):
                if out[k] != "\n":
                    out[k] = " "
        offset += len(line)
    return "".join(out), blanked

# 只匹配**缩进恰好 4 空格**的声明，即顶层类型的成员。函数体内的局部变量缩进更深，
# 必须排除：`let ipaMB` / `let detail` 这类名字在设备专属分支与模拟器分支里各有一份，
# 按「名字出现在抹后文本里」判定会把它们全部误报成缺符号。
_SIMULATOR_MEMBER = re.compile(
    r"^    (?:@\w+[^\n]*\n    )*"
    r"(?:private\s+|fileprivate\s+|internal\s+|public\s+|open\s+)?"
    r"(?:static\s+)?(?:func|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.M,
)

def match_paren(text, open_index):
    """返回与 text[open_index] == '(' 配对的 ')' 下标；找不到返回 -1。"""
    depth = 0
    i = open_index
    in_string = False
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

def split_top_level(text):
    """按深度 0 的逗号切分（括号 / 方括号 / 花括号都算深度）。"""
    parts = []
    depth = 0
    in_string = False
    start = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if in_string:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return parts

def argument_labels(inner):
    """从参数列表文本里取出标签序列（`label: value` 形式）。"""
    labels = []
    for part in split_top_level(inner):
        matched = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", part.strip())
        if matched:
            labels.append(matched.group(1))
    return labels

_SWIFT_SOURCES = None

def swift_sources():
    """Seal/ 与 SealTests/ 下的全部 Swift 文件（进程内只枚举一次）。

    变异检查会把 `violations()` 跑 70+ 遍，每遍都 rglob 一次目录纯属浪费；
    实测这一步和下面的 strip_comments 缓存一起把守卫从近 3 分钟压回 40 秒内。
    """
    global _SWIFT_SOURCES
    if _SWIFT_SOURCES is None:
        _SWIFT_SOURCES = sorted(
            list((ROOT / "Seal").rglob("*.swift"))
            + list((ROOT / "SealTests").rglob("*.swift"))
        )
    return _SWIFT_SOURCES

_LOG_CODES = None

def all_log_codes():
    """源码里出现过的全部 `SEAL-XXX-NNN` 码（进程内只算一次）。

    只服务「日志码索引与源码一致」这一条断言 —— 它守的是**文档漂移**，不是运行时行为，
    所以刻意**不**走每遍的 `load`（否则每遍要读 165 个文件，变异检查会慢一个量级）。
    """
    global _LOG_CODES
    if _LOG_CODES is None:
        codes = set()
        for path in swift_sources():
            try:
                text = read(path)
            except OSError:
                continue
            codes.update(re.findall(r'"(SEAL-[A-Z]+-[0-9]+[a-z]?)"', text))
        _LOG_CODES = codes
    return _LOG_CODES


def violations(load=read):
    failures = []
    checks = 0
    def check(ok, message):
        nonlocal checks
        checks += 1
        if not ok:
            failures.append(message)

    # 每遍（= 每个变异）内的读取与去注释结果都只算一次。
    # 注意缓存必须在**单遍**作用域内：变异检查每遍喂进来的 load 都指向被改写过的内容，
    # 跨遍缓存会读到陈旧文本，让变异检查静默失效。
    _raw_cache = {}
    _stripped_cache = {}
    # 必须先把原始 loader 绑到另一个名字再重绑 `load`：闭包里引用 `load` 会指向
    # 重绑后的自己，直接 RecursionError（实测踩到）。
    original_load = load

    def load_cached(path):
        if path not in _raw_cache:
            _raw_cache[path] = original_load(path)
        return _raw_cache[path]

    def strip_cached(path):
        if path not in _stripped_cache:
            _stripped_cache[path] = strip_comments(load_cached(path))
        return _stripped_cache[path]

    load = load_cached

    rust = load("Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs")
    install = section(rust, "pub(crate) async fn run_install_chain", "fn is_missing_package_path")
    check(".uninstall(" not in install, "R01: installation recovery must not uninstall")
    swift = load("Vendor/Minimuxer/Sources/Install.swift")
    legacy = section(swift, "public class LockDownInstall", "public class RPInstall")
    legacy = section(legacy, "public func installIpa", "public func removeApp")
    check(".uninstall(" not in legacy, "R01: legacy installation must not uninstall")

    signing = load("Seal/Core/Signing/SigningCoordinator.swift")
    install = section(signing, "private func installSignedIPA(", "private func removeStaleProfiles(")
    check("InstalledAppDeviceVerifier.isInstalled" not in install,
          "R02: lookup cannot turn failed replacement into success")
    portal = load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    rotation = section(portal, "private func rotateCertificatesAndCreateIdentity(", "static func externalSealIdentityFailure(")
    check("revokeCertificate(" in rotation
          and "persistRevokedSigningMaterial(updatedSecret, [candidate.serialNumber])" in rotation
          and "createSigningIdentity(" in rotation,
          "R03: capacity recovery must revoke, persist, then create in one portal transaction")
    create = section(portal, "private func createSigningIdentity(", "private func waitForCreatedCertificate(")
    check("revokeCertificate(" not in create and "cleanUpNewCertificate(" in create,
          "R03: only cleanup of this operation's new certificate is allowed")

    # R04: Apple Portal 的超时必须走 HardTimeout（非结构化任务竞速）。用 withThrowingTaskGroup 时，
    # 任务组退出前必须等所有子任务结束，ALTAppleAPI 回调不返回会让超时错误被无限期拖住
    # —— 等于没有超时，UI 无限等待。此处 2026-09-14 修正过，别再退回去。
    timeout_fn = section(portal, "func withAppleTimeout", "\n}")
    check("HardTimeout.run" in timeout_fn and "withThrowingTaskGroup" not in timeout_fn,
          "R04: withAppleTimeout must use HardTimeout, not withThrowingTaskGroup")

    # R05: Apple 免费账号的请求节流 + 1100 退避重试（2026-09-16）。
    # 抖音这类「主 App + 8 个扩展」的 IPA 需要在 App ID 阶段连续注册 9 个号
    #（每个还要 updateFeatures），再连续申请 9 个描述文件 —— 短时间二十余次连发请求
    # 会触发 Apple 侧掐断会话，返回 1100 "Your session has expired. Please log in."。
    #
    # 判定它是限流而非真过期的依据：用户日志里每一次 AUTH-107 报错前 1–3 秒都有一条
    # 「证书决策」成功。证书申请能成功说明 session 在 Apple 服务端仍然有效，
    # 所以让用户「去重新验证 Apple ID」是死循环（重新登录后密集请求再次触发限流）——
    # 这正是用户反馈的「无论怎样在验证 Apple ID 就报错失效」。
    check("actor AppleRequestThrottle" in portal and "minimumInterval" in portal,
          "R05: Apple requests must be throttled to avoid rate-limit session drops")
    check("await AppleRequestThrottle.shared.wait()" in timeout_fn,
          "R05: every Apple request must pass through the throttle (single entry point)")
    recovery_fn = section(portal, "private func withSessionRecovery", "func sign(")
    check("sessionRecoveryBackoffNanoseconds" in recovery_fn
          and "Self.isSessionExpiredError(error)" in recovery_fn
          # 判据必须**真的在把守抛出**，而不是只出现在函数体里（2026-09-18 加固：
          # 判据被挪进 `let retryable = …` 之后，只查「有没有出现过」会失去约束力）。
          and "guard retryable else { throw error }" in recovery_fn,
          "R05: 1100 must back off and retry instead of failing immediately")
    check("static func isSessionExpiredError" in portal,
          "R05: session expiry classification must stay testable")
    # 逐行检查并跳过注释：文件里刻意留了「为什么不用 contains("1100")」的说明注释，
    # 直接对整段文本做 `not in` 会被自己的注释触发（2026-09-16 实际踩到）。
    substring_matches = [
        line for line in portal.splitlines()
        if 'contains("1100")' in line and not line.strip().startswith("//")
    ]
    check(not substring_matches,
          "R05: 1100 must be matched by error code/message, never by substring")

    # R06: 安装通道的失败熔断 + 批量续签不再前置阻塞（2026-09-16）。
    # 批量续签原先在进入循环前 `await refreshSigningChannel()`，把整段隧道诊断
    #（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）压在「正在连接设备」上，
    # 这是「点续签后卡很久」的第二个入口。去掉前置等待的前提是通道层有熔断，
    # 否则通道不可用时 N 个 App 会各自重跑一遍 75s 诊断（N×75s）。
    renewal_view_model = load("Seal/Features/Apps/AppsViewModel.swift")
    batch_start = section(renewal_view_model, "private func startBatchRefresh(", "private func runBatchRefresh(")
    check("beginSigningChannel()" in batch_start,
          "R06: batch renewal must warm the channel in parallel")
    check("await self.refreshSigningChannel()" not in batch_start,
          "R06: batch renewal must not block on the tunnel diagnosis up front")
    install_channel_source = load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    check("failureCooldownSeconds" in install_channel_source
          and "lastFailureAt" in install_channel_source,
          "R06: install channel must fuse repeated tunnel diagnosis failures")
    check("clearFailureCooldown()" in renewal_view_model,
          "R06: user-initiated sessions must clear the fuse")
    # 熔断方法必须留在 protocol 主体里：只写在 extension 的话，`any InstallChannel`
    # 会静态派发到默认空实现，MinimuxerInstallChannel 的覆写永远不会被调用 ——
    # 表现是「用户手动重试也一直被拒」，且守卫全绿（同类坑见 install(onProgress:)）。
    protocol_source = load("Seal/Core/Installation/InstallChannel.swift")
    protocol_body = section(protocol_source, "protocol InstallChannel: Actor {", "\n}")
    check("func clearFailureCooldown() async" in protocol_body,
          "R06: clearFailureCooldown must be a protocol requirement (dynamic dispatch)")

    # R07: `UIControl.sendAction(_:to:for:)` 的返回类型是 Void，不是 Bool。
    # 2026-09-16 CI 因 `return UIControl().sendAction(...)` 编译失败（exit 65）：
    #   SigningProgressView.swift:645:28: error: cannot convert return expression of
    #   type 'Void' to return type 'Bool'
    # 「借 UIControl 发消息」是触发私有 selector 的经典写法，很容易顺手当成返回 Bool 用。
    # 需要判断「转场是否生效」时必须换判据（本项目改成「给足时间后进程是否仍存活」）。
    signing_progress_view = load("Seal/Features/Apps/SigningProgressView.swift")
    check("return UIControl().sendAction" not in signing_progress_view,
          "R07: UIControl.sendAction returns Void, not Bool — cannot be returned")

    # R08: 设备端旧描述文件清理必须覆盖扩展，且必须「有明确记录才删」（2026-09-16）。
    # 真机现象（StikDebug 的 App Expiry 页）：Seal 自己累积 17 份 profile，
    # LiveContainer 的 ShareExtension 一天内累积 6 份。两个原因：
    #   1. 安装后的清理只按**主** Bundle ID 匹配，扩展的 profile 从头到尾没人管；
    #   2. 清理只在安装成功那一刻触发，维护作业里根本没有这一步，所以历史堆积清不掉。
    # 反面约束同样重要：删错 profile 会让已安装的 App 立刻无法启动（iOS 启动时校验
    # profile 是否还在设备上），所以「拿不到可信的保留 UUID」时必须整条跳过，
    # 绝不能猜「保留最新那份」。
    profile_reader = load("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift")
    check("static func embeddedProfiles" in profile_reader
          and "isInstalledAppProvision(entry.path)" in profile_reader,
          "R08: cleanup must know every installed profile, including extensions")
    # 扩展包后缀是 .appex（本仓 SigningWorkspace / AppBundleSigningIdentityReader /
    # ApplePortalSigningService 都用 pathExtension == "appex"）。只认 .app 会静默漏掉
    # 全部扩展 —— 守卫全绿但扩展清理根本没生效，是「绿着坏掉」的典型。
    check('container.hasSuffix(".app") || container.hasSuffix(".appex")' in profile_reader,
          "R08: extensions are .appex — matching only .app silently disables extension cleanup")
    cleaner_source = load("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift")
    check("skipped-no-managed-bundle-ids" in cleaner_source,
          "R08: an empty keep-map must delete nothing")
    sweep_body = section(
        cleaner_source,
        "private static func removeProfiles(",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )
    sweep_clean = squash(strip_comments(sweep_body))
    # 删除的**唯一**入口是局部函数 `removeProfile`（避免两条路径各写一遍 do/catch ——
    # 那种重复迟早漂移成「修了一条、漏了另一条」）。两条路径都必须先取得「凭什么可以删」：
    #   路径 1：keep-map 命中 ⇒ 知道该留哪一份；
    #   路径 2：设备端核验通过 ⇒ 见 R11。
    # 2026-09-17 重构成「先本地筛候选、再统一核验」之后，原「lookup 必须在 remove 之前」的
    # **行序**断言不再成立（`removeProfile` 被抽成局部函数、定义在循环之前），改成守这个形状。
    check("if let keepingUUID = keepingByBundleID[loweredBundleID]" in sweep_clean,
          "R08: a profile may only be deleted after its managed bundle-id lookup succeeded")
    coordinator_source = load("Seal/Core/Signing/SigningCoordinator.swift")
    check("SignedArtifactProfileReader.embeddedProfiles(in: signedData)" in coordinator_source,
          "R08: post-install cleanup must use the whole embedded profile set")
    maintenance_source = load("Seal/Core/Maintenance/AppMaintenanceJob.swift")
    check("profileSweeper" in maintenance_source and "profileKeepMap" in maintenance_source,
          "R08: idle maintenance must sweep stale device profiles")
    check("guard let uuid = record.provisioningProfileUUID" in maintenance_source,
          "R08: records without a profile UUID must be skipped, never guessed")
    # 自替换结算清理（R11 里要用）：它是**唯一**能回收 Seal 自己那批 Team 变体的路径，
    # 而它的保留集合只有 Seal 一个条目 ⇒ 其它 App 全靠宽松受保护集合兜住。
    registrar_source = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    # 扩展记录是「乐观值」：applySigningResult 在签名阶段就写它，不等安装校验。
    # 签名成功但安装失败时，扩展记录指向一份设备上不存在的 profile ——
    # 拿它当保留集合会删掉真正在用的那一份，扩展当场失效。
    check("guard record.signedArtifactStatus == .installed else { continue }" in maintenance_source,
          "R08: extension profile ids are optimistic — only trust them after a verified install")
    # R08: 清理链路的两个「静默失效」入口（2026-09-17 真机取证）。
    #
    # 真机日志：`描述文件清理：扫描 0，匹配 0，删除 0，中断于 dump，首个错误：NoDevice`。
    # 15 秒正好是 `MuxerConstants.deviceFetchTimeoutMs`，说明 `Provision.dumpProfiles`
    # 内部轮询超时后**一次都没重试**就整轮放弃。而两个触发点的时机都**不保证设备已连上**：
    # 安装后清理紧随安装（RSD 连接可能正在重建），维护期清理在 App 启动时
    #（LocalDevVPN 隧道可能还没起来）。同一账号的历史日志里清理是有成功记录的
    #（`删除 1` / `删除 3`）—— 所以问题不是「清理不可用」，而是「撞上瞬时不可达就白丢一次
    # 机会」，而下一次机会要等到下次安装或下次启动，profile 在此期间继续累积。
    check("private static let dumpAttemptLimit = 3" in cleaner_source,
          "R08: a transient NoDevice must not throw away the whole cleanup round")
    # 重试必须真的「先重置 provider 再等一等」：provider 可能缓存着一条已经断开的 RSD 连接，
    # 不重置的话三次重试全走同一条死路，等于没重试（函数还在、循环还在，约束已经失效）。
    dump_body = squash(strip_comments(section(
        cleaner_source,
        "private static func dumpProfiles(",
        "private static func removeProfiles("
    )))
    check("for attempt in 1...dumpAttemptLimit" in dump_body
          and "Provision.resetProvider()" in dump_body
          and "Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)" in dump_body,
          "R08: retrying the dump without resetting the cached provider retries the same dead link")
    # 调用点必须走这个带重试的包装。直接调 `Provision.dumpProfiles` 会让重试形同虚设。
    check("try await dumpProfiles(docsPath: workingDir.path)" in sweep_clean
          and "Provision.dumpProfiles" not in sweep_clean,
          "R08: the sweep must go through the retrying dump wrapper")
    # 试了几次必须进摘要 —— 否则下次真机还是「扫描 0，匹配 0，删除 0」，
    # 看不出是设备没连上还是清理逻辑本身坏了。
    check("summary.dumpAttempts = dump.attempts" in cleaner_source,
          "R08: the retry count is the only evidence that the device was unreachable")
    # 源码断言只能证明字段被赋值，证明不了它**真的出现在日志里** —— 那是单测的活。
    # 同时断言「单测文件里的关键断言确实存在」，防止测试被删空后守卫仍然全绿。
    profile_cleaner_tests = load("SealTests/Installation/DeviceProfileCleanerTests.swift")
    check("dumpAttempts: 3" in profile_cleaner_tests
          and 'contains("，dump 尝试 3 次")' in profile_cleaner_tests
          and "func retriedDumpIsReported()" in profile_cleaner_tests,
          "R08: the retry count must stay covered by a real unit test")
    # R08: 「维护为什么没跑」必须可归因（同一次真机取证）。
    #
    # `AppMaintenanceJob` 第 4 步是**唯一覆盖全部 Seal 管理 App** 的描述文件清理路径，
    # 它那条日志是无条件写的，但真机日志里一次都没出现过（而 `系统` 类别在导出里确实存在，
    # 有 9 条）⇒ 维护要么根本没被调用，要么落在 `.skipped` / `.failed` 上。
    # 而这两个分支原先一个只有 `break`、一个只弹窗，**都不写日志** ⇒ 完全无法归因，
    # profile 堆积看起来像清理逻辑坏了（实际可能只是每轮都撞上前台操作）。
    apps_clean = strip_comments(load("Seal/Features/Apps/AppsViewModel.swift"))
    maintenance_body = section(apps_clean, "func runMaintenanceIfIdle()", "func fullEmail(for account:")
    for case_start, case_end, code in (
        ("case .skipped:", "case .completed(let report):", "SEAL-STORAGE-009"),
        ("case .aborted(let stage, let reason):", "case .failed(let failure):", "SEAL-STORAGE-006"),
        ("case .failed(let failure):", "return outcome", "SEAL-STORAGE-010"),
    ):
        branch = section(maintenance_body, case_start, case_end)
        check("logStore?.append(" in branch and code in branch,
              "R08: every non-.completed maintenance outcome must leave a trace — "
              "otherwise profile buildup is unattributable (" + code + ")")
    # R08: 自替换结算清理也必须落日志（同一次真机取证）。
    #
    # 这是**唯一**会回收 Seal 自己那份堆积的路径 —— Seal 的自更新不走 `installSignedIPA`，
    # 所以「安装后旧描述文件清理」那条根本轮不到它。而它原先只把摘要写进**事务审计**
    #（`finishCleanup` → `store.close(cleanupSummary:)`），事务审计只在 App 内部可读，
    # 排障时能拿到的只有日志 ⇒ 真机上 Seal 堆了 16 份旧 profile，日志里查不出任何原因。
    registrar_clean = squash(strip_comments(load("Seal/Core/Renewal/SelfAppRegistrar.swift")))
    check("try? await logStore?.append(" in registrar_clean
          and "自替换结算清理：" in registrar_clean
          and registrar_clean.index("自替换结算清理：") < registrar_clean.index("finishCleanup(cleanup)"),
          "R08: the self-replacement cleanup must log before closing the transaction — "
          "the transaction audit is not readable during triage")
    # 同上：源码断言证明不了「日志真的落下来了」（`logStore` 没注入 / 消息被脱敏吃掉都会静默失效）。
    handoff_tests = load("SealTests/Renewal/SelfAppPendingHandoffTests.swift")
    check("func confirmedReplacementLogsCleanupSummary()" in handoff_tests
          and 'hasPrefix("自替换结算清理：")' in handoff_tests,
          "R08: the self-replacement cleanup log needs a real unit test")

    # R11: 「换 Apple ID 后旧 Team 后缀」的 profile 回收（2026-09-17）。
    #
    # 起因：用户轮换多个 Apple ID 突破免费账号「3 个自签应用」上限，而 `BundleIDMapper`
    # 强制附加**当前** team 后缀 ⇒ 每换一个账号，每个 App 就多一个 Bundle ID。
    # 从 19 份真机日志量化：**19 个 base × 13 个 team = 39 个 Seal 生成过的 Bundle ID**，
    # 而 keep-map 的 key 只有当前在用的那些 ⇒ 历史后缀的 profile 永远进不了 `matched`，
    # `删除` 恒为 0（真机 `扫描 325，匹配 1，删除 0`）。
    #
    # 这是**设备端破坏性操作**：删错一份，对应 App 立刻无法启动（iOS 启动时校验 profile）。
    # 所以判据必须钉死，而且要注意「绿着坏掉」的写法 —— 形态判据、单测、日志全都还在，
    # 但安全性已经被悄悄抽掉的那种改法。
    reclaim_source = strip_comments(load("Seal/Core/Maintenance/ProfileReclaimPolicy.swift"))
    # ① 形态判据只认 `.seal.` 中缀。其它工具（AltStore / SideStore）用 `<原始>.<teamID>`，
    #    没有这个中缀 ⇒ 天然不会碰别人的 App。
    check('static let sealGeneratedMarker = ".seal."' in reclaim_source,
          "R11: the orphan marker must stay the dotted form — '.seal' would also match xseal.y")
    # ①b keep-map 的命中判断必须**大小写不敏感**。
    #    写成 `keepingByBundleID[lowered] == nil` 这种精确查表时，只要 key 的大小写
    #    与设备端不一致，就会把「正在用的那个」判成可回收 ⇒ 删掉活着的 profile。
    #    调用方目前确实会把 key 归一化成小写，但**这条判断的错法方向是删数据**，
    #    不能靠调用方约定来保证安全 —— 2026-09-17 就是被单测当场证伪的。
    check("keepingByBundleID.keys.contains(where: { normalized($0) == lowered })"
          in reclaim_source,
          "R11: the keep-map membership test must be case-insensitive — a case mismatch "
          "would classify a live profile as reclaimable")
    # ①c **两个集合必须分开**（2026-09-17 真机事故的修法）。
    #
    #    判据是「不在保留集合里 ⇒ 成为候选」，所以「保留集合漏了谁」会直接变成「删掉谁」。
    #    严格集合（`keepingByBundleID`）刻意宁缺勿滥 —— 拿不到可信 UUID 就不进集合；
    #    宽松集合（`protectedBundleIDs`）宁滥勿缺 —— 记录里出现过就进。
    #    一旦有人把后者合并进前者（或干脆删掉后者），**已装 App 的扩展 profile 会被删掉**：
    #    扩展不是独立安装的 App，`isAppInstalled` 对它恒为 `false`，
    #    设备端核验这道安全网对扩展完全是瞎的。
    #    真机日志（构建 95）：`候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列。
    check("protectedBundleIDs: Set<String>" in reclaim_source
          and "protectedBundleIDs.contains(where: { normalized($0) == lowered })"
          in reclaim_source,
          "R11: the candidate rule needs a separate protected set — without it, extension "
          "profiles of installed apps are reclaimed (device probing can't see extensions)")
    # ①d 宽松集合的构造**不得**受 `signedArtifactStatus` 门槛影响。
    #    严格 keep-map 要求 `.installed` 才收扩展（那个取舍是对的），但那个标记一旦陈旧，
    #    扩展 ID 就掉出保护范围 ⇒ 被当孤儿删掉。
    protected_parts = reclaim_source.split("static func protectedBundleIDs(records:", 1)
    protected_body = squash(protected_parts[1]) if len(protected_parts) > 1 else ""
    check(protected_body != ""
          and "signedArtifactStatus" not in protected_body
          and "record.extensions" in protected_body,
          "R11: the protected set must collect extensions unconditionally — gating it on "
          "signedArtifactStatus is exactly how live extension profiles got deleted")
    # ①e 两个集合必须真的**贯通到设备层**，不能只在判据里存在。
    #    判据再对，调用方传个空集合也等于没有保护。
    for name, source in (("idle maintenance", maintenance_source),
                         ("post-install cleanup", coordinator_source),
                         ("self-replacement settle", registrar_source)):
        check("ProfileReclaimPolicy.protectedBundleIDs(records:" in squash(strip_comments(source)),
              f"R11: {name} must pass a record-derived protected set")
    # ①f 受保护集合为空时**整轮不回收**（fail closed）。
    #    记录读不到 ⇒ 保护范围未知 ⇒ 宁可这一轮不回收，也不能按「现有信息尽量删」办。
    check("let reclaimEnabled = reclaimSealOrphans && protectedBundleIDs.isEmpty == false"
          in squash(strip_comments(cleaner_source)),
          "R11: an empty protected set must disable reclaim entirely (fail closed)")
    # ② 决策函数是**唯一**的安全边界，三个分支缺一不可。
    #    `.notInstalled` 必须**问过阳性对照**才可能返回 `.reclaim` —— 这是最容易被
    #    「简化」掉的一句：直接 `return .reclaim` 之后，形态判据与单测全都还在，
    #    功能看起来完全正常，但「隧道抖动 ⇒ 全部答成未安装 ⇒ 全删」的路径就敞开了。
    decision_parts = reclaim_source.split("static func decision(", 1)
    decision_body = squash(decision_parts[1]) if len(decision_parts) > 1 else ""
    check("case .unavailable: return .abortPass" in decision_body,
          "R11: a failed probe must abort the pass — it must never be read as 'not installed'")
    check("case .installed: return .keepInstalled" in decision_body,
          "R11: an installed app's profile must always be kept")
    check("return positiveControlPassed ? .reclaim : .abortPass" in decision_body,
          "R11: .reclaim must require a passed positive control")
    # ③ 设备层必须用会**抛错**的 `isAppInstalled`，而不是 `lookupApp`：
    #    `Minimuxer.lookupApp` 返回 `String?`，把「没装」与「查询失败」**折叠成同一个 nil**
    #    （`Minimuxer.swift:254` 里 `try?` 吞掉错误、`Device.getFirstDevice()` 失败也返回 nil）。
    #    拿它当判据 ⇒ 隧道一抖动，所有候选都被读成「没装」⇒ 删掉正在用的 profile。
    reclaim_body = squash(strip_comments(section(
        cleaner_source,
        "private static func probeInstalled(",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )))
    check("try Minimuxer.isAppInstalled(bundleId: bundleID)" in reclaim_body,
          "R11: the reclaim path must use the throwing isAppInstalled")
    check("Minimuxer.lookupApp(" not in reclaim_body,
          "R11: lookupApp's nil means both 'not installed' and 'query failed' — "
          "reading it as 'not installed' deletes profiles of installed apps")
    # ④ 阳性对照必须**真的是设备查询**，且必须在删任何一份之前跑完。
    #    把 `== .installed` 改成 `= true` 能让对照永远通过 —— 通道不可信时照样全删。
    # ⚠️ **2026-09-20 跟进**：阳性对照改成「**带耗时的**探测 ＋ 再问一次同一个 ID」（R58 ✓）
    # ⇒ 这里的两处文本要**一起**更新 ✗ —— 否则断言与锚点都会失配 ✓
    #（**教训**：改任何一行之前，grep 守卫时不能只搜注释文案，**代码行本身就是锚点** ✗）。
    check("let firstControlProbe = await probeInstalledWithDuration(bundleID: controlBundleID)"
          in reclaim_body
          and "let positiveControlPassed = firstControlProbe.probe == .installed" in reclaim_body,
          "R11: the positive control must be an actual probe of a definitely-installed app")
    control_at = reclaim_body.find("probeInstalledWithDuration(bundleID: controlBundleID)")
    candidate_at = reclaim_body.find("ProfileReclaimPolicy.decision(")
    check(control_at != -1 and candidate_at != -1 and control_at < candidate_at,
          "R11: the positive control must run before any candidate is probed or deleted")
    # ⑤ `.abortPass` 必须**中止整轮**，而不是只跳过当前这一条。
    #    只跳过的话，后面的候选会继续被一条已经不可信的通道「判定」，等于没有保护。
    #
    #    2026-09-17 改成「先问完所有候选、再决定」之后，中止的形状变成
    #    「循环外 `guard … else { 记录原因; return }`」—— 语义比原来更强：
    #    **连已经问过的那几条也不删**（半路删掉一部分再中止，等于用一条已判定不可信的
    #    通道做了一半不可逆的事）。所以断言也跟着改成这个形状。
    check("case .abortPass:" in reclaim_body
          and "guard reclaimAbortReason == nil else { summary.reclaimAborted = "
              "reclaimAbortReason return summary }" in reclaim_body
          and reclaim_body.count("summary.reclaimAborted =") >= 2,
          "R11: .abortPass must record why and stop the whole pass")
    # ⑥ 中止必须进日志，且不能借用 `中断于`（那会让人以为整轮清理白跑了，
    #    而路径 1 的成绩其实仍然有效）。
    check("if let reclaimAborted" in cleaner_source
          and '"，回收中止：' in cleaner_source,
          "R11: an aborted reclaim must be visible — otherwise '回收 0' is misread "
          "as 'no candidate matched the marker'")
    # ⑦ 两个调用点都必须**显式**开启回收；默认值必须仍是 false（默认删设备数据是不可接受的）。
    check(cleaner_source.count("reclaimSealOrphans: Bool = false") == 2,
          "R11: orphan reclaim must stay opt-in at every entry point")
    check(squash(strip_comments(maintenance_source)).count("reclaimSealOrphans: true") == 1,
          "R11: idle maintenance must opt in explicitly")
    check(squash(strip_comments(coordinator_source)).count("reclaimSealOrphans: true") == 1,
          "R11: post-install cleanup must opt in explicitly")
    # ⑧ 源码断言只能证明「逻辑在」，证明不了每个分支**真的被测过** —— 那是单测的活。
    reclaim_tests = load("SealTests/Maintenance/ProfileReclaimPolicyTests.swift")
    check("func notInstalledWithHealthyChannelIsTheOnlyReclaimPath()" in reclaim_tests
          and "func unavailableNeverReclaims()" in reclaim_tests
          and "func failedPositiveControlAbortsTheWholePass()" in reclaim_tests
          and "func noCandidateIsEverReclaimedWhenPositiveControlFails()" in reclaim_tests,
          "R11: every branch of the reclaim decision needs a real unit test")
    # 大小写不敏感那条必须有**用混合大小写 key** 的单测。把 key 改成小写就能让
    # 上面那条源码断言（断言实现里写了 `lowercased()` 比较）继续绿着 ——
    # 所以这里要单独钉住「测试用的确实是混合大小写的 key」。
    case_test = section(
        reclaim_tests,
        "func currentBundleIdentifierIsNeverACandidate()",
        "func matchingIsCaseInsensitive()"
    )
    check('"com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"' in case_test,
          "R11: the keep-map case-insensitivity needs a real unit test with a mixed-case key")
    check("func reclaimAbortIsVisibleWithoutClaimingTheWholeRunFailed()" in profile_cleaner_tests,
          "R11: the reclaim summary needs a real unit test")
    # 「开关漏传」是这条功能最典型的静默失效：`reclaimSealOrphans` 是个 Bool，
    # 漏传时编译不失败、别的单测也不红，只是旧 Team 的 profile 永远清不掉 ——
    # 而这正是用户报的那个现象。所以要有一条专门断言「调用方真的开了」的单测。
    maintenance_tests = load("SealTests/Maintenance/AppMaintenanceJobTests.swift")
    check("func maintenanceSweepEnablesSealOrphanReclaim()" in maintenance_tests
          and "receivedReclaimFlags" in maintenance_tests,
          "R11: the opt-in flag must stay covered by a real unit test")
    # 受保护集合必须有单测，而且必须覆盖**两个方向**：
    #   ① 扩展 ID 在集合里 ⇒ 不是候选（真机事故的直接修法）；
    #   ② 同一个 ID **不**在集合里 ⇒ 确实是候选（否则 ① 可能只是因为「形态没匹配上」而通过，
    #      也就是绿着坏掉 —— 判据被删空时测试照样全绿）。
    check("func protectedExtensionIsNeverACandidate()" in reclaim_tests
          and "func extensionIsCollectedEvenWhenRecordIsNotMarkedInstalled()" in reclaim_tests,
          "R11: the protected set needs real unit tests (extension protected / still a "
          "candidate without protection)")
    protected_test_body = section(
        reclaim_tests,
        "func protectedExtensionIsNeverACandidate()",
        "func protectedSetMatchingIsCaseInsensitive()"
    )
    check(protected_test_body.count("protectedBundleIDs: [extensionID]") >= 1
          and protected_test_body.count("protectedBundleIDs: []") >= 1,
          "R11: the protected-set test must assert both directions — with and without "
          "protection — or it passes for the wrong reason")
    # 构造侧：不得出现 `signedArtifactStatus` 门槛（源码断言已守实现，这里守**单测真的钉住了它**）。
    check("func extensionIsCollectedWhenStatusIsNil()" in reclaim_tests,
          "R11: the protected set must be tested with a nil install status")
    # 三个调用点各自要有单测证明「真的传下去了」。
    check("func protectedSetCoversExtensionsEvenWhenRecordIsNotMarkedInstalled()" in maintenance_tests,
          "R11: idle maintenance must prove it passes the protected set")
    settle_tests = load("SealTests/Renewal/SelfAppPendingHandoffTests.swift")
    check("func settleCleanupCarriesProtectedBundleIDsForOtherAppsExtensions()" in settle_tests,
          "R11: self-replacement settle cleanup must prove it passes the protected set — "
          "its keep-map only holds Seal itself, so extensions have no other protection")

    # R12: 批量续签的逐项成功日志 + 轮询日志降噪（2026-09-17 真机日志驱动）。
    #
    # ① 批量续签原来**一条逐项结果都不写** —— 「续签并安装成功」只在**单签**的
    #    `AppsViewModel.signAndInstall` 里写，而批量走的是 `RenewalCoordinator` →
    #    `SigningCoordinator.signAndInstall`。后果是真机上「某个 App 到底成没成」
    #    只能靠推断：2026-09-17 用户续签 LiveContainer 后界面停在「安装中」，
    #    取消后看到 App 像是重装了，却无法确认装没装上、描述文件是不是新申请的。
    #    排障入口只有导出的日志，而当时日志里**一个字都没有**。
    renewal_source = strip_comments(load("Seal/Core/Renewal/RenewalCoordinator.swift"))
    check('"SEAL-RENEW-020"' in renewal_source
          and "Self.describeProfile(updated)" in renewal_source,
          "R12: the batch renewal path must log a per-item success line")
    # 这条日志必须带上**描述文件身份**（UUID + 创建/到期时间）。
    # 只写「成功」两个字回答不了那个真正的问题：「换的是新申请的那份，还是旧的那份」。
    # 断言的是 `describeProfile` 的**函数体**而不是整个文件 —— 后者在函数被改成
    # `return ""` 时照样通过（定义还在，只是不再产出任何字段）。
    # 用 `section()` 而不是 `split(...)[1]`：后者会取到**文件尾**，
    # 于是「函数体里有没有这个字段」变成了「文件后面还有没有这个字段」。
    profile_body = squash(section(
        renewal_source,
        "static func describeProfile(",
        "private func emitFailure("
    ))
    check(profile_body != ""
          and "provisioningProfileUUID" in profile_body
          and "provisioningProfileCreationDate" in profile_body
          and "provisioningProfileExpirationDate" in profile_body
          and "ISO8601DateFormatter" in profile_body,
          "R12: the per-item success line must carry the profile identity (UUID + creation "
          "+ expiry), ISO8601-formatted so it can be compared with Apple's portal")
    # 实参漏传不会编译失败，只会让这条日志重新变成空白 —— 与 `reclaimSealOrphans`
    # 属同一类静默失效（见 R11 ⑦）。必须限定在 `RenewalCoordinator` 的构造块里查：
    # `logStore: logStore` 在 `AppContainer` 里出现 8 次，全局匹配会让
    # 「只删掉这一处」的变异检不出来。
    renewal_init = section(
        load("Seal/Application/AppContainer.swift"),
        "let renewalCoordinator = RenewalCoordinator(",
        "let appRecordRecovery"
    )
    check("logStore: logStore" in squash(renewal_init),
          "R12: the batch coordinator must be given a log store — a missing argument "
          "compiles fine and silently blanks the per-item log again")
    # 源码断言只能证明「字段被写出来了」，证明不了格式化真的产出了 UUID 与时间
    # （可能被脱敏吃掉、字段可能是 nil）。所以那条日志里唯一可测的纯函数要有单测，
    # 而且单测必须断言**完整**的 ISO8601 形态 —— 断言 `contains("T")` 这种单字符会
    # 同时匹配 `contains(_: Character)` 与 `contains(_: String)`，宏展开难以预料。
    log_tests = load("SealTests/Renewal/RenewalCoordinatorLogTests.swift")
    check("func profileIdentityIncludesUUIDAndBothDates()" in log_tests
          and "func missingDatesAreSpelledOutRatherThanOmitted()" in log_tests,
          "R12: the per-item success line needs a real unit test for its profile identity")
    check('"2026-09-17T05:28:58Z"' in log_tests,
          "R12: the ISO8601 unit test must assert the full form, not a single character")

    # ② 轮询日志必须保持删除状态（2026-09-17 真机日志量化）。
    #
    # `restorePendingBatchResultIfNeeded` 由 `load()` 每 ~9 秒调用一次，而
    # 「没有待恢复的数据」与「当前有会话在进行」都是**正常路径**。
    # 那两条是 09-16「93 秒空白」排查时加的临时脚手架，实测占了全部日志的
    # **30%（73/244 行）**，把真实信号挤出了只保留 1000 条的环形缓冲。
    view_model_code = strip_comments(load("Seal/Features/Apps/AppsViewModel.swift"))
    check("[BatchDebug]" not in view_model_code,
          "R12: the temporary [BatchDebug] scaffolding must stay removed — it was 30% of "
          "the log ring buffer and pushed real signal out")
    # 但「**确实有待恢复的数据、却被跳过**」是异常，仍要留痕 —— 那才是「结果丢了」的
    # 征兆。两条一起断言：正常路径静默（裸 `return`）＋ 异常路径有条件日志。
    # 2026-09-17 又加了第二个条件 `hasRestoredPendingBatchResult == false`：
    # 「已经恢复进会话」不是跳过（载荷要等抽屉关闭才清），否则每次 `load()` 轮询
    # 都会重复报同一条警告 —— 真机实测就是 1 条真警报 + 若干条重复。
    restore_body = squash(section(
        view_model_code,
        "private func restorePendingBatchResultIfNeeded()",
        "private func clearPendingBatchResult()"
    ))
    check(restore_body != ""
          and "guard let payload = pendingPayload else { return }" in restore_body
          and "if pendingPayload != nil, hasRestoredPendingBatchResult == false {"
              in restore_body,
          "R12: the restore poll path must stay silent on the normal path — only "
          "'pending data exists and the restore was genuinely skipped' deserves a log line")
    check("hasRestoredPendingBatchResult = true" in restore_body
          and "hasRestoredPendingBatchResult = false" in view_model_code,
          "R12: the already-restored flag must be set on restore and cleared on dismiss, "
          "otherwise the skip warning either repeats or goes missing")

    # R13: 「Apple 要求双重认证」必须走专门的分类与提示（2026-09-17 真机取证，构建 95）。
    #
    # 加这条之前，Apple 返回 `Code：3018 / requires signing in with two-factor
    # authentication` 时界面给的是「Apple ID 验证失败 / 重试；如持续失败请核对
    # Apple ID 与密码」—— 而**密码完全没问题**：Apple 已经接受了密码，只是要求走第二步。
    # 用户会在一个正确的密码上反复试，甚至跑去重置密码。
    # 这类错法不崩、不编译失败，只在真机上把用户引错方向 ⇒ 判据与文案抽成纯函数
    # （`AppleAuthenticationDiagnosis`）+ 单测 + 守卫。
    diagnosis_source = strip_comments(
        load("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift")
    )
    check("static let twoFactorRequiredCode = 3018" in diagnosis_source,
          "R13: the two-factor error code must stay 3018 — it is the only stable "
          "identifier Apple gives (the description is localised and gets reworded)")
    # 判据必须**先认错误码**：描述会随 Apple 的措辞与语言变，错误码不会。
    # 描述只做兜底（万一 Apple 换码），不能成为唯一依据。
    check("if nsError.code == twoFactorRequiredCode { return true }" in diagnosis_source,
          "R13: the code check must come first and stand on its own — matching only on "
          "the description breaks the moment Apple rewords or localises it")
    # 这是整条功能的**全部意义**：提示里不能把用户引向一个正确的密码。
    # 源码断言只能证明「有这么个工厂」，证明不了它的文案 ⇒ 真正的护栏是单测（见下），
    # 这里额外钉住那个工厂没有去复用泛化文案。
    check("核对 Apple ID 与密码" not in diagnosis_source,
          "R13: the two-factor prompt must not reuse the generic 'check your Apple ID "
          "and password' advice — the password is exactly what is NOT the problem")
    check('code: "SEAL-AUTH-101a"' in diagnosis_source,
          "R13: the two-factor failure needs its own code so it is greppable in logs")

    # 三个映射入口：`make`（新账号登录）、`validate`（已存 session 重新验证）、
    # `failure(from:)`（Anisette 前置失败后的通用兜底）。
    # 「只在其中一条链路上加」是这类修复最容易犯的错，而且不崩、不编译失败。
    client_source = strip_comments(load("Seal/Infrastructure/Accounts/AppleAccountClient.swift"))
    check(client_source.count("AppleAuthenticationDiagnosis.isTwoFactorRequired(error)") == 3,
          "R13: every error-mapping entry point must route the two-factor error — "
          "covering only one path silently re-introduces the wrong advice elsewhere")
    check(client_source.count("AppleAuthenticationDiagnosis.twoFactorFailure(for: error)") == 3,
          "R13: every entry point must use the shared factory, not a hand-written prompt — "
          "two copies drift and only one of them gets fixed")

    # 顺序也是设计：双重认证是最具体的诊断（Apple 已接受密码），必须排在限流/网络之前。
    # 两个入口顺序不一致时，同一个错误在两条路径上会给出不同提示。
    # 断言的是**每个函数体内的相对位置**，不是「文件里有没有这两个字符串」。
    for entry_name, start_marker, end_marker in (
        ("AppleAuthenticationFailure.make",
         "static func make(stage: AppleAuthenticationStage, error: Error) -> ImportFailure {",
         "case .teamLookup:"),
        ("AppleAccountClient.validate",
         "func validate(",
         "nonisolated static func mask(_ appleID: String) -> String {"),
        ("AppleAccountClient.failure(from:)",
         "private nonisolated static func failure(from error: Error) -> ImportFailure {",
         "private struct AuthObjects"),
    ):
        entry_body = section(client_source, start_marker, end_marker)
        two_factor_at = entry_body.find("isTwoFactorRequired(error)")
        rate_limit_at = entry_body.find("isRateLimited(error)")
        check(two_factor_at != -1 and rate_limit_at != -1 and two_factor_at < rate_limit_at,
              f"R13: {entry_name} must check two-factor before rate-limit/network — "
              "the more specific diagnosis has to win")

    # 新错误码**不能**落进「凭据失效」那一组：那会把账号标成需要重新验证，
    # 而这里账号和密码都是好的，只是第二步没走完。
    policy_source = strip_comments(
        load("Seal/Core/Accounts/AppleServiceFailurePolicy.swift")
    )
    check("SEAL-AUTH-101a" not in policy_source,
          "R13: the two-factor failure must not be classified as credentials-rejected — "
          "the password is fine, marking the account as needing re-verification is wrong")

    # 源码断言只能守「形状」，守不住「文案真的没把用户引错」。所以那几条必须由单测承担，
    # 守卫反过来钉住「这些单测确实存在」—— 防止测试被删空后仍然全绿。
    diagnosis_tests = load("SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift")
    check("func code3018IsRecognisedAsTwoFactorRequired()" in diagnosis_tests
          and "func descriptionMarkerIsTheFallbackWhenTheCodeDiffers()" in diagnosis_tests,
          "R13: the two-factor classification needs a real unit test")
    check("func twoFactorFailureNeverTellsTheUserToCheckThePassword()" in diagnosis_tests,
          "R13: the 'never send the user to check the password' rule is the whole point "
          "of this fix — it must be pinned by a unit test, not just by prose")
    check("func makeRoutes3018ToTheTwoFactorFailure()" in diagnosis_tests,
          "R13: testing the classifier alone would not catch a removed branch in `make` — "
          "the routing itself needs an end-to-end assertion")
    check("func twoFactorFailureIsNotClassifiedAsCredentialsRejected()" in diagnosis_tests,
          "R13: the 'not credentials-rejected' boundary needs a unit test")

    # R14: 两条安装路径共用同一个心跳 + 扩展随父 App 保留（2026-09-17 真机，构建 97）。
    #
    # ① 普通安装卡了 **9 分多钟**，日志里从「开始安装」到用户导出日志**一行都没有** ——
    #    因为心跳当时只加在**自替换**那条路径上。同一条规则只落在两条链路中的一条，
    #    是本仓库反复踩到的形态（`InstallStageTimeline` 那次也是）。
    #    判据：心跳必须是一个共用实现，两条路径都走它。
    install_source = strip_comments(
        load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    )
    check("private func beginInstallHeartbeat(" in install_source,
          "R14: the install heartbeat must be ONE shared helper — two copies drift, "
          "and only one of them gets fixed")
    check(install_source.count("beginInstallHeartbeat(") == 3,
          "R14: BOTH install paths must use the shared heartbeat "
          "(1 definition + 2 call sites). A normal install that hangs logs nothing without it")
    check('let heartbeat = beginInstallHeartbeat("安装", budget: mergedTimeout)' in install_source
          and 'beginInstallHeartbeat("自替换安装", budget: budget)' in install_source,
          "R14: each path needs its own label, and the normal path must start the "
          "heartbeat before it blocks on the synchronous FFI")
    check("selfReplacementHeartbeatNanoseconds" not in install_source,
          "R14: the old inline heartbeat must stay gone — a second copy is exactly how "
          "the two paths drifted apart")

    # ② 扩展随父 App 保留。扩展不是独立安装的 App，`isAppInstalled` 对它恒为 false ⇒
    #    设备端核验对扩展完全瞎。此前扩展**只**靠 `protectedBundleIDs`（记录里出现过的 ID）
    #    保护，于是「主 App 不在记录里」时扩展失去全部保护 —— 主 App 却被核验救下。
    #    真机：`候选 4，回收 3，已装保留 1`，示例里主 App 与它的三个扩展并列。
    reclaim_source = strip_comments(
        load("Seal/Core/Maintenance/ProfileReclaimPolicy.swift")
    )
    check("static func isExtensionBundleID(" in reclaim_source,
          "R14: extensions of an installed app must be recognised via the parent prefix")
    check('if lowered.hasPrefix(parent + ".") { return true }' in reclaim_source,
          "R14: the parent prefix must end on a DOT boundary — without it sibling "
          "variants would 'protect' each other and reclaim would stop working entirely")
    cleaner_source = strip_comments(
        load("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift")
    )
    check("installedCandidates.insert(ProfileReclaimPolicy.normalized(entry.bundleID))"
          in cleaner_source,
          "R14: the 'installed parent' set must be built from THIS pass's candidates — "
          "a general installed-app list would let an ordinary app's ID prefix-match "
          "every orphan and silently disable reclaim")
    # 「先问完所有候选、再决定」是这条规则的**结构前提**：扩展要等父 App 的探测结果。
    # 顺序断言用相对位置，不是「文件里有没有这几个字符串」。
    reclaim_pass = section(
        cleaner_source,
        "var probes: [(uuid: String, bundleID: String, probe: ProfileReclaimPolicy.InstallProbe)] = []",
        "extension DeviceProfileCleaner: StaleProfileSweeping"
    )
    probe_at = reclaim_pass.find("probes.append(")
    abort_at = reclaim_pass.find("guard reclaimAbortReason == nil else {")
    installed_at = reclaim_pass.find("var installedCandidates: Set<String> = []")
    remove_at = reclaim_pass.find("removeProfile(entry.uuid)")
    check(probe_at != -1 and abort_at != -1 and installed_at != -1 and remove_at != -1
          and probe_at < abort_at < installed_at < remove_at,
          "R14: the reclaim pass must probe EVERY candidate before deleting any — "
          "the extension rule needs the complete 'which candidates are installed' set, "
          "and an abort must land before anything irreversible")
    check("ofAnyOf: installedCandidates" in reclaim_pass,
          "R14: the pass must consult the parent rule with the real candidate set — "
          "passing an empty set leaves the call in place while protecting nothing")
    # 受保护集合的规模是「候选为什么这么多」的第一归因：记录读不到时它会是 0/极小。
    # 2026-09-17 的日志里只有 `候选 4，回收 3`，看不出那一刻保护范围到底有多大。
    check('，受保护 \\(protectedCount)' in cleaner_source,
          "R14: the protected-set size must be in the log — without it, 'many candidates' "
          "cannot be told apart from 'the records were not read'")

    # ③ 安装超时的**文案必须与实现一致**（2026-09-17 发现）。
    #    超时是原样抛出、**不重试**的（R05：底下那次安装很可能还在跑），
    #    而文案当时写着「系统已自动重试」—— 用户会继续等一个并不存在的重试。
    #    「超过 10 分钟」也是错的：等待上限按包大小算（小包约 804 秒、大包可到 2400 秒）。
    check("系统已自动重试" not in install_source,
          "R14: the timeout message must not claim a retry — the timeout path re-throws "
          "without retrying, so the claim makes the user wait for nothing")
    check("也不会自动重试" in install_source,
          "R14: the timeout message must say the call is neither cancelled nor retried — "
          "otherwise the user cannot tell whether the app may still get installed")
    # 用 `section_or_empty`：变异锚点 `if Self.isTimeoutInstallError(error) {` → `if false {`
    # 会**删掉这个标记**，用 `section()` 会让整轮守卫崩掉而不是报一条失败。
    timeout_branch = squash(section_or_empty(
        install_source,
        "if Self.isTimeoutInstallError(error) {",
        "if Self.isSelfReplacementBusyError(error) {"
    ))
    check("throw error" in timeout_branch,
          "R14: a timed-out install must be re-thrown, not retried (R05) — the underlying "
          "FFI may still be running, and a retry would put a second installd command on "
          "the same bundle id")

    # 两个新的归因计数必须有单测：源码断言证明不了「值真的被算出来了」。
    extension_tests = load("SealTests/Maintenance/ProfileReclaimPolicyTests.swift")
    check("func extensionOfAnInstalledCandidateIsRecognised()" in extension_tests
          and "func prefixMustEndOnADotBoundary()" in extension_tests
          and "func extensionOfANonInstalledParentIsNotProtected()" in extension_tests,
          "R14: the parent-prefix rule needs real unit tests — source assertions cannot "
          "prove the boundary behaviour")
    cleaner_tests = load("SealTests/Installation/DeviceProfileCleanerTests.swift")
    check("func protectedSetSizeIsReported()" in cleaner_tests
          and "func extensionKeptCountIsReportedSeparately()" in cleaner_tests,
          "R14: the new attribution counters need real unit tests")

    # R15: 脱敏不得吃掉 ISO 时间戳（2026-09-17 从真机日志发现）。
    #
    # 手机号模式的字符类里有数字与连字符，于是 `2026-09-17T06:38:18Z` 被整段当成号码，
    # `AppleAccountClient.mask` 对 6 / 8 位数字给出 `20****09` / `202****917`
    # ⇒ **日志里所有 ISO 时间戳的年月都没了**。日志是唯一的排障通道，时间戳被毁代价很大：
    # 证书的 notBefore / notAfter 相差一年，脱敏后几乎一模一样（只差 1 秒），
    # 看上去像「到期早于生效」，排查时差点被当成 bug 报上去。
    redactor_source = strip_comments(load("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift"))
    check('(?![A-Za-z0-9\\-:])' in redactor_source,
          "R15: the phone pattern must not stop inside a date — without excluding `-` and "
          "`:` from the trailing lookahead it matches `2026-09-17 14` and mangles timestamps")
    check("static func looksLikeDateFragment(" in redactor_source
          and '^(?:19|20)\\d{2}-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\\d|3[01]))?$' in redactor_source,
          "R15: a date-shaped match must be left alone — tightened to a real year + month so "
          "it cannot become a hole for phone numbers (1234-5678 / 2026-13 are not dates)")
    check("guard looksLikeDateFragment(match) == false else { return match }" in redactor_source,
          "R15: the phone redactor must actually consult the date guard")
    # 单测必须钉住「时间戳原样保留」与「真手机号照旧脱敏」两侧 ——
    # 只钉一侧时，把日期识别器放宽到吃掉手机号也不会红。
    redactor_tests = load("SealTests/Diagnostics/LogPrivacyRedactorTests.swift")
    check("func keepsISOTimestampsIntact()" in redactor_tests
          and "func certificateValidityPeriodStaysReadable()" in redactor_tests,
          "R15: keeping ISO timestamps intact needs a real unit test")
    check("func stillRedactsRealPhoneNumberShapes()" in redactor_tests
          and "func dateShapeDetectorRejectsPhoneLikeNumbers()" in redactor_tests,
          "R15: relaxing the date rule must not leak phone numbers — both sides need a test")

    # R16: 缓存设备会话的活性探测（2026-09-17 加，**只取证不改变行为**）。
    #
    # 安装复用 `connect_to_rsd_services` 的缓存隧道会话，而这条链路上**没有任何一处**
    # 验证会话还活着：`start()` 的 900 秒缓存只查 `Minimuxer.ready()` 标志位，
    # `installSignedIPA` 的唯一漏斗 `if !isReady() { start() }` 同样只查标志位
    # ⇒ 标志为真时连 `start()` 都不调。而本仓注释**三处**都记着「死连接」这个失败模式。
    # 死会话上跑同步 FFI 会阻塞到 OS 放弃 —— 真机实测普通安装静默 9 分多钟。
    check("private func probeCachedSessionIfStale() async {" in install_source,
          "R16: the cached RSD session needs a liveness probe before an install")
    check("if attempt == 1 { await probeCachedSessionIfStale() }" in install_source,
          "R16: the probe must run before the FIRST attempt — that is the attempt that "
          "reuses whatever cached session happens to exist")
    # ⚠️ 探测**自己也不能卡住**：它要验证的正是「死连接会阻塞」。
    check("private static let cachedSessionProbeTimeoutSeconds: Double = 5" in install_source,
          "R16: the probe must be bounded (5s) — an unbounded probe on a dead session "
          "reproduces the very hang it is meant to diagnose")
    check("offThread(seconds: Self.cachedSessionProbeTimeoutSeconds)" in install_source,
          "R16: the probe must go through the bounded wrapper, not call the FFI directly")
    # ⚠️ 这一步**只记日志**：真正的补救是重建连接，而它会拆掉可能仍在跑的上一笔安装
    # 连接（R05）。没有直接证据之前不许动行为 —— 探测就是为了拿到那条证据。
    probe_body = squash(section_or_empty(
        install_source,
        "private func probeCachedSessionIfStale() async {",
        "\n    init(\n        pairingStore: PairingStore,"
    ))
    check(probe_body != ""
          and "Minimuxer.reset()" not in probe_body
          and "resetProvider()" not in probe_body,
          "R16: the probe must stay observation-only — resetting here would tear down a "
          "possibly still-running install (R05) before we even know the session is dead")
    check("fetchUDIDDetailed()" in probe_body,
          "R16: the probe must use a real round-trip that throws — a cached/flag-based "
          "check cannot tell a dead session from a live one")

    # R17: 「批量续签被自己替换中断」不许自相矛盾（2026-09-17 真机，构建 102）。
    #
    # Seal 自己替换自己时，进程**必然**在队列项还是 `running` 的时候被杀 —— 但那一项的
    # 结果其实已经写进持久化载荷了（`SEAL-RENEW-023`，Seal 那一项被显式记成 completed）。
    # 旧实现盲目把 running 降级为 unknown，于是同一个批次给出三份互相矛盾的结论：
    #   日志「上次续签被中断，1 个应用的结果未知，需要重新核验」   ← 假警报
    #   队列文件里留下一个幽灵条目（其实成功的那一项）
    #   结果抽屉同时显示 completed(total: 2, succeeded: 2, failed: 0)
    # ⇒ 先恢复载荷、再结算队列；载荷里已定论的项按结果结算，只有真没结论的才降级。
    payload_source = strip_comments(
        load("Seal/Core/Renewal/PendingBatchResultPayload.swift")
    )
    # 这里自己加载一份（`store` 要到后面 G 段才定义）。
    queue_store_source = strip_comments(
        load("Seal/Infrastructure/Renewal/RefreshQueueStore.swift")
    )
    # 状态↔字符串的映射住在类型自己的文件里（2026-09-17 从 `AppsViewModel` 挪出来：
    # 原先它是 `private extension`，写入侧、读取侧、单测**三个文件**都要用 ⇒ 编译不过）。
    batch_session_source = strip_comments(
        load("Seal/Core/Renewal/BatchRefreshSession.swift")
    )
    # ⚠️ 两个条件都必须落在**新文件**上：`"extension X {"` 是 `"private extension X {"`
    # 的**子串**，只在别处查「有没有 private」是抓不到「被收回成 file 级」这个变异的。
    check("extension BatchRefreshSession.Item.State {" in batch_session_source
          and "private extension BatchRefreshSession.Item.State" not in batch_session_source
          and "BatchRefreshSession.Item.State {" not in view_model_code,
          "R17: the payload mapping must be internal and live with the type — it is used by "
          "the writer, the reader AND the tests; a file-private copy is exactly how this "
          "broke the build once")
    check("static func settledQueueStates(from payload: [String: Any]?)" in payload_source,
          "R17: the pending payload must be mappable to queue states — that mapping is "
          "what lets the queue recovery settle instead of guessing")
    # 只映射「已定论」的两态。把 `running` 也映射上就等于「替那个正在被杀死的项宣布结果」。
    check("case .completed: return .completed" in batch_session_source
          and "case .failed: return .failed" in batch_session_source
          and "case .waiting, .running, .preparingSealUpdate: return nil" in batch_session_source,
          "R17: only settled states may be mapped — mapping `running` would claim a result "
          "for the very item that was killed mid-flight")
    check("if let known = settled[items[index].appID] {" in queue_store_source
          and "items[index].state = known" in queue_store_source,
          "R17: an interrupted item with a known result must be SETTLED, not downgraded")
    check("outcome.settledFromResult > 0" in view_model_code
          and "outcome.downgraded > 0" in view_model_code,
          "R17: the two outcomes must be reported separately — `settledFromResult` is a "
          "normal path (info), `downgraded` deserves the user-facing re-verification warning")
    # ⚠️ **顺序就是这条修复本身**：先恢复载荷、读出已定论的项，再结算队列。
    # 顺序反了的话，队列里那个 running 项会在载荷被读之前就被标成 unknown。
    recovery_body = squash(section_or_empty(
        view_model_code,
        "func recoverInterruptedQueueIfNeeded() async {",
        "private func settledQueueStates(from payload:"
    ))
    restore_at = recovery_body.find("restorePendingBatchResultIfNeeded()")
    settle_at = recovery_body.find("settledQueueStates(from:")
    recover_at = recovery_body.find("recoverInterruptedQueue(settled:")
    check(restore_at != -1 and settle_at != -1 and recover_at != -1
          and restore_at < settle_at < recover_at,
          "R17: the payload must be restored and read BEFORE the queue is settled — "
          "Seal kills itself mid-batch, so the running item's result only exists in the "
          "payload; settling first marks it 'unknown'")
    queue_tests = load("SealTests/Renewal/RefreshQueueStoreTests.swift")
    check("func recoverInterruptedSettlesItemsThatAlreadyHaveAResult()" in queue_tests
          and "func settledItemsLeaveOutstanding()" in queue_tests,
          "R17: settling instead of downgrading needs real unit tests — source assertions "
          "cannot prove the state that comes out")
    payload_tests = load("SealTests/Renewal/PendingBatchResultPayloadTests.swift")
    check("func onlySettledStatesAreMapped()" in payload_tests
          and "func sealItemIsSettledAsCompleted()" in payload_tests,
          "R17: the payload mapping needs real unit tests")

    # R18: 安装等待「明显超常」的记录（2026-09-17 加，**只记日志、不改变行为**）。
    #
    # 普通小包安装 7–11 秒，而等待上限按包大小算（小包 804 秒、大包 2400 秒）。
    # 「慢」与「死」在没有设备端进度信号时**无法区分** ⇒ 不能据此提前放弃；
    # 能做的是把「卡在传输还是卡在 installd」写清楚，让下一次真机日志可判读
    # （界面还显示上传百分比 = 卡在传输；显示「设备正在安装」= 卡在 installd）。
    #
    # ⚠️ 阈值**必须按本次等待上限算**（2026-09-17 修正）：第一版写死 120 秒 ——
    # 那是按小包定的，而**大包本来就慢**（抖音 779 MB 等两分钟完全正常）
    # ⇒ 写死会对大包报**假警报**，而假警报会把真信号埋掉。
    check("private static func abnormalInstallWaitSeconds(budget: Double) -> Double" in install_source
          and "max(120.0, budget / 4.0)" in install_source,
          "R18: 阈值必须**按本次等待上限**算 —— 写死 120 秒会对大包报假警报"
          "（抖音 779 MB 的上限是 2400 秒，等两分钟完全正常）")
    heartbeat_body = squash(section_or_empty(
        install_source,
        "private func beginInstallHeartbeat(",
        "private static let cachedSessionProbeThresholdSeconds"
    ))
    check("didReportAbnormal == false, Double(waited) >= threshold" in heartbeat_body,
          "R18: the abnormal record must fire exactly ONCE — a 13-minute wait would "
          "otherwise write six copies of the same warning and bury the real signal")
    check("throw " not in heartbeat_body and "reset()" not in heartbeat_body,
          "R18: the heartbeat must stay observation-only — turning it into a watchdog that "
          "gives up early would fail genuinely slow installs (上限按包大小算)")
    # ⚠️ 两个调用点必须**各自**传自己的预算：漏传一个会让那条链路退回写死阈值。
    check('beginInstallHeartbeat("自替换安装", budget: budget)' in install_source
          and 'beginInstallHeartbeat("安装", budget: mergedTimeout)' in install_source,
          "R18: both install paths must pass their OWN budget to the heartbeat — "
          "少传一个，那条链路就会用错阈值（自替换 892 秒 vs 普通 804 秒不是同一个数）")

    # R19: Seal 早期的**裸** Bundle ID `com.mjorb.seal` 也要能回收（2026-09-17 真机截图）。
    #
    # 它不含 `.seal.` 中缀 ⇒ 旧实现下永远回收不掉：keep-map 的 key 是**当前**形态
    # （`com.mjorb.seal.<team>`），形态判据又不认它。设备上会长期留着一份陈旧的「Seal」profile，
    # 而**两份同名**会让用户手动清理时删错正在用的那一份（对应 Seal 立刻无法启动）。
    policy_source = strip_comments(load("Seal/Core/Maintenance/ProfileReclaimPolicy.swift"))
    check("if lowered == SelfManagedSealMigrationPolicy.canonicalBundleIdentifier { return true }"
          in policy_source,
          "R19: Seal 早期的裸 Bundle ID 也必须能回收 —— 否则那份陈旧 profile 永远清不掉，"
          "而两份同名的「Seal」会让人删错正在用的那一份")
    # 引用既有常量，不抄第二份字面量（同一条规则两份实现，迟早漂移）。
    check('canonicalBundleIdentifier = "com.mjorb.seal"' not in policy_source,
          "R19: 必须引用 SelfManagedSealMigrationPolicy.canonicalBundleIdentifier，"
          "不要在回收策略里再抄一份字面量")
    # ⚠️ 精确相等，不能前缀匹配：`com.mjorb.sealX` 不是 Seal 生成过的任何形态。
    check("hasPrefix(SelfManagedSealMigrationPolicy.canonicalBundleIdentifier)" not in policy_source,
          "R19: 裸 ID 必须精确相等 —— 前缀匹配会把 `com.mjorb.sealX` 这类无关 ID 也放进来")
    # ⚠️ **顺序就是安全本身**：两条守卫（keep-map / 宽松受保护集合）必须先跑。
    # 裸 ID 分支若跑到前面，「正在用的那一份」会被判成候选 ⇒ 删掉 Seal 自己。
    orphan_body = squash(section_or_empty(
        policy_source,
        "static func isReclaimableOrphan(",
        "static func normalized(_ bundleID: String) -> String {"
    ))
    keep_at = orphan_body.find("keepingByBundleID.keys.contains")
    protect_at = orphan_body.find("protectedBundleIDs.contains")
    bare_at = orphan_body.find("lowered == SelfManagedSealMigrationPolicy.canonicalBundleIdentifier")
    check(keep_at != -1 and protect_at != -1 and bare_at != -1
          and keep_at < bare_at and protect_at < bare_at,
          "R19: the bare-ID branch must come AFTER both guards — otherwise the profile Seal "
          "is actually using gets treated as a candidate, i.e. you delete Seal itself")
    policy_tests = load("SealTests/Maintenance/ProfileReclaimPolicyTests.swift")
    check("func sealCanonicalBareIdentifierIsACandidate()" in policy_tests
          and "func sealCanonicalBareIdentifierRespectsTheKeepMap()" in policy_tests
          and "func sealCanonicalBareIdentifierIsNotAPrefixMatch()" in policy_tests,
          "R19: 三个方向都要有单测 —— 认得出、受 keep-map 保护、且不前缀匹配")

    # R20: 把 anisette 准备这段静默括起来（2026-09-17 真机，构建 105）。
    #
    # 真机日志实测：`证书检查` 之后**直接跳到 2 分钟后的失败**，中间一行都没有 ——
    # 而这一步恰好最可能慢（`anisetteProvider.fetch()` 要本地签名内核生成设备环境，
    # 代码在 `SEAL-AUTH-107t` 的文案里就写明「本地签名内核生成设备环境时卡住」）。
    # 与安装心跳同一条纪律：**长等待必须留下可判读的时间线**。
    portal_source = strip_comments(
        load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    )
    sign_once_body = squash(section_or_empty(
        portal_source,
        "private func signOnce(",
        "var session = ALTAppleAPISession("
    ))
    before_at = sign_once_body.find('"签名：正在准备设备环境（anisette）"')
    fetch_at = sign_once_body.find("anisetteProvider.fetch()")
    after_at = sign_once_body.find('"签名：设备环境已就绪，耗时')
    check(before_at != -1 and fetch_at != -1 and after_at != -1
          and before_at < fetch_at < after_at,
          "R20: the anisette step must be bracketed — 日志里「证书检查」到失败之间曾空白 2 分钟，"
          "而这一步是最可能慢的那一步；没有这两行就无法归因")
    check("Int(Date().timeIntervalSince(anisetteStartedAt))" in sign_once_body,
          "R20: 完成那条必须带耗时 —— 「是不是这步慢」只能靠它判断")

    # R21: 「证书轮换失败」必须说清**后果**（2026-09-17 真机）。
    #
    # 轮换循环是「先撤销、再创建」，而创建只在「3022 + 还有下一张」时才继续 ——
    # **其它错误直接抛出，而证书已经撤销了**。所以走到这条失败时，
    # **用那些证书签名的 App 已经无法启动**（真机实测：某个账号 `证书检查：远端 0 张`，
    # 就是上一轮这么留下的）。旧文案只说「已释放 N 张」+「稍后重试」：
    # ① 用户不会知道「为什么我的 App 突然打不开了」；
    # ② 若失败原因是会话失效（`SEAL-AUTH-102c` 那条路径），「稍后重试」是**无效建议**。
    rotation_failure = squash(section_or_empty(
        portal_source,
        'title: "证书轮换失败"',
        'code: "SEAL-CERT-227"'
    ))
    check("用这些证书签名的 App 现在无法启动" in rotation_failure,
          "R21: 「证书轮换失败」必须写明后果 —— 走到这里时用那些证书签的 App 已经打不开了，"
          "不写用户只会看到「App 莫名启动不了」")
    check("重新验证" in rotation_failure,
          "R21: recovery 不能只说「稍后重试」 —— 失败原因常常是会话失效，"
          "那种情况下重试无效，必须先重新验证账号")

    # R22: 日志码索引必须与源码一致（2026-09-17 加）。
    #
    # 用户发来日志时靠 `docs/qa/log-code-index.md` 把 `[SEAL-XXX-NNN]` 翻译成人话。
    # **手工维护的索引一定会漂移** —— 真实踩到：`SEAL-APPID-305`（刻意去掉的本地硬拦）
    # 与 `SEAL-CERT-224` 已不在源码里，而旧日志里还留着它们，很容易误判成「现在还在报」。
    # ⇒ 两侧都断言：主表里的码必须仍在源码里；「已移除」表里的码必须**确实**不在。
    index_source = load("docs/qa/log-code-index.md")
    live_part, separator, removed_part = index_source.partition("## 已从源码移除")
    check(separator != "", "R22: 日志码索引必须有「已从源码移除」一节（旧日志会看到历史码）")
    # ⚠️ 只从**表格行**取码：前言里会引用历史码（用来解释「防的就是这种漂移」），
    # 把前言也算进来会让这条断言永远红（2026-09-17 实际踩到）。
    def table_codes(part):
        rows = "\n".join(
            line for line in part.splitlines() if line.lstrip().startswith("|")
        )
        return set(re.findall(r"`(SEAL-[A-Z]+-[0-9]+[a-z]?)`", rows))
    live_codes = table_codes(live_part)
    removed_codes = table_codes(removed_part)
    known_codes = all_log_codes()
    stale = sorted(live_codes - known_codes)
    check(len(live_codes) >= 20 and not stale,
          "R22: 索引里这些码在源码里已不存在（文档漂移，会误导排查）：" + "、".join(stale[:6]))
    resurrected = sorted(removed_codes & known_codes)
    check(not resurrected,
          "R22: 「已移除」表里的码又回到源码里了（要么删掉该行、要么它其实没被移除）："
          + "、".join(resurrected[:6]))

    # R23: 证书阶段的「认证状态无效」不许只给「去重新验证」一条路（2026-09-17 用户反馈）。
    #
    # 同一个「认证状态无效」有两种成因：①登录真失效；②**短时间请求过密被 Apple 限流**
    # （多扩展 App 的典型症状：抖音 = 主 App + 8 扩展，一次签名连发 9 次 `addAppID`）。
    # 只给 ① 会把用户推进死循环：「重新验证 → 再签 → 又被限流 → 又被要求验证」——
    # 这正是用户反馈的原话（「无论怎样在验证 Apple ID 就报错失效」）。
    # `appIDFailure` 里早就为同一个 1100 修过，但**证书阶段漏了**。
    cert_failure = squash(section_or_empty(
        portal_source,
        "private static func certificateFailure(",
        "title: \"证书准备失败\""
    ))
    check("被 Apple 限流" in cert_failure,
          "R23: 证书阶段必须点明「可能是限流」—— 只写「登录失效」会让用户去反复重新验证，"
          "而限流情况下重新验证根本没用")
    check("先等几分钟重试" in cert_failure,
          "R23: recovery 必须先给「等几分钟」—— 顺序反了就是那个死循环")
    check('recovery: "前往「我的」页面重新登录该 Apple ID"' not in cert_failure,
          "R23: 不能退回「只让用户去重新验证」这一条路（那正是死循环的成因）")

    # R24: **跑在 per-bundle-ID 循环里的**每一个 portal 写入都必须过 `withSessionRecovery`。
    #
    # 为什么这条最要紧：多扩展 App 的 Phase 1 每个 bundle ID 要发**两次**写请求，
    # 抖音（主 App + 8 扩展）就是 18 次突发 ⇒ 撞上 Apple 的短时限流返回 1100 ⇒
    # 被归类成「账号需要重新验证」⇒ 用户去重新验证、再签、又被限流（死循环）。
    #
    # ⚠️ **2026-09-17 修正：原来的断言是 `count(...) == 3`，而那个 3 是从当时的代码里数出来的**
    # —— 它把「覆盖不全」固化成了期望值，于是 `updateFeatures`（`ALTAppleAPI.shared.update`）
    # 一直没接退避重试，守卫却全绿。漏掉它的两种后果**都不报错**：
    # ① 主 App 撞 1100 ⇒ `guard ... else { throw error }` ⇒ **整个签名失败**；
    # ② 扩展撞 1100 ⇒ 走降级分支把 entitlements **清空**继续签 ⇒ 签名「成功」但扩展缺权限。
    #
    # ⇒ 期望值改为**按操作逐个点名**（缺哪个报哪个），再用计数兜住「新增了第 6 类写入」。
    # 刻意**不**覆盖的：`revoke`（证书轮换时单发一次）、`registerDevice`、`fetch*` 系列 ——
    # 它们不在 per-bundle-ID 循环里，不构成突发。
    for label, why in (
        ('withSessionRecovery("创建 App ID \\(mappedBundleID)")',
         "创建 App ID"),
        ('withSessionRecovery("更新应用能力 \\(mappedBundleID)")',
         "更新应用能力（updateFeatures）—— Phase 1 里每个 bundle ID 的第二次写请求，"
         "与 addAppID 同等密集；主 App 撞 1100 会直接失败、扩展撞 1100 会被静默清空 entitlements"),
        ('withSessionRecovery("申请描述文件 \\(preparedAppID.mapped)")',
         "申请描述文件"),
        ('withSessionRecovery("创建证书")',
         "创建证书 —— 它是整条流程里第一个真正落到 Apple 侧的变更，最容易撞上限流；"
         "漏掉它会让限流被误报成「账号需要重新验证」"),
        ('withSessionRecovery("分配 App Group \\(mappedBundleID)")',
         "分配 App Group（付费账号才走，但同一条规则不该只落在免费路径上）"),
        ('withSessionRecovery("读取 App ID 列表", retriesOnTimeout: true)',
         "读取 App ID 列表（Phase 1 的**第一个**请求；2026-09-18 真机：它撞上 1100 时"
         "会直接让整轮签名失败，而失败点排在名额诊断之前 ⇒ 日志里连走到哪一步都看不出）"),
        ('withSessionRecovery("读取证书列表", retriesOnTimeout: true)',
         "读取证书列表（慢速路径；读操作，2026-09-18 补）"),
    ):
        check(label in portal_source, "R24: " + why + " 必须过退避重试")
    # 注意：定义写的是 `withSessionRecovery<T>(`，不带 `<` 的计数只数得到**调用点**。
    check(portal_source.count("withSessionRecovery(") == 7,
          "R24: 退避重试的调用点数量变了（应为 7 个：创建 App ID / 更新应用能力 / 申请描述文件 / "
          "创建证书 / 分配 App Group / 读取 App ID 列表 / 读取证书列表）—— "
          "新增或删除 portal 调用时请同步这里，别只改这个数字、先确认新调用是不是也在热路径上")

    # R24b: `applications` 字典的查询必须用 mapped ID（2026-09-18 真机日志实锤）。
    #
    # 字典从 `prepared.appURL`（SigningWorkspace 已把 Info.plist 的 CFBundleIdentifier
    # 改写成 mapped ID）解析建键 ⇒ 键是 mapped；历史 bug 用 original ID 查 ⇒ 恒 nil ⇒
    # ① `requestedEntitlements` 恒空（签出的包不带任何能力，付费账号不分配 App Group）；
    # ② features 诊断恒报「本次 []」（build 138 日志「远端 ["APG3427HIY"] vs 本次 []」）；
    # ③ 「跳过冗余 updateFeatures」优化永远不可能命中。
    # 注意：mapped 与 original 未必不同（无冲突时不加后缀），所以这条断言只能防**回退**，
    # 不能证明键一定对 —— 真正的判据是真机日志里「本次 []」变成真实能力集。
    check("if let application = applications[mappedBundleID] {" in portal_source,
          "R24b: Phase 1 的 applications 查询必须用 mapped ID —— 用 original ID 查恒 nil，"
          "entitlements 全部静默丢失")
    check("applications[originalBundleID]" not in portal_source,
          "R24b: 代码里不许再出现用 original ID 查 applications 的写法（键错位复发）")

    # R25: 同步阻塞 FFI 的**每一处**等待都要有界（2026-09-17 审计出来的）。
    #
    # 本仓明文规则：「同步阻塞 FFI 的等待必须带超时」。而 `Minimuxer.isAppInstalled`
    # 有两处**只放到 `Task.detached`、没有任何超时** —— 那只把它挪出主线程，
    # **阻塞本身仍然无界**：死会话上不报错、只阻塞到操作系统放弃。
    # 其中一处跑在维护期 ⇒ 一次无界阻塞会让**整轮维护永远完不成**（日志里毫无线索）。
    #
    # ⇒ 抽出共用的 `BlockingCall.bounded`，三处共用；通道里那份重复实现改为委托。
    blocking_source = strip_comments(load("Seal/Infrastructure/Installation/BlockingCall.swift"))
    check("enum BlockingCall {" in blocking_source
          and "static func bounded<T: Sendable>(" in blocking_source,
          "R25: 必须有一个共用的「有界同步 FFI」包装 —— 每处各抄一份迟早漂移")
    check("HardTimeout.run(seconds: seconds)" in blocking_source,
          "R25: 有界包装必须真的走硬超时")
    verifier_source = strip_comments(load("Seal/Features/Apps/InstalledAppDeviceVerifier.swift"))
    check("BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds" in verifier_source
          and "Task.detached" not in verifier_source,
          "R25: 设备核验的同步 FFI 必须有界 —— 只 Task.detached 不够，阻塞本身仍然无界")
    check("BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds" in cleaner_source,
          "R25: 维护期的设备探测必须有界 —— 一次无界阻塞会让整轮维护永远完不成")
    # 通道那份重复实现必须**委托**，不能再抄一遍（「同一条规则两份实现」已踩过五次）。
    check("await BlockingCall.bounded(seconds: seconds, work)" in install_source
          and "OffThreadOutcome" not in install_source,
          "R25: 安装通道的 offThread 必须委托给共用实现，不要保留第二份")
    # 安装后验证里的 `lookupApp` 也是同步阻塞 FFI，而且**在循环里跑 8 次**。
    check("let probe = await offThread(seconds: BlockingCall.queryTimeoutSeconds) {"
          in install_source
          and "Minimuxer.lookupApp(bundleId: bundleID) != nil" in install_source,
          "R25: 安装后验证里的 lookupApp 也必须是有界查询 —— 死会话上它会在 8 次循环里一直卡住")

    # R26: 创建 App ID 的顺序 —— 主 App 必须优先（2026-09-17）。
    #
    # 用户报「只有抖音签不上、重新加 Apple ID 也不行」。抖音 = 主 App + 8 扩展，
    # 一次签名要连发 9 次 `addAppID`，而免费账号的 App ID 名额是主 App 与扩展**共享**的：
    # 扩展创建失败会「丢弃降级」继续签名，**主 App 创建失败则整个签名抛错**。
    # 原实现按 Bundle ID 字母序创建 ⇒ 只要有扩展的字母序排在主 App 之前
    #（`com.x.app-ext` < `com.x.app`，因为 `-` 的码位小于 `.`），
    # 它就会先把名额吃掉，轮到主 App 时名额已空 ⇒ 整个 App 签不上，而名额已经白花。
    #
    # 顺序抽成纯函数 `ApplePortalAppIDResolver.preparationOrder` 以便单测 ——
    # 源码断言只能证明函数存在，证明不了它真的把主 App 排在前面（名额充足时两种顺序结果一样，
    # 只有单测能钉住「主 App 在最前」这个**行为**）。
    check("static func preparationOrder(" in portal_source
          and "ApplePortalAppIDResolver.preparationOrder(" in portal_source,
          "R26: 创建 App ID 的顺序必须抽成 ApplePortalAppIDResolver.preparationOrder 并真的被调用")
    check("mappings.sorted(by: { $0.key < $1.key })" not in portal_source,
          "R26: 不能退回「按 Bundle ID 字母序创建 App ID」—— 扩展会先吃掉共享名额，主 App 反而签不上")
    # 只用于断言：某个变异可能恰好删掉标记，用 section() 会让整轮守卫带栈崩掉。
    app_id_order_body = section_or_empty(
        portal_source,
        "static func preparationOrder(",
        "\n}"
    )
    check("let lhsIsMain = lhs.mapped == mappedMainBundleID" in app_id_order_body
          and "if lhsIsMain != rhsIsMain { return lhsIsMain }" in app_id_order_body,
          "R26: preparationOrder 必须真的把主 App 排到最前（不是只留个名字）")
    check("return lhs.original < rhs.original" in app_id_order_body,
          "R26: 主 App 之外的条目仍要按原序稳定排序，否则同一份输入的顺序会抖、日志对不上")
    # 名额诊断必须**无条件**写：缺了它，「名额不够」与「请求过密被限流」在导出的日志里
    # 长得一模一样（都是 App ID 阶段报会话失效），于是「用户把日志发给我能看出失败原因吗」= 不能。
    check(r'"App ID 名额：本次需 \(mappings.count) 个（主 App 1 + 扩展 \(extensionAppIDCount)），"'
          in portal_source,
          "R26: 必须无条件写一条「App ID 名额」诊断 —— 否则两种成因在日志里无法区分")
    app_id_order_tests = load("SealTests/Signing/ApplePortalSigningFailureTests.swift")
    check("func ordersAppIDCreationWithTheMainAppFirst()" in app_id_order_tests
          and "#expect(order.first?.mapped == main)" in app_id_order_tests,
          "R26: 主 App 优先的顺序必须由单测钉住（源码断言证明不了它真的排到最前）")

    # R28: 切 tab 的 UI 测试不能用「裸 tap + 一次等待」（2026-09-17）。
    #
    # 这条在 CI 上红过一次（`ImportFlowUITests.swift:45` 的 XCTAssertTrue 超时），
    # 而**同一份代码重跑就绿** ⇒ 是抖动不是缺陷。机制：初始 mode 由
    # `AppsRootView.resolveInitialModeIfNeeded()` **程序化翻页**决定，
    # pager 动画未结束时 `tap()` 会被吞掉。该测试原有的注释只防住了
    # 「切 mode 之前」那一次点击，没防住「点完之后目标页没出现」。
    # ⇒ 改用 `tapStage`（点 → 等 → 没到就再点；它**不掩盖确定性缺陷** —— 真坏了重试 4 次照样红）。
    #
    # 为什么值得写进守卫：这类回归**只在 CI 上间歇性暴露**，本地（无 Swift 工具链）根本看不出来，
    # 每次误判都要花掉一轮 15 分钟 + 一次人工排查（本次就是）。守卫能把它挡在推送前。
    # `not in` 断言前必须 `strip_comments()` —— 注释里写反面示例是允许的（本文件注释就提到过裸 tap）。
    ui_tests = strip_comments(load("SealUITests/ImportFlowUITests.swift"))
    check("private func tapStage(" in ui_tests
          and 'app.buttons["已安装，0 个"].tap()' not in ui_tests
          and 'app.buttons["待签名，0 个"].tap()' not in ui_tests,
          "R28: 切 tab 的 UI 测试必须用 tapStage —— 裸 tap 会撞上程序化翻页的动画尾部被吞掉，"
          "而这类抖动只在 CI 上间歇性暴露")
    # ⚠️ 断言必须落在**确定性的选中态**上（2026-09-18 实测后加固）。
    # `TabView(.page)` + `selection` 绑定在程序化改 `mode` 时**偶发不翻页**
    # （该测试第 40-42 行的注释早就记过这个「header 竞态」）。实测证据：上一版把它改成
    # 「点 4 次、每次等 3 秒」**仍然失败** ⇒ 不是「tap 被吞」，而是**点击被接受了、页面没翻**。
    # ⇒ 断言「目标页文字出现」会让 CI 间歇性红，而那是 SwiftUI 的行为、不是 Seal 的缺陷。
    # 选中态直接反映 `mode`（`modeButton` 用 `.accessibilityAddTraits(... .isSelected ...)`），
    # 点击一旦被接受就立刻成立 ⇒ 确定性。
    check("button.isSelected" in ui_tests,
          "R28: 切 tab 的断言必须落在**确定性的选中态**（`button.isSelected`）上 —— "
          "断言「目标页文字出现」依赖 `TabView(.page)` 翻页，会间歇性红")

    # R28b: **滑动**路径也要有同样的保护（2026-09-18 实测）。
    #
    # 上面那条规则原先只落在**点击**这条路径上：`tapStage` 已改成「点 → 等 → 没到就再点 +
    # 断言选中态」，而**滑动**那条仍在断言「目标页文字出现」—— 2026-09-18 构建 131 因此红：
    # `ImportFlowUITests.swift:63`（滑左之后 5 秒内「已安装应用」没出现）。
    # 而该提交**只有 8 张 PNG 删除、0 个 Swift 改动**，同一份测试代码在构建 130 是绿的
    # ⇒ 抖动，不是回归。**这是本仓第 7 次「规则只覆盖两条链路中的一条」**，所以守卫也要覆盖两条。
    #
    # 计数 1 = 裸滑动只允许出现在 `swipeStage` 内部（裸滑动会撞上程序化翻页的动画尾部被吞掉）。
    # 断言用 `squash` 写成一行式，避免数缩进空格（缩进一改守卫就莫名其妙地红）。
    check("private func swipeStage(" in ui_tests
          and ui_tests.count("pager.swipeLeft()") == 1
          and ui_tests.count("pager.swipeRight()") == 1,
          "R28b: 滑动路径也必须走 swipeStage —— 裸滑动会撞上程序化翻页的动画尾部被吞掉，"
          "而这类抖动只在 CI 上间歇性暴露")
    check("XCTAssertTrue( selected.isSelected," in squash(ui_tests),
          "R28b: 滑动路径的断言必须落在**确定性的选中态**（`selected.isSelected`）上 —— "
          "断言「目标页文字出现」依赖 `TabView(.page)` 翻页，会间歇性红")

    # R29: 证书轮换路径的「创建证书」也要过退避重试，且**共用**判据与间隔（2026-09-17）。
    #
    # `ApplePortalCertificateService`（证书轮换 / 孤儿证书清理）与
    # `ApplePortalSigningService`（签名）是**两条链路**，而「遇 1100 就退避」原先只落在签名那条上
    # —— 本仓第 6 次「规则只覆盖一条链路」。
    #
    # 为什么这条后果最严重：轮换的顺序是**先 revoke、再创建**。撤销成功而创建失败
    # （1100 被当成真过期、直接抛）会让这个账号变成 **0 张证书** ⇒
    # **用它签过的所有 App 立刻打不开**（不崩、不编译失败，只在真机上废掉一堆 App）。
    cert_service_source = strip_comments(
        load("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift")
    )
    check('withSessionRecovery("创建证书（证书轮换）")' in cert_service_source,
          "R29: 证书轮换路径的「创建证书」也必须过退避重试 —— 它前面刚 revoke 过，"
          "创建失败会让账号变成 0 张证书，用它签过的 App 全部打不开")
    # 判据与间隔必须**共用**签名服务那一份，不能在新链路里抄一份（抄一份迟早漂移成
    # 「同一个 1100 在一条链路上重试、在另一条上直接失败」）。
    # ⚠️ 断言必须**限定在重试循环体内**：R30 新加的文案分支里也出现了
    # `ApplePortalSigningService.isSessionExpiredError(error)`，用整文件的 `in`
    # 会让变异（把循环里的判据换成 `code == 1100`）**抓不到** —— 另一处出现把它兜住了。
    # 这是技能规矩 4 的实例：「片段在同一文件里出现多次时，`in` 断言就失去约束力」。
    cert_recovery_body = section_or_empty(
        cert_service_source,
        "private func withSessionRecovery<T>(",
        "private static func certificateMachineName("
    )
    check("ApplePortalSigningService.isSessionExpiredError(error)" in cert_recovery_body
          and "ApplePortalSigningService.sessionRecoveryBackoffNanoseconds" in cert_recovery_body,
          "R29: 退避重试的判据与间隔必须共用 ApplePortalSigningService 那一份")

    # R30: 证书创建被限流而失败时，文案必须说清两件事（2026-09-17）。
    #
    # 1100 原先**原样上抛**，落到调用方的通用 catch，变成
    # 「无法完成证书处理 … **没有返回明确失败原因**」+「重新同步证书后确认当前状态」——
    # 既没说清这是限流（不是登录真的失效），也没说清**旧证书已经撤销、
    # 这个账号现在可能没有可用证书**（本仓 R21 / R23 修过同一族的文案问题）。
    # 而这条链路的两个调用方（`revokeCertificateAndCreateLocal` / `executeCertificateCleanup`）
    # 都是**先撤销、再创建** ⇒ 创建失败 = 账号可能 0 张可用证书、已装 App 需要重新签名。
    # ⚠️ 只查文案不够：变异可以把条件改成 `if false` 而**文案原封不动** ——
    # 那样断言仍然全绿，而分支永远走不到。所以必须**同时断言分支条件**。
    # `if ApplePortalSigningService.isSessionExpiredError(error) {` 在文件里唯一
    # （重试循环里那处是 `guard ... else { throw error }`，形状不同）。
    check('code: "SEAL-CERT-233"' in cert_service_source
          and "这个账号现在可能没有可用证书" in cert_service_source
          and "if ApplePortalSigningService.isSessionExpiredError(error) {" in cert_service_source,
          "R30: 证书创建遇 1100 的文案必须写明「撤销已生效、账号可能没有可用证书」—— "
          "否则用户只看到「没有返回明确失败原因」，不知道要立刻重新创建一张")
    # ⚠️ 文案不能假设「一定发生了撤销」：设置页的「创建证书」按钮走的是同一个函数，
    # 那时没有任何撤销，说「撤销已生效」就是新的误导。
    check("若你刚才是在" in cert_service_source,
          "R30: 该文案不能假设「一定发生了撤销」—— 设置页的「创建证书」按钮也走同一个函数")

    # R31: 2026-09-18 真机（构建 118）——「只有抖音签不上」的真实失败链与三处修复。
    #
    # 日志证据（`Seal-log(14).txt`，构建 118，抖音两次尝试）：
    #   · **`退避` 零命中** ⇒ 退避重试一次都没触发（这些错误不是 `isSessionExpiredError`）；
    #   · 抖音两次**都没有** `App ID 名额` 那行 ⇒ 它根本没走到「建号」——
    #     失败在 Phase 1 的**第一个**请求 `fetchAppIDs`，而它原先既没退避重试、
    #     又排在名额诊断**之前** ⇒ 日志里连「走到哪一步」都看不出；
    #   · `appIDFailure` 给出的正确文案（「本次证书申请刚成功 ⇒ 更可能是限流，先等几分钟重试 /
    #     换账号」）被 `sign()` 的 catch **无差别替换**成「Apple ID 会话已过期 / 去「我的」重新验证」
    #     ⇒ 用户真的去重新加 Apple ID（原话：「重新添加 318***5*** 后我去签另一个应用是签名成功，
    #     我卸载后又签抖音 还是失败」）⇒ **死循环** —— 正是 `appIDFailure` 那段注释要避免的那个；
    #   · 证书列表拉取失败被 `try?` **吞掉错误**，日志只有「暂不可用」，分不出限流/超时/网络；
    #     这段静默在真机上长达 **112 秒**（06:48:46→06:50:38、06:54:37→06:56:29）。
    check("title: failure.title," in portal_source
          and "该 Apple ID 的登录状态已过期。签名过程中无法重新认证" not in portal_source,
          "R31: `sign()` 不能把 SEAL-AUTH-107 无差别替换成「去重新验证」—— "
          "那会覆盖 `appIDFailure` 特意写过的「先等几分钟 / 换账号」，把用户推回死循环")
    check("App ID 阶段开始：本次需" in portal_source,
          "R31: Phase 1 的入口必须先留痕 —— 完整的名额诊断排在 `fetchAppIDs` 之后，"
          "那个请求一失败，日志里就完全看不出「走到了哪一步」")
    check("证书列表拉取失败：耗时" in portal_source
          and "Self.isSessionExpiredError(failure)" in portal_source,
          "R31: 证书列表拉取失败必须记下**原因与耗时** —— 原先 `try?` 把错误吞了，"
          "日志只有「暂不可用」，分不出是限流、超时还是网络")

    # R32: 2026-09-18 真机（构建 118）—— **进度文案撒谎，把用户推进了死循环**。
    #
    # 抖音（779.7 MB）在 `signingWorkspace.prepare()`（解压 / 改写 Bundle / 重签二进制 / 重新打包，
    # **完全不碰 Apple**）上花了 **112 秒**，而它原先被算进 `.preparingAccount`
    # （文案「正在验证 Apple ID」、进度固定 **16%**）⇒ 用户盯着「正在验证 Apple ID 16%」
    # 等了 2 分钟，判断「Apple ID 验证卡住了」，**于是去重新验证 Apple ID** ——
    # 正是「重新验证 → 又被限流」死循环的**入口**。
    # 同一次日志里 3105（4.3 MB）/ LiveContainer（4.9 MB）是秒级 ⇒「只有抖音卡」的真正原因是**包大**。
    #
    # ⇒ 给它单独一个阶段。下面五条断言，每一条漏了都会**静默错**：
    signing_stage_source = strip_comments(load("Seal/Core/Signing/SigningStage.swift"))
    check("case preparingBundle" in signing_stage_source
          and "正在准备应用文件" in signing_stage_source,
          "R32: `preparingBundle` 阶段必须存在，且文案不能是「正在验证 Apple ID」")
    # ⚠️ 2026-09-18：这里原先断言「`SigningProgressView` 的三处 switch
    #（segmentFraction / overallProgress / timelinePosition）都必须处理 `preparingBundle`」。
    # 那三处 switch 已合并成 `SigningProgressBudget` 的**唯一一张表**，
    # 「每个阶段都被进度界面接住」改由 R36 逐个阶段点名 —— 比原来的 `count >= 3` 更强：
    # 后者只能证明「`.preparingBundle` 出现了 3 次」，证明不了「10 个阶段都在」。
    check("case .preparingBundle: .signing" in strip_comments(
              load("Seal/Core/Signing/SigningCoordinator.swift")),
          "R32: `SigningStage.appState` 必须处理 `preparingBundle`")
    check("case preparingBundle" not in strip_comments(load("Seal/Core/Apps/AppState.swift")),
          "R32: **不要**给 `AppState` 加 case —— 它是 `Codable` 且被持久化，加 case 会波及"
          "所有 switch 与旧数据；这里只需要一个正确的**文案**，不需要新状态")
    check(0 <= portal_source.find("await progress(.preparingBundle)")
          < portal_source.find("let prepared = try signingWorkspace.prepare("),
          "R32: `progress(.preparingBundle)` 必须发在 `signingWorkspace.prepare(` **之前** —— "
          "顺序错了文案就还是「正在验证 Apple ID」")
    check("应用文件准备完成（解压 + 结构改写；重签与打包另计），耗时" in portal_source,
          "R32: 这段准备必须记耗时 —— 原先它一行日志都没有，「等了 2 分钟」无法归因")
    # ⚠️ **文案不许声称它没做的事**（2026-09-18，由一份第三方审计发现）。
    # `signingWorkspace.prepare(...)` 只做「读中央目录 + 解压 + 结构改写 + 瘦身 + 归一化 +
    # 删旧签名」，**重签与打包都在它之后、不在这个计时窗口里**。
    # 原来那句写「（解压/改写/重签/打包）」会让人把它误读成「四件事加起来 N 秒」，
    # 从而**去优化解压**，而真正可能的大头（1.46 GB 的 deflate 打包）**根本没被计时**。
    check("（解压/改写/重签/打包）" not in portal_source,
          "R32: 「应用文件准备完成」的文案不许声称包含重签/打包 —— 它们不在这个计时窗口里")
    # 两处原本完全没埋点、却可能是耗时大头的阶段，必须有独立计时。
    # （打包：1.46 GB 走 deflate，按移动端单核 20–50 MB/s 估算量级 30–70 秒；
    #   重签：33 个 Mach-O 逐个串行，引擎无任何并发。）
    check("签名：打包完成（deflate），耗时" in portal_source
          and "签名：重签完成（逐 Mach-O 串行），耗时" in portal_source,
          "R32: 打包与重签必须各有独立耗时埋点 —— 它们是本地耗时的大头候选，"
          "原先完全没有埋点 ⇒ 「大包签名慢」只能靠猜")
    # R41: `prepare` 的耗时必须**拆出「解压」那一段**（2026-09-18 真机，构建 133）。
    #
    # 真机实测：抖音的 `prepare` 整体 **118 秒**，而它内部有**四次全树遍历**
    #（解压 / 结构改写 / 瘦身 arm64e / 归一化）⇒ 只报一个总数，**优化方向只能靠猜**
    #（3 号线原来猜「打包是最大头」，实测打包只有 1 秒 ✗）。
    # 拆成「解压 X 秒 / 其余遍历 Y 秒」两个数就足以定方向。
    # ⚠️ 这里**自包含地重新 load**（不依赖 `workspace_source`）—— 那个变量定义在本文件
    # 更靠后的 R35 段里，直接引用会 `UnboundLocalError`（本守卫自己抓到过 ✗）。
    # ⚠️ 锚点**刻意不含反斜杠**（2026-09-19）：Swift 的字符串插值是 `\(...)`，
    # 写进守卫的 Python 字符串要写 `\\(` —— 一旦层数写错，**断言与变异会一个过一个不过**
    # （本轮实际踩到 ✗）。改用不含反斜杠的 `prepared.xxxSeconds` 片段，转义层数为零 ✓。
    check("rewriteSeconds: rewriteSeconds" in strip_comments(
              load("Seal/Infrastructure/Signing/SigningWorkspace.swift"))
          and "prepared.rewriteSeconds" in portal_source
          and "prepared.stripSeconds" in portal_source
          and "prepared.normalizeSeconds" in portal_source,
          "R41: `prepare` 的耗时必须**拆到每一段**（解压 / 改写 / 瘦身 / 归一化）—— "
          "否则 105–120 秒里「解压」与「三趟全树遍历」无法区分，优化只能靠猜"
          "（「打包最大」与「解压最大」两个猜测**都**被实测推翻了 ✗）")

    # R42: **1100 不许被说成「限流」**（2026-09-19 真机，构建 141）。
    #
    # `withSessionRecovery` 的措辞判据就是 `isSessionExpiredError`（Apple 的 **1100 会话已过期**），
    # 而旧文案写「Apple 会话疑似被限流」✗ ⇒ 两个害处：
    #   ① 把用户引向「等一会儿再试」—— 而**退避治不好会话过期** ✗（白等 73 秒）；
    #   ② 日志里**看不到 1100** 这个真正的码 ⇒ 排查时只能看到「疑似限流」这种推测 ✗。
    # 真机证据（构建 141）：**两个不同 Apple ID、两次尝试形态完全相同**
    # ⇒ 那不是账号级的「限流」，是设备身份 / 网络出口级 ✓。
    check("Apple 会话已过期（1100）" in portal_source,
          "R42: 会话过期（1100）的措辞必须说准 —— 写成「疑似被限流」会把用户引向"
          "「等一会儿再试」（治不好），也让日志里看不到 1100 这个真正的码")
    check("换个节点再试" in portal_source,
          "R42: 退避全部失败时必须给出**可执行**的出路（重新验证 / **换网络节点**）—— "
          "真机证据是「两个不同账号失败形态完全相同」，那是网络出口级的特征，"
          "只说「重新验证」会让用户在账号上打转")

    # R43: **本地准备之后必须重建会话（换一份新的 anisette）**（2026-09-19 真机根因）。
    #
    # anisette 里的 `X-Apple-I-MD` 是**一次性验证码**，有效期只有几十秒 ✗；
    # 而 `prepare` 的解压 + 三趟全树遍历要 **105–120 秒** ✗
    # ⇒ 拿两分钟前取的 anisette 去请求 ⇒ Apple 判会话异常返回 **1100** ✗✗。
    #
    # 真机证据（构建 141，两次尝试、**两个不同 Apple ID，失败形态完全相同**）：
    #   23:56:05 「设备环境已就绪」（anisette 在这里取）
    #   → 120 秒本地准备 → 23:58:10 第一次 Apple 请求 ⇒ **1100** ✗
    #   而 gap **之前**的请求（fetchTeams / ensureDevice / 证书检查）**全部成功** ✓
    # ⇒ 时间顺序完全对上；也解释了「换账号也一样失败」（设备身份级，与账号无关）✓
    check("let freshSession = { (label: String) async -> ALTAppleAPISession? in" in portal_source
          and "var session = ALTAppleAPISession(" in portal_source,
          "R43: `prepare` 之后必须**重建会话**（重新取 anisette）—— "
          "anisette 的一次性码有效期只有几十秒，而本地准备要 105–120 秒 ⇒ "
          "不重建就是拿过期 anisette 去请求，Apple 判会话异常返回 1100")

    # R44: 阳性对照失败时必须输出**判别性诊断**（2026-09-19 真机，构建 141）。
    #
    # 真机：「阳性对照未通过（com.mjorb.seal.CT8QZ7352B 被答成未安装）」✗ ——
    # Seal 正在运行、它**一定**装着 ⇒ 核验通道在撒谎 ✓
    # 但「通道整体不可信」与「只有 Seal 自己的 ID 查不到」**现象完全相同** ✗
    # ⇒ 失败时必须再问两个**系统 App** 来判别，否则下一次真机日志仍然分不出来 ✓
    cleaner_source = strip_comments(load("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift"))
    check("com.apple.Preferences" in cleaner_source and "com.apple.mobilesafari" in cleaner_source,
          "R44: 阳性对照失败时必须输出**判别性诊断**（拿系统 App 再问一次）—— "
          "否则「通道不可信」与「只有 Seal 自己查不到」在日志里分不开")

    # R58: 阳性对照失败时，诊断里**必须带探测耗时**，并**再问同一个 ID 一次**（2026-09-20 真机）。
    #
    # `InstallProbe.unavailable` 把**超时**（`BlockingCall.bounded` 到点）与
    # **抛错**（`isAppInstalled` throw）**折叠成同一个值** ✗
    # ⇒ 真机日志里那句「阳性对照未通过」**分不出是哪一种** ✗，
    # 而两者的处置完全不同：**超时** ⇒ 通道还没就绪 / 已死；**抛错** ⇒ 查询被拒 ✓。
    #
    # 真机构建 175 实测（`Seal-log(28).txt`）：两次中止都发生在**刚启动**
    #（冷启动后 22 秒 / 自替换重启后 60 秒），且同行都带 `dump 尝试 N 次`；
    # 16 秒后再跑就正常了 ⇒ **强烈指向「启动早期通道还没就绪」** ✓
    # ⇒ **耗时是最便宜的判别器**（超时必然贴近上限、抛错是瞬时的 ✓），
    #   而「再问一次同一个 ID」能把「瞬时失败」与「通道持续撒谎」分开 ✓。
    check("probeInstalledWithDuration" in cleaner_source
          and "第一次=" in cleaner_source
          and "第二次=" in cleaner_source
          and 'String(format: "(%.1fs)", seconds)' in cleaner_source,
          "R58: 阳性对照失败时必须输出**带耗时的**探测结果（并再问同一个 ID 一次）✗ —— "
          "否则「超时」与「抛错」在日志里分不开，"
          "而真机实测中止都发生在刚启动、16 秒后就正常 ⇒ 分不出就没法定位 ✓")
    # R58b: `TimedProbe` **必须显式遵循 `CustomStringConvertible`**（2026-09-20 真机踩到）✗
    #
    # 光有一个 `var description` **不会**让字符串插值用它 —— 插值走的是**合成的**
    # memberwise 描述 ⇒ 真机日志里打出来的是
    # `TimedProbe(probe: Seal.…InstallProbe.unavailable, seconds: 2.4e-05)` ✗
    #（而且长到被日志行**截断** ✗）⇒ **诊断反而把日志变难读了** ✗。
    # ⇒ 这类「加了诊断、但诊断静默降级成噪音」的退化，只有守卫能钉住 ✓。
    check("struct TimedProbe: CustomStringConvertible" in cleaner_source,
          "R58b: `TimedProbe` 必须显式遵循 `CustomStringConvertible` ✗ —— "
          "只写 `var description` 不会被字符串插值采用（插值走合成的 memberwise 描述）⇒ "
          "日志里会打出原始结构体并被截断，诊断变噪音 ✗")

    # R59: 「加入 QQ 群」必须保留**两条路径**（2026-09-20）。
    #
    # `mqqapi://card/show_pslcard?...&uin=<群号>&card_type=group` 是**主路径**
    #（QQ 装了就直接开群资料卡 ✓），短链 `qm.qq.com/q/XXXX` 只在 **QQ 没装**时兜底 ✓。
    # ⚠️ **换群时两处必须一起改** ✗ —— 短链是**不透明**的，从链接本身看不出群号 ✗，
    # 只换短链会让主路径跳进**旧群** ✗✗（2026-09-20 实际踩到 ✓）。
    # ⚠️ 本断言只能钉「两条路径都还在」✓；「两处指向同一个群」**无法静态校验** ✗
    #（要联网解析短链才拿得到群号 ✗）⇒ 只能靠上面那段注释 + 台账提醒 ✓。
    community_source = load("Seal/Features/Settings/SealCommunityView.swift")
    check("private let qqGroupNumber" in community_source
          and "private let qqJoinURL" in community_source
          and "mqqapi://card/show_pslcard" in community_source
          and "openURL(fallback)" in community_source,
          "R59: 「加入 QQ 群」必须保留**两条路径**（`mqqapi` 主路径 ＋ 短链兜底）✗ —— "
          "删掉任一条：**没装 QQ 的用户点进去没有任何反应** ✗")

    # R60: 发布正文必须**只取「第一个版本」那一节**（2026-09-20 修）✗
    #
    # 原来是 `NOTES="$(cat RELEASE_NOTES.md)"` ✗ ⇒ **更新弹窗把所有历史版本全列出来**
    #（实测：整个文件 74 行 / 5 个版本 ✗），而且旧版本文案里带 `installation_proxy` /
    # `installd` 这类**内部术语** ✗✗ —— 那是给开发者看的，不该出现在用户弹窗里 ✓。
    # ⚠️ 两个发布档（完整档 + 快速档）**都有**这段 ✗ ⇒ 必须**同时**钉住 ✓。
    release_workflows = (".github/workflows/ios.yml", ".github/workflows/ios-release.yml")
    check(all('NOTES="$(cat RELEASE_NOTES.md)"' not in load(w) for w in release_workflows)
          and all("if (found) exit; found=1" in load(w) for w in release_workflows),
          "R60: 发布正文必须**只取第一个版本一节** ✗ —— 取整个文件会让更新弹窗"
          "列出所有历史版本（且含内部术语）✗；两个发布档都要改 ✓")

    # R60b: `RELEASE_NOTES.md` 的**第一节版本必须等于 `MARKETING_VERSION`**（2026-09-20）✓
    #
    # 因为正文只取第一节（R60 ✓）⇒ 两者不一致就会**给用户发错版本的说明** ✗✗
    #（例如新版本写好了、版本号没 bump ⇒ 弹窗显示上一版的文案 ✓；
    #  或把新版本**追加到末尾**而不是置顶 ⇒ 同上 ✓）。
    #
    # ⚠️ **第一版判据写成「第一个是最高版本」—— 太弱** ✗：
    # 把第一节的 `# ` 降级成 `## `（等于**删掉**第一节）之后，
    # 剩下的第一个（1.1.16）**自己就是最高** ⇒ 判据照样 PASS ✗✗，
    # 变异检查当场报 `Guard failed mutation check: R60b` ✓。
    # ⇒ 改成跟 `MARKETING_VERSION` **对账** ✓（这才是真正要守的东西 ✓）。
    marketing_versions = re.findall(r"MARKETING_VERSION:\s*(\S+)", load("project.yml"))
    notes_first = re.findall(r"^# (\d+\.\d+\.\d+)", load("RELEASE_NOTES.md"), re.M)
    check(len(marketing_versions) == 1
          and len(notes_first) >= 1
          and notes_first[0] == marketing_versions[0],
          "R60b: `RELEASE_NOTES.md` 的**第一节版本必须等于 `MARKETING_VERSION`** ✗ —— "
          "发布正文只取第一节（R60）⇒ 不一致就会**给用户发错版本的说明** ✗；"
          "新版本必须**置顶**，不能追加到末尾 ✓")

    # R45: 重签前必须有「**分界日志**」（2026-09-19 真机，构建 147）。
    #
    # 真机：Seal 在 `signing` 阶段**直接闪退** ✗（两次都在同一位置，日志到此为止，
    # 没有 error、没有打包、没有安装）⇒ 导出日志里连
    # 「死在重签**前**还是重签**中**」都分不出来 ✗。
    # ⇒ 重签前必须留一行，把问题一分为二 ✓。
    check("签名：开始重签（逐 Mach-O 串行）" in portal_source,
          "R45: 重签前必须有「分界日志」—— 真机上 Seal 在 signing 阶段闪退，" 
          "没有它连「Swift 侧准备」与「签名器内部」都分不开")

    # ⚠️ **R46 已移除**（2026-09-19）：签名器从 `Vendor/rork-sign` 换成了上游
    # `SideSign` + `CodeSignKit` ✓（用户死命令「一个代码不漏地抄，不要打补丁」✓），
    # 而 `Seal/Infrastructure/Signing/RorkAppSigner.swift` **整个文件已删除** ✗
    # ⇒ 这条断言失去了对象 ✓。
    #
    # 🔴 **但它守的知识必须留档** ✗ —— 真机（构建 147）Seal 在 `signing` 阶段被 iOS
    # **按 CPU 预算杀掉**（崩溃日志 `bug_type 202`：90 秒 CPU / 166 秒，
    # 超过「180 秒内 50%」的上限），而当时签名阶段**一行日志都没有** ✗
    # ⇒ 连「死在哪个 bundle」都不知道 ✗。
    #
    # 换签名器之后这个能力**变弱了** ✗（必须如实记录，别让它悄悄消失）：
    #   · `rork-sign` 有 `AppSigningOptions.diagnostics`，Seal 打开后能拿到**逐 bundle** 的诊断 ✓；
    #   · 上游 `SideSign` 只有 `verboseLog`（逐 bundle，但走 `print` ⇒ **进不了 Seal 的日志** ✗）
    #     与 `signApp(progress:)`（`Progress.completedUnitCount` **逐 Mach-O 累加**，
    #     但没有回调、只能轮询 ✗）。
    # ⇒ **现在真机上「死在哪个 bundle」只能靠 `SEAL-STAGE-001` 的阶段边界 + 日志戛然而止推断** ✗。
    # ⇒ **真机回归时必须专门验证**：抖音（9 个 bundle）重签**不再**被 CPU 预算杀掉 ✓；
    #    若再被杀，就去接上游 `progress:`（它是上游自己的 API ✓，不算发明 ✓）。

    # R47: Bundle ID 的报错必须**说清是 Apple 的规定**，并指出「显示名可以带表情」
    #（2026-09-19 用户问「Bundle ID 能不能带符号/表情」）。
    #
    # 带空格 / 中文 / 表情 / 符号的 Bundle ID 会被 **Apple 直接拒绝** ✗ ——
    # 不是 Seal 的限制。而「桌面显示的名字」写在 `CFBundleDisplayName`，**可以带表情** ✓。
    # 不把这两件事分开说，用户会以为「Seal 不支持表情」✗。
    bundle_policy_source = strip_comments(load("Seal/Core/Signing/BundleIDPolicy.swift"))
    check("Apple 规定" in bundle_policy_source and "App 名称" in bundle_policy_source,
          "R47: Bundle ID 的报错必须说清「这是 Apple 的规定」，"
          "并指出想带表情应该改「App 名称」—— 否则用户会以为 Seal 不支持表情")

    # R48: 签名器诊断**必须过滤**（2026-09-19 真机，构建 151 —— 我自己引入的回归 ✗）。
    #
    # 打开签名器诊断后，它对**每个** bundle（含 `BDAlogProtocol.bundle` 这类纯资源包）
    # 和每个 Mach-O 各打一行 ⇒ 抖音一次 **200+ 行** ✗
    # ⇒ 1000 条环形缓冲被占满，把**阶段 / 耗时 / 错误**全挤掉 ✗
    #（实测那一份日志 204/240 行都是「重签：」✗）。
    #
    # ⚠️ 过滤太松会刷爆日志、太紧会丢掉崩溃点 —— 两种都**不编译失败、也不崩**，
    # 所以既要有纯函数 + 单测，也要有这条守卫 ✓。
    portal_filter_source = strip_comments(
        load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    )
    # ⚠️ **2026-09-19 收窄**：签名器已从 `rork-sign` **换成上游 `SideSign`** ✓
    #（用户死命令「照抄」✓），而上游的诊断走它自己的 `debugLog` ✗ ——
    # **不再经过 Seal 的回调** ⇒ 原来的 `guard Self.isUsefulSigningDiagnostic(message)` 调用点**已移除** ✓。
    #
    # ⇒ 断言改成**只要求过滤规则本身还在** ✓（它是对的 ✓，将来若再接诊断出口就直接用 ✓）；
    #    **不再要求调用点存在** ✗（那会把「已换成上游签名器」这件事判成红 ✗）。
    check("static func isUsefulSigningDiagnostic(" in portal_filter_source,
          "R48: 签名器诊断的**过滤规则**必须保留 —— 一旦再接诊断出口，不过滤会刷爆 "
          "1000 条环形缓冲，把阶段 / 耗时 / 错误全挤掉（真机实测 204/240 行都是「重签：」）")

    # R49: 判 Mach-O 时**不许把整个二进制读进内存**（2026-09-19 真机，构建 151）。
    #
    # `rewriteExecutablePathReferences` 对**全树每个 Mach-O** 调用一次，
    # 而它第一步是 `Data(contentsOf:)` ⇒ 抖音 30+ 个 framework、几百 MB 白搬进内存 ✗
    #（紧接着的 `firstRange` 判定在**绝大多数二进制上都会失败** ✗）。
    # 实测：「归一化」段 **45 秒** ✗ + 崩溃日志 `Footprint: +956.91 MB` ✗，
    # 而崩溃点正是最大的 `AwemeCore.framework` ✓。
    # ⇒ 必须用 `.mappedIfSafe`（mmap，不复制、不占常驻内存）✓
    # ⚠️ **2026-09-19 真机崩溃后反转**：这里**必须用普通读取，绝不能用 mmap** ✗✗
    #
    # 崩溃栈：`_platform_memmove` ← `Data._Representation.replaceSubrange` ←
    #         `SigningWorkspace.rewriteExecutablePathReferences`，
    # 异常：`EXC_BAD_ACCESS (SIGBUS)` / `KERN_PROTECTION_FAILURE`，
    # 地址落在 **mapped file** 区域（`vmRegionInfo` 明确指认 ✓）。
    #
    # 原因：本函数会 `replaceSubrange` **原地改写**这份 Data 再 `write` 回盘 ✗；
    # Swift 的 COW 判定「唯一引用」⇒ **直接在映射页上写** ✗ ⇒ 写只读页 ⇒ SIGBUS ✗✗。
    # ⇒ **判据：凡是要改写的 Data 一律不许 mmap；只有纯读的检查才可以用** ✓
    workspace_src = strip_comments(load("Seal/Infrastructure/Signing/SigningWorkspace.swift"))
    check("guard var data = try? Data(contentsOf: machOURL) else { return }" in workspace_src
          and "Data(contentsOf: machOURL, options: .mappedIfSafe)" not in workspace_src,
          "R49: `rewriteExecutablePathReferences` 会**原地改写**这份 Data ⇒ 必须普通读取 ✗ —— "
          "用 mmap 会在写映射页时 SIGBUS（2026-09-19 真机崩溃 ✓）")

    # ⚠️ **R52 已移除**（2026-09-19）：签名器从 `Vendor/rork-sign` 换成了上游
    # `SideSign` + `CodeSignKit` ✓（用户死命令「一个代码不漏地抄，不要打补丁」✓），
    # `Vendor/rork-sign` **整个目录已删除** ✗ ⇒ 这条断言失去了对象 ✓。
    #
    # 🔴 **但它守的知识必须留档** ✗ —— 已核实：
    #   `CodeSignKit/MachOParser.swift:555` 只有「**读** cryptid」没有「清零」✓，
    #   `SideSign` / `SideStore` 也**完全不处理** ✗。
    #
    # 后果（原文照录）：
    #   「a decrypted image that still advertises cryptid=1 makes dyld attempt
    #     FairPlay decryption with the wrong account and **crash at launch**」
    # ⇒ **签名后启动崩溃** ✗✗ —— 最高严重级。
    #
    # ⇒ **真机回归时必须专门验证「装完能不能启动」** ✓（这是换签名器引入的**已知风险** ✓）。
    # ⇒ 若真的启动崩，把原来那个补丁移植到 `CodeSignKit` ✓
    #   （原型见 `Vendor/rork-sign` 的历史提交 `b548021` ✓，
    #    以及 `docs/upstream-alignment.md` 的台账 ✓）。

    # R54: `ios.yml` 的 push 触发路径必须覆盖**整个 `Vendor/`**（2026-09-19 实踩 ✗）
    #
    # 原来只列了 `Vendor/Minimuxer/**` ✗ —— 于是「改了
    # `Vendor/CodeSignKit/Package.swift`（统一 swift-crypto 版本）」**根本不触发 CI** ✗✗，
    # 推上去后干等，还以为 CI 在跑 ✓。
    #
    # ⚠️ 而现在 `Vendor/` 里已经有**签名器本体**（`SideSign` / `CodeSignKit` ✓）
    # 和它的一串依赖（`GSACryptoKit` / `libdeflate` / `AnisetteKit` ✓）
    # ⇒ 改它们却不跑 CI = 可能把坏代码推上去而毫无察觉 ✗。
    #
    # ⇒ 断言必须是 `Vendor/**`（整目录 ✓），不能是某个子目录 ✗。
    #（`paths` 只决定**要不要触发**，不影响构建耗时 ✓。）
    ios_workflow = load(".github/workflows/ios.yml")
    check('"Vendor/**"' in ios_workflow
          and '"Vendor/Minimuxer/**"' not in ios_workflow.split("paths:")[1].split("workflow_dispatch")[0],
          "R54: `ios.yml` 的 push 触发路径必须覆盖整个 `Vendor/**` ✗ —— "
          "只列 `Vendor/Minimuxer/**` 会让「改了签名器却不跑 CI」，推上去干等 ✓")

    # R55: 签名身份读取必须走**上游 `MachOParser`**（2026-09-19，换签名器的一部分 ✓）
    #
    # 背景：Seal 原来用 `RorkSigner.checkMachOCodeSignatures` ✗ —— 它**整块读**可执行文件；
    # 上游 `SideStore/CertificateManager.swift:325` 用的是 `MachOParser(url:)` ✓，
    # 而 `MachOParser` 内部是 `.mappedIfSafe`（**mmap** ✓）⇒ 更省内存 ✓。
    #
    # ⚠️ 这条路径**喂给 `SEAL-CERT-232`** ✗（「读不出身份 ⇒ 中断证书轮换」）
    # ⇒ 影响的是**真实行为**，不是纯诊断 ✓。
    # ⚠️ 实测：把 `RorkSigner` 的引用全删掉后，**原来的守卫照样全绿** ✗
    # ⇒ 说明这条路径**此前没有任何守卫覆盖** ✓ ⇒ 补上 ✓。
    identity_reader = strip_comments(
        load("Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift")
    )
    check("import CodeSignKit" in identity_reader
          and "try? MachOParser(url: executableURL)" in identity_reader
          and "parser.x509Certificates()" in identity_reader
          and "RorkSigner." not in identity_reader,
          "R55: 签名身份读取必须走上游 `MachOParser`（mmap ✓）✗ —— "
          "退回 `RorkSigner` 会变成整块读，且这条路径喂给 SEAL-CERT-232，影响真实行为 ✓")

    # R50: 读**可执行文件**（取 entitlements / 改 load commands）时**不许整块读入**
    #（2026-09-19 真机：崩溃点正是「**刚开始签最大的 `AwemeCore.framework`**」✗）。
    #
    # 这些调用只需要 Mach-O 的**头部 / load commands**，却把整个二进制搬进内存 ✗
    # —— 抖音的 framework 有上百 MB，而崩溃日志里 `Footprint +956.91 MB` ✓。
    # 两条链路（AppBundleSigner / BundleSigner）都要，缺一条就等于没修 ✗。
    # ⚠️ **2026-09-19 真机崩溃后收窄**：mmap **只准用在纯读的地方** ✓
    #
    # 保留（纯读）：`readEntitlementsXML(...)` / `inspectMachO(...)` / 缓存条目 decode ✓
    # 回退（会被改写 ✗）：签名主路径的 `input`（进签名器）/ `var executable`（会被重新赋值）
    #   —— 二者都会 SIGBUS（同 R49 ✓）。
    # ⚠️ **R50 已移除、判据改由 R57 承接**（2026-09-19）：签名器换成上游
    # `SideSign` + `CodeSignKit` 后，`Vendor/rork-sign` **整个目录已删除** ✗
    # ⇒ 原来那两条断言失去了对象 ✓，**但同样的判据已重定向到 `CodeSignKit`** ✓（见下面的 R57 ✓）。
    #
    # 🔴 **但「mmap 判据」必须留档** ✗ —— 这是 2026-09-19 真机 SIGBUS 换来的：
    #   **不是「哪里该用 mmap」，而是「这份 Data 会不会被原地写」** ✓
    #   · **只读 ⇒ mmap 安全** ✓
    #   · **原地写 ⇒ 必须整块读** ✓（`SigningWorkspace.rewriteExecutablePathReferences`
    #     —— 这条**仍然由 R49 钉住** ✓）
    # ⇒ 换成上游签名器后，这条判据在 `CodeSignKit` 里同样适用 ✓
    #   （上游 `MachOParser` 用 mmap 读 ✓、`MachOSigner:301` 用 `subdata` 复制后改 ✓）。
    # ✅ **照抄上游 `mahee96/CodeSignKit`（SideStore 用的签名器）的内存策略**（2026-09-19 ✓）
    #
    # 用户指示「**照抄，禁止乱发明**」✓ —— 上游的做法是：
    #   `MachOParser.swift:154,157` 用 `Data(contentsOf:…, options: .mappedIfSafe)` 读 ✓
    #   `MachOSigner.swift:301` 用 `workingData.subdata(in: 0..<codeLimit)` **复制出新 Data 再改** ✓
    # ⇒ **mmap 读（0 内存）+ 复制后改（1×）⇒ 全程 1 份** ✓
    #
    # ⚠️ **为什么这里 mmap 安全** ✗（本仓 2026-09-19 在别处踩过 SIGBUS ✓）：
    # 本文件的签名入口**全部是 `_ data: Data`（不是 `inout`）** ✓，
    # 改写都发生在 `var output = data` 的 **COW 副本**上 ✓ ⇒ mmap 那份**只被读** ✓。
    # **反面**：`SigningWorkspace.rewriteExecutablePathReferences` **原地改** ⇒ 那里**必须**整块读 ✓（R49）。
    # **⇒ 判据不是「哪里该用 mmap」，而是「这份 Data 会不会被原地写」** ✓。
    # （上面那条断言已随 `Vendor/rork-sign` 删除 ✓ —— 同样的判据现在适用于 `CodeSignKit` ✓。）

    # R53: `rewriteExecutablePathReferences` 必须**先分块预扫描**，命中才整块读 ✓
    #
    # 2026-09-19 两次真机迭代的结论（两个极端都不能选 ✗）：
    #   ① 整块 `Data(contentsOf:)` ⇒ 抖音全树 1.46 GB 白读 ⇒ **45 秒 + 内存峰值** ✗
    #      用户实测：内存峰值让 iOS **jetsam** 批量杀后台（**网易云 + LocalDevVPN 一起被杀** ✗）
    #   ② `.mappedIfSafe` ⇒ 下面要 `replaceSubrange` 原地改写 ⇒ **SIGBUS 崩溃** ✗✗
    #   ③ **分块扫描** ✓ ⇒ 既不吃内存 ✓ 也不 SIGBUS ✓
    #
    # ⚠️ 分块扫描必须排在**整块读之前** ✗ —— 排后面等于没改 ✓。
    # ⚠️ 重叠必须保留 `needle.count - 1` 字节 ✗ —— 漏掉跨块匹配会导致**该改写的没改**
    #    ⇒ 装完闪退 ✗✗（这条最危险，所以也钉住 ✓）。
    check("func containsBytes(" in workspace_src
          and "guard containsBytes(rpathNeedle, in: machOURL) else { return }" in workspace_src
          and "Data(buffer[0..<total]).range(of: needle) != nil" in workspace_src
          and 0 <= workspace_src.find("guard containsBytes(rpathNeedle, in: machOURL)")
          < workspace_src.find("guard var data = try? Data(contentsOf: machOURL)")
          and "findsNeedleStraddlingAChunkBoundary" in load(
              "SealTests/Signing/SigningWorkspaceChunkedScanTests.swift"),
          "R53: `rewriteExecutablePathReferences` 必须先**分块预扫描**、命中才整块读 ✗ —— "
          "整块读会让 jetsam 杀后台（网易云 + LocalVPN 一起被杀 ✓），mmap 会 SIGBUS ✗")
    # R57: **换签名器之后，「内存策略」这条判据必须钉在新内核上**（2026-09-19）✓
    #
    # R50 守的是 `Vendor/rork-sign` 的 mmap 读 ✗ —— 那个目录已删 ✓；
    # 而它守的**知识**现在适用于上游 `CodeSignKit` ✓（这是「照抄」能成立的前提 ✓）：
    #   · `MachOParser.swift:154,157` 用 `.mappedIfSafe` 读 ✓（0 常驻内存 ✓）
    #   · `MachOSigner.swift:301` 用 `subdata` **复制出新 Data 再改** ✓（全程 1 份 ✓）
    # ⇒ **整条链路只有 1 份内存** ✓ —— 这正是抖音（780 MB + 8 扩展）不再 jetsam 的原因 ✓。
    #
    # ⚠️ 这条断言**不是形式主义** ✗：本仓 2026-09-19 实测过另一条路 ——
    # 整块 `Data(contentsOf:)` 让抖音签名的内存峰值到 **2.11 GB**
    #（`JetsamEvent`：`largestProcess = "Seal"`，`rpages 129697 × 16KB` ✗），
    # 连带把后台的网易云 / LocalDevVPN 一起杀掉 ✗✗。
    # ⇒ 谁把 `CodeSignKit` 的 mmap 改成整块读，谁就把那个 2 GB 峰值请回来了 ✗。
    codesignkit_parser = load("Vendor/CodeSignKit/Sources/MachOParser.swift")
    codesignkit_signer = load("Vendor/CodeSignKit/Sources/MachOSigner.swift")
    check("Data(contentsOf: execURL, options: .mappedIfSafe)" in codesignkit_parser
          and "Data(contentsOf: url, options: .mappedIfSafe)" in codesignkit_parser,
          "R57: 上游 `CodeSignKit/MachOParser` 必须**用 mmap 读**（`.mappedIfSafe`）✗ —— "
          "改成整块读会把抖音签名的内存峰值请回 2.11 GB，触发 jetsam 批量杀后台")
    check("workingData.subdata(in: 0..<min(codeLimit, workingData.count))" in codesignkit_signer,
          "R57: 上游 `CodeSignKit/MachOSigner` 必须**复制出新 Data 再改**（`subdata`）✗ —— "
          "在 mmap 的那份上原地改会写只读页 ⇒ SIGBUS（本仓 2026-09-19 真机踩过 ✓）")

    filter_test_source = load("SealTests/Signing/SigningDiagnosticFilterTests.swift")
    check("signedCodeAlwaysPasses" in filter_test_source
          and "resourceBundlesAreDropped" in filter_test_source,
          "R48: 过滤规则必须有单测（signedCode 必须放行 / 资源包必须丢掉）—— "
          "过滤太紧会丢掉崩溃点，而那种错法不编译失败、也不崩")

    # R36: 进度条与阶段轨道的数值只许来自 `SigningProgressBudget`（2026-09-18）。
    #
    # 起因：用户反馈「百分比进度条和底部 5 个横杠都是跳着走的，不像 0→100 的丝滑」。
    # 根因不是动效 —— 是**进度只是 `SigningStage` 的纯函数**（10 个阶段 → 10 个写死的
    # 常数、没有任何时间项），于是两次阶段推送之间界面只能冻结、阶段一变就跳一格；
    # 而同一套语义还写在**三处 switch** 里（`segmentFraction` / `overallProgress` /
    # `timelinePosition`），改一处漏两处也不会报错。
    #
    # 现在收敛成一张表 + 一组纯函数，所以这里守两件事：
    #   ① 每个阶段都必须有预算 —— 漏一个，界面上那个阶段会停在上一阶段的数值上；
    #   ② 表的连续性 `ceiling_i == floor_{i+1}` —— 破了它，阶段切换时进度会跳一下或往回退。
    # 两条都属于「不崩、不报错、只在真机上看得见」，只能靠守卫 + 单测钉住。
    budget_source = strip_comments(load("Seal/Core/Signing/SigningProgressBudget.swift"))
    stage_source = strip_comments(load("Seal/Core/Signing/SigningStage.swift"))
    stage_names = re.findall(r"^    case (\w+)$", stage_source, re.M)
    # 这条是**正则漂移**的哨兵：取不到阶段名时下面那个循环会变成空集 ⇒ 永远绿。
    check(len(stage_names) >= 10,
          "R36: 没能从 `SigningStage` 里取到阶段名（正则漂移 ⇒ 「每个阶段都有预算」会退化成空检查）")
    for stage_name in stage_names:
        check("case .%s:" % stage_name in budget_source,
              "R36: 阶段 `%s` 没有进度预算 —— 界面上它会停在上一阶段的数值上" % stage_name)
    budget_rows = re.findall(r"floor: ([0-9.]+), ceiling: ([0-9.]+),", budget_source)
    check(len(budget_rows) == len(stage_names),
          "R36: 预算表行数（%d）与阶段数（%d）不一致" % (len(budget_rows), len(stage_names)))
    for row_index in range(len(budget_rows) - 1):
        check(budget_rows[row_index][1] == budget_rows[row_index + 1][0],
              "R36: 阶段预算必须首尾相接（ceiling_i == floor_{i+1}）—— "
              "破了它，阶段切换时进度会跳一下或往回退")
    budget_view = strip_comments(load("Seal/Features/Apps/SigningProgressView.swift"))
    for budget_symbol, budget_why in (
        ("SigningProgressBudget.bucketCount", "轨道格数"),
        ("SigningProgressBudget.bucketFill(", "轨道每一格的填充"),
        # ⚠️ 2026-09-19：`overallProgress`（**估算**）**不再**被视图使用 ——
        # 用户明确要求「圈圈不要假预估」⇒ 环与数字只取 `confirmedProgress` ✓。
        # 估算函数本身**保留**（`bucketFill` 仍在用），但不再要求视图消费它 ✓。
        ("SigningProgressBudget.confirmedProgress(", "进度环的「已确认」那一段"),
        # ⚠️ 2026-09-19：`isEstimated`（估算态）**不再**被视图使用 ——
        # 扫光与呼吸点都已随「圈圈不要假预估」去掉，它现在没有读者了 ✓。
        # 函数本身**保留**（语义仍是「这个阶段有没有真实进度信号」），只是不再要求视图消费 ✓。
        ("SigningProgressBudget.showsOwnElapsed(", "长阶段的「本阶段已用时」"),
    ):
        check(budget_symbol in budget_view,
              "R36: `SigningProgressView` 必须用 " + budget_symbol + "（" + budget_why + "）")
    # 界面里不许再出现写死的进度常数 —— 那正是「跳着走」的来源。
    for stale_progress in (
        "case .preparingBundle: return 0.23",
        "case .preparingCertificate: return 0.30",
        "case .installing: return 0.93",
        "case .verifying: return 0.99",
        "segmentFraction(for stage: SigningStage)",
        "timelinePosition(for stage: SigningStage)",
    ):
        check(stale_progress not in budget_view,
              "R36: `SigningProgressView` 不许再写死进度（%s）—— "
              "数值只许来自 `SigningProgressBudget`" % stale_progress)
    # 单测必须真的在守这两条性质：测试被删空或改宽之后，上面的源码断言照样全绿。
    budget_tests = strip_comments(load("SealTests/Signing/SigningProgressBudgetTests.swift"))
    check("func everyStageBudgetMeetsTheNextOne()" in budget_tests
          and "current.ceiling == next.floor" in budget_tests,
          "R36: 单测必须断言「阶段预算首尾相接」")
    check("func theTwoLongStagesNoLongerStandStill()" in budget_tests
          and "#expect(bundle > 30)" in budget_tests,
          "R36: 单测必须断言「两个长阶段不再一动不动」")

    # R33: 「**读**可重试超时、**写**绝不可」是硬规则（2026-09-18）。
    #
    # 为什么读要开：读是幂等的（`fetchAppIDs` / `fetchCertificates`），超时重试最坏只是多花时间；
    # 而**限流时 Apple 的响应会变慢**，20 秒超时后直接失败太脆 ——
    # 而且超时**不是**会话过期（`isSessionExpiredError` 为假）⇒ 原先完全不重试。
    #
    # 为什么写绝对不行：`addCertificate` 的注释写明 ——「请求超时**不代表失败**：
    # Apple 可能已经建好证书、只是响应没回来；即使建好了也**拿不回来**（私钥随响应返回）
    # ⇒ **绝不盲目重试（会多占一个证书名额）**」。`updateFeatures` 同理；
    # `fetchProvisioningProfile` 内部还会先 delete，更不许重试。
    #
    # ⇒ 两侧都要钉：**读必须开**（否则限流时的慢响应直接失败），
    #   **写必须不开**（否则多占证书名额 / 重复写）。只钉一侧会绿着坏掉。
    for read_label in ('withSessionRecovery("读取 App ID 列表", retriesOnTimeout: true)',
                       'withSessionRecovery("读取证书列表", retriesOnTimeout: true)'):
        check(read_label in portal_source, "R33: 读操作必须允许重试超时：" + read_label)
    for write_label in ('withSessionRecovery("创建证书", retriesOnTimeout',
                        'withSessionRecovery("更新应用能力 \\(mappedBundleID)", retriesOnTimeout',
                        'withSessionRecovery("申请描述文件 \\(preparedAppID.mapped)", retriesOnTimeout',
                        'withSessionRecovery("创建 App ID \\(mappedBundleID)", retriesOnTimeout',
                        'withSessionRecovery("分配 App Group \\(mappedBundleID)", retriesOnTimeout'):
        check(write_label not in portal_source,
              "R33: **写操作绝不允许重试超时**（会多占证书名额 / 重复写）：" + write_label)

    # R34: 取证点 —— `fetchAppIDs` 是否回填 `features`（2026-09-18）。
    #
    # 这条诊断是「跳过冗余 `updateFeatures`」这个优化的**前置条件**。那个优化能砍掉
    # 一次抖音签名里**一半**的 Apple 请求（Phase 1 每个 bundle ID 一次 `updateFeatures`），
    # 而减少请求量正是「扩展多的 App 签不上」（Apple 限流）最直接的解法。
    #
    # 但不能盲改：`ALTAppID.features` 在本仓代码里**只被写入、从未被读取**，
    # 无法证明 `fetchAppIDs` 会填充它。若它恒为空，靠它跳过会**静默丢掉 entitlements**
    # （比现状更糟）⇒ 先取证。守卫钉住「诊断存在」且「排在 updateFeatures 之前」。
    check("App ID features 诊断：" in portal_source,
          "R34: 必须保留 `fetchAppIDs` 是否回填 `features` 的取证诊断 —— "
          "它是「跳过冗余 updateFeatures」这个减请求优化的前置条件，删了就只能盲改")
    check(0 <= portal_source.find("App ID features 诊断：")
          < portal_source.find('withSessionRecovery("更新应用能力'),
          "R34: 取证诊断必须排在 Phase 1 的 `updateFeatures` 之前（否则拿不到「复用前」的观测）")
    # ⚠️ 诊断必须**直接算出「能省多少次请求」**，而不只是「features 是不是空的」——
    # 后者不足以判断能否跳过 `updateFeatures`（前置条件是「远端 features 与本次要设置的
    # **完全一致**」，不一致时跳过会静默丢能力）。这是砍掉一半 Apple 请求的关键取证。
    # ⚠️ 2026-09-18：`desiredFeatureKeys` 的参数从 original 改为 mapped（applications 键错位
    # 修复，见 R24b）—— 修复前它恒返回空集，「能省 N 次」恒为 0，这条取证一直空转。
    check("能省 \\(skipCandidates) 次请求" in portal_source
          and "func desiredFeatureKeys(mapped: String) -> Set<String>" in portal_source,
          "R34: 取证诊断必须把「远端 features 与本次要设置一致」的**个数**算出来 —— "
          "只说「features 非空」判断不了能不能跳过 updateFeatures")
    check("guard let application = applications[mapped] else { return [] }" in portal_source,
          "R34: desiredFeatureKeys 必须用 mapped ID 查 applications（original 恒 nil，取证空转）")
    # ⚠️ 还**必须报出值类型**：判据「键集相等 ⇒ 值也相等」只在**所有值都是布尔开关**时成立。
    # 若某个能力的值是列表（App Group / Associated Domains 之类），键集相等**不代表**值相等，
    # 跳过会**静默丢掉那个能力** ⇒ 那时这条优化就**不能做**。这是能否落地的最后一块判据。
    check("desiredFeatureTypeSummary" in portal_source
          and "本次要设置的能力与值类型" in portal_source,
          "R34: 取证诊断必须报出**值类型** —— 有列表值时「键集相等」不等于「值相等」，"
          "跳过会静默丢能力，那时这条优化不能做")

    # R35: 解压**之前**按「解压后」体积判空间（2026-09-18）。
    #
    # 原先只有签名服务里那道 `IPA × 4 + 200MB`，用的是**压缩**体积。它对抖音这种
    # 「压缩比 ≈1.9×」的包偏保守（780MB ⇒ 门槛 3.32GB，实测峰值 ≈3.0GB）；
    # 但**对高压缩比的包会严重低估** —— 例：100MB 压缩 → 1.5GB 解压，
    # 实际峰值 ≈ 100 + 1500 + 100 = 1700MB，而那道门槛只有 600MB
    # ⇒ 可能在**签名中途写满磁盘**，比「直接拒绝」更糟（工作区停在半成品状态）。
    #
    # 断言三件事：① 解压总量被**返回出来**并真的用于空间判断（原先只用于 8GB 上限）；
    # ② 检查排在 `unzipItem` **之前**；③ 有独立日志码便于事后归因。
    workspace_source = strip_comments(load("Seal/Infrastructure/Signing/SigningWorkspace.swift"))
    check("try validateFreeSpace(" in workspace_source
          and 'code: "SEAL-SIGN-406"' in workspace_source,
          "R35: 解压前必须按解压后体积判空间，并给出可归因的日志码")
    check("private func validate(_ entries: [Entry]) throws -> UInt64 {" in workspace_source,
          "R35: `validate` 必须把解压后总量**返回出去** —— 原先它只用于 8GB 安全上限，"
          "没参与空间判断，所以高压缩比的包会被低估")
    check(0 <= workspace_source.find("try validateFreeSpace(")
          < workspace_source.find("try fileManager.unzipItem("),
          "R35: 空间检查必须排在 `unzipItem` **之前** —— 排在后面就变成「解压到一半没空间」")
    # ⚠️ **前置**那道检查（签名服务里、排在所有检查最前面）也必须用准确值。
    # 退回「压缩体积 × 4」会两头出错，而它排在最前面 ⇒ **错的那一头会先拦住用户**：
    # 抖音 780MB × 4 = 3.32GB（实际 ≈3.0GB）⇒ 假警报；高压缩比的包则被低估。
    check("signingWorkspace.requiredTemporarySpace(" in portal_source
          and "ipaSize * 4" not in portal_source,
          "R35: 前置的磁盘检查必须用「解压后」体积的**准确值** —— `压缩体积 × 4` 会先拦住"
          "能签的机器（假警报），或低估高压缩比的包")
    # 公式**只许一份**（本仓「同一条规则两份实现」已踩过 6 次）。
    check(workspace_source.count("static func requiredTemporarySpace(") == 1
          and workspace_source.count("multipliedReportingOverflow(by: 2)") == 1,
          "R35: 「需要多少临时空间」的公式只许有一份 —— 两处各写一遍迟早漂移")

    # R37: 判 Mach-O magic **之前不许整体读入文件**（2026-09-18，由一份第三方审计发现）。
    #
    # `rewriteExecutablePathReferences` 被 `normalizeRootFrameworksIntoFrameworksDirectory`
    # 对**全树每个文件**调用（app 根目录存在 `.framework` / `.dylib` 时才走进去；
    # **抖音正好满足** —— 3 个注入的 tweak dylib 放在 app 根）。
    # 原实现第一件事是 `Data(contentsOf:)` —— **整个文件读进内存之后**才判 magic
    # ⇒ 5053 个文件、合计 **1.46 GB** 的无谓磁盘读 + 同等量级的内存分配，
    # 其中非 Mach-O 的那绝大部分（图片 / 视频 / 字体 / `Assets.car`）**纯属浪费**。
    # 更麻烦的是**内存峰值**：单个几百 MB 的资源文件在 iOS 上有被 **jetsam 杀掉**的余地
    # —— 那会表现为「签名中途莫名失败」。
    check("guard let magicData = try? handle.read(upToCount: 4)" in workspace_source
          and 0 <= workspace_source.find("guard magic == 0xfeedfacf")
          < workspace_source.find("guard var data = try? Data(contentsOf: machOURL)"),
          "R37: 判 Mach-O magic 必须**先只读前 4 字节** —— 整体读入之后再判，会让全树遍历"
          "（5053 个文件 / 1.46 GB）把每个文件都读进内存，非 Mach-O 的那些纯属浪费，"
          "且有 jetsam 风险")

    # ⚠️ **R38 已移除**（2026-09-19）：签名器从 `Vendor/rork-sign` 换成了上游
    # `SideSign` + `CodeSignKit` ✓（用户死命令「一个代码不漏地抄」✓），
    # 而 `Seal/Infrastructure/Signing/RorkAppSigner.swift` **整个文件已删除** ✗
    # ⇒ 这条断言失去了对象 ✓。
    #
    # 🔴 **但它守的知识必须留档** ✗ —— `rork-sign` 的 `SigningCacheOptions` 是它**独有**的优化 ✓：
    # 按**内容寻址**缓存「已签名的 Mach-O」（key = 证书哈希 + entitlements 哈希 +
    # Mach-O 内容 + CD 哈希模式，**不含描述文件字节**）⇒ 续签同一个 App 时那 30 多个
    # Mach-O **全部命中** ⇒ 这正是主场景（7 天续签）省掉全部重签的杠杆 ✓。
    #
    # ⚠️ **上游 `SideSign` / `CodeSignKit` 没有签名缓存** ✗（已逐行核实 ✓）
    # ⇒ **Seal 现在每次续签都是全量重签** ✗，这直接加重了**大包**的 CPU 预算压力 ✗
    #（真机构建 147：签抖音时 90 秒 CPU / 166 秒，撞「180 秒内 50%」上限被系统杀掉 ✗）。
    # ⇒ 保留 `SigningCacheStats` 类型（恒为 `(0, 0)` ✓）**只是为了让调用方结构不变** ✓ ——
    # **它不是缓存，别再把它当缓存读** ✗。
    # ⇒ **真机回归时必须专门看**：抖音（780 MB + 8 扩展）重签耗时与 CPU 秒数 ✓。

    # R39: **每个阶段真正进入时必须落一行日志**（2026-09-18）—— 这是「分段耗时」的唯一来源。
    #
    # `SigningProgressBudget` 的 τ（每阶段时长）现在是**估的**，要靠真机日志里各阶段的
    # 时间戳差来校准；而此前 `updateSigningStage` **只改状态、一行都不落**
    # ⇒ 阶段切换在日志里没有任何时间戳 ⇒ 三条线（进度 τ 校准 / 大包耗时归因 / 请求量判据）
    # 都在等的**那份数据根本拿不到**。
    #
    # ⚠️ 且必须**只在真正的阶段切换时**记（`tick == .restart`）—— 同一阶段会被重复推送
    #（安装通道的 >1.0 哨兵 + 签名侧补发），不加闸门会刷屏（与「轮询型日志不许写」同一条理由）。
    apps_view_source = strip_comments(load("Seal/Features/Apps/AppsViewModel.swift"))
    check("阶段进入：" in apps_view_source and 'code: "SEAL-STAGE-001"' in apps_view_source,
          "R39: 阶段进入必须落日志 —— 否则「每阶段耗时」拿不到，τ 只能永远靠估，"
          "三条线都在等的数据也就永远拿不到")

    # R40: **`SEAL-AUTH-102c` 不得把账号标成「失效」**（2026-09-18 真机，构建 133）。
    #
    # 它自己的文案写着「两种常见成因：登录真的失效，**或者被 Apple 限流**」、
    # recovery 写着「**先等几分钟重试**」；而策略表把所有 `102*` 一律判成
    # `.credentialsRejected` ⇒ **立刻标失效，与那段文案直接矛盾** ✗
    #
    # 真机证据：`318***5***@qq.com` 签抖音时，紧接 **3 次限流退避重试**之后报 102c，
    # 账号随即显示「失效 + 已签名 0/10」⇒ 用户去重新验证 → 又撞限流 → **死循环**。
    # 语义上：`107`（明确会话过期）已经不标 ✓，而 `102c` 是**二义**的，更不该标 ✓。
    policy_source = strip_comments(load("Seal/Core/Accounts/AppleServiceFailurePolicy.swift"))
    check('if code == "SEAL-AUTH-102c" { return nil }' in policy_source,
          "R40: `SEAL-AUTH-102c` 不得标记账号失效 —— 它是**二义**错误（会话过期 or 限流），"
          "文案自己写着「先等几分钟重试」；标失效会让用户陷入「重新验证 → 又限流」的死循环")
    check(0 <= policy_source.find('SEAL-AUTH-102c')
          < policy_source.find('hasPrefix("SEAL-AUTH-102")'),
          "R40: `102c` 的排除必须排在 `hasPrefix(\"SEAL-AUTH-102\")` **之前** —— "
          "排在后面等于没排除")
    check('if code.hasPrefix("SEAL-AUTH-102") { return .credentialsRejected }' in policy_source,
          "R40: 其余 `102*`（尤其 `102d`：Apple **明确**拒绝凭据）**必须保持**标记失效")
    # ⚠️ 闸门**必须是 `stage != currentStage`，不能是 `tick == .restart`**
    #（2026-09-19 真机踩到 ✗）：`InstallStageTimeline.tick` 只对 **`.installing`** 返回
    # `.restart`，其余阶段一律 `.clear` —— 它是「安装计时起点」的簿记，
    # **不是**「阶段是否切换」。拿它当闸门 ⇒ **只有 `installing` 会落日志** ✗✗
    #（真机实测：整份日志只有 1 条 `SEAL-STAGE-001`，正是 `installing` ✓ 印证）。
    check(0 <= apps_view_source.find("if stage != currentStage {")
          < apps_view_source.find("阶段进入："),
          "R39: 阶段日志的闸门必须是 `stage != currentStage`（真正的阶段切换）—— "
          "同一阶段会被重复推送需要闸门，但**不能用 `tick`**：它只对 `.installing` 返回 `.restart`，"
          "用它当闸门会导致只有 installing 落日志（真机实测只有 1 条）")
    # ⚠️ 日志还必须排在 `guard signingSession != nil` **之前**（2026-09-18 真机，构建 133）。
    # 批量续签走的是 `BatchRefreshSession`，`signingSession` 可能为空 ⇒ 原来那个 guard
    # 会让整段 return、**日志一条都不落** ⇒ 实测整份日志只有 **2 条** `SEAL-STAGE-001`
    #（而且都是 `installing`）✗。而「每阶段耗时」的样本**恰恰主要来自批量续签**
    #（用户最常用的入口）⇒ 日志必须与 session 状态**解耦**。
    check(0 <= apps_view_source.find("阶段进入：")
          < apps_view_source.find("guard signingSession != nil else { return }"),
          "R39: 阶段日志必须排在 `guard signingSession != nil` **之前** —— "
          "批量续签时 `signingSession` 可能为空，排在后面会导致整段 return、"
          "日志不落（真机实测只有 2 条）")

    # R08: 日志导出的表头必须自带**构建标识**（2026-09-17 的取证教训）。
    #
    # `CURRENT_PROJECT_VERSION` 由 `Scripts/build-unsigned-ipa.sh` 取 `GITHUB_RUN_NUMBER`，
    # 所以它唯一对应一次 CI 构建、进而唯一对应一个提交。没有这一行时，
    # 「这份日志来自哪个构建」只能靠**比对日志文案的措辞**去反推 ——
    # 2026-09-17 实际踩到：一份日志的文案与当前源码不一致，顺着它去比对历史提交，
    # 才发现那份日志来自比修复更早的构建，整轮分析的前提都不成立。
    formatter_source = strip_comments(load("Seal/Core/Diagnostics/SealLogEntry.swift"))
    check("static var currentBuildLabel: String" in formatter_source
          and 'CFBundleShortVersionString' in formatter_source
          and 'CFBundleVersion' in formatter_source,
          "R08: the log header must identify the build it came from")
    check('"构建 \\(buildLabel)' in formatter_source,
          "R08: the build label must actually be rendered into the export header")
    # 真实导出路径必须**显式**透传：靠默认参数虽然也能工作，但这条依赖
    # 「日志能不能定版」，要能被源码断言看见 —— 删掉它守卫就该红。
    store_source = squash(strip_comments(load("Seal/Infrastructure/Diagnostics/SealLogStore.swift")))
    check("buildLabel: SealLogTextFormatter.currentBuildLabel" in store_source,
          "R08: the store must pass the build label through — otherwise exports silently lose it")
    # 源码断言只能证明「渲染逻辑在」，证明不了导出文本里真有这一行。
    formatter_tests = load("SealTests/Diagnostics/SealLogTextFormatterTests.swift")
    check("func storeExportIncludesBuildLabel()" in formatter_tests
          and "func buildLabelComesBeforeEntries()" in formatter_tests,
          "R08: the build label in the export needs a real unit test")

    # R09: 构造器实参顺序必须与声明顺序一致（2026-09-16 被 CI 拦下一次）。
    # 本机（Windows）没有 Swift 工具链，而 `build-package` **不编译测试 target** ——
    # 所以测试里 `AppRecord(...)` 的参数顺序写错会顺利通过 build-package，
    # 只在 `swift-regression` 红（exit 65），一轮 CI 白等 13 分钟。
    # 实际报错：error: argument 'ipaRelativePath' must precede argument 'signedArtifactStatus'
    def declared_argument_labels(path, marker):
        """从 `marker` 之后的第一个 `(` 解析出参数标签序列（marker 必须包含到 `(`）。"""
        source = strip_comments(load(path))
        at = source.find(marker)
        if at == -1:
            return []
        open_at = source.index("(", at + len(marker) - 1)
        close_at = match_paren(source, open_at)
        if close_at == -1:
            return []
        return argument_labels(source[open_at + 1:close_at])

    def call_order_errors(declared_labels, call_pattern, skip_paths=()):
        """校验 Seal/ 与 SealTests/ 下每个调用点的实参标签顺序与声明一致。

        返回 (错误列表, 实际扫到的调用点数)。**调用点数必须一并返回并断言下限**：
        本轮第一版把正则写成 `(?<![A-Za-z0-9_.])signAndInstall\\(`，而真实调用点全是
        `coordinator.signAndInstall(` —— 前一个字符是 `.`，被反向断言全部排除，
        于是「零调用点 ⇒ 零错误 ⇒ 检查通过」。守卫全绿但完全没在守卫任何东西，
        正是这个脚本注释里反复警告的「绿着坏掉」。
        """
        errors = []
        scanned = 0
        if not declared_labels:
            return errors, scanned
        for source_path in swift_sources():
            relative = source_path.relative_to(ROOT).as_posix()
            if relative in skip_paths:
                continue
            source = strip_cached(relative)
            for match in re.finditer(call_pattern, source):
                # 声明本身（`func name(`）不是调用点；否则会把参数默认值当成实参。
                if source[max(0, match.start() - 5):match.start()] == "func ":
                    continue
                call_open = match.end() - 1
                call_close = match_paren(source, call_open)
                if call_close == -1:
                    continue
                labels = argument_labels(source[call_open + 1:call_close])
                if not labels:
                    continue
                scanned += 1
                indices = [
                    declared_labels.index(label)
                    for label in labels
                    if label in declared_labels
                ]
                if len(indices) != len(labels) or indices != sorted(indices):
                    errors.append(relative + " -> " + ", ".join(labels))
        return errors, scanned

    # 同一类坑在 2026-09-16 一天内咬了两次：AppRecord（测试里）与 signAndInstall（本轮自己
    # 给批量续签加 onInstallProgress 时，把它写到了 broadcastsInstallStage 之后）。
    # 这类函数的特点：参数多、绝大多数带默认值、调用点几乎全是「省略中间几个」，
    # 于是把靠后的标签写到前面去看起来毫无违和感 —— 但 Swift 要求实参标签顺序与声明
    # 一致，直接 exit 65。校验的代价是几行 Python，收益是省掉一轮 13 分钟的 CI。
    # 每项：(名字, 声明文件, 声明锚点, 声明标签数下限, 调用点正则, 跳过文件, 调用点数下限)
    order_targets = (
        ("AppRecord", "Seal/Core/Apps/AppRecord.swift", "    init(", 30,
         r"(?<![A-Za-z0-9_.])AppRecord\(", ("Seal/Core/Apps/AppRecord.swift",), 10),
        ("signAndInstall", "Seal/Core/Signing/SigningCoordinator.swift",
         "func signAndInstall(", 10, r"(?<![A-Za-z0-9_])signAndInstall\(", (), 2),
        ("installSignedIPA", "Seal/Core/Signing/SigningCoordinator.swift",
         "private func installSignedIPA(", 7, r"(?<![A-Za-z0-9_])installSignedIPA\(", (), 2),
        ("installCachedSignedIPAIfPossible", "Seal/Core/Signing/SigningCoordinator.swift",
         "private func installCachedSignedIPAIfPossible(", 8,
         r"(?<![A-Za-z0-9_])installCachedSignedIPAIfPossible\(", (), 1),
    )
    for name, path, marker, min_declared, pattern, skips, min_sites in order_targets:
        declared_labels = declared_argument_labels(path, marker)
        check(len(declared_labels) >= min_declared,
              "R09: " + name + " must stay parseable by the guard")
        errors, sites = call_order_errors(declared_labels, pattern, skip_paths=skips)
        # 调用点数下限是防「绿着坏掉」的：正则写歪会扫到 0 个调用点，
        # 而 0 个调用点必然 0 个错误 —— 检查通过但什么都没守住（本轮实际踩到）。
        check(sites >= min_sites,
              "R09: " + name + " call sites must stay discoverable by the guard (found "
              + str(sites) + ")")
        check(not errors,
              "R09: " + name + " call-site labels must follow the declaration order ("
              + " | ".join(errors) + ")")

    # R10: 安装阶段必须「看得见、退得出」（2026-09-16 真机反馈）。
    # 现象一：单签停在 93%（= `.installing`，见 SigningProgressView.overallProgress）。
    # 现象二：批量续签抽屉停在「传输中」。
    # 两者是同一件事：上传完成（安装通道的 >1.0 哨兵）之后 installd 才真正开始安装，
    # 而安装期间**没有任何进度回报**；同时 UI 既没有说明也没有退出通道 ——
    # 抽屉在运行中隐藏了整个 footer 并禁用了下滑关闭，用户被关在一个静止弹窗里，
    # 感受就是「怎么都没反应」。
    #
    # 这些约束有个共同特征：改回旧写法**不会编译失败、也不会跑挂单测**，
    # 只会让真机重新「卡住」。所以必须由静态守卫钉住。
    bridge_source = load("Seal/Core/Signing/InstallStageBridge.swift")
    # 1.0 是「上传到 100%」，不是「开始安装」：用 >= 会让 UI 在设备还没动手时谎报安装中。
    check("uploadProgress > uploadCompletionSentinel" in bridge_source,
          "R10: 1.0 means 'upload finished', not 'installing' — the sentinel must be exclusive")
    install_signed_body = section(
        load("Seal/Core/Signing/SigningCoordinator.swift"),
        "private func installSignedIPA(",
        "private func bridgedInstallProgress("
    )
    # 两个安装分支必须对称地走同一个包装：Seal 自替换漏了会丢掉「回主页」信号，
    # 普通安装漏了则从上传完成到装完整段停在「传输中」。
    check(install_signed_body.count("bridgedInstallProgress(") >= 2,
          "R10: both install branches must bridge the upload sentinel (batch callbacks see stages only)")
    check("isSelfReplacement: false" in install_signed_body
          and "bridgedInstallProgress(" in install_signed_body.split("isSelfReplacement: false", 1)[1],
          "R10: the ordinary-app install path is the one that used to stall on '传输中'")
    bridge_helper = section(
        load("Seal/Core/Signing/SigningCoordinator.swift"),
        "private func bridgedInstallProgress(",
        "private func removeStaleProfiles("
    )
    check("InstallStageBridge.shouldEmitInstalling(" in bridge_helper
          and "await progress(.installing)" in bridge_helper,
          "R10: the bridge must actually emit .installing, not just forward the percentage")
    renewal_process = section(
        load("Seal/Core/Renewal/RenewalCoordinator.swift"),
        "private func process(",
        "static let requiresActionCode"
    )
    check("broadcastsInstallStage: true" in renewal_process,
          "R10: batch renewal must ask for the install-stage broadcast")
    check("onInstallProgress: { installProgress in" in renewal_process,
          "R10: batch renewal must subscribe to the upload percentage")
    check(".appInstallProgress(" in renewal_process,
          "R10: batch renewal must forward the real upload percentage to the drawer")
    batch_view = strip_comments(load("Seal/Features/Apps/BatchRefreshView.swift"))
    check("InstallWaitNote(startedAt:" in batch_view,
          "R10: the batch drawer must explain the install wait instead of standing still")
    check("currentInstallProgress" in batch_view,
          "R10: the batch drawer must show the real upload percentage")
    check("cancelBatchRefresh()" in batch_view,
          "R10: a running batch must expose a cancel path")
    progress_view = strip_comments(load("Seal/Features/Apps/SigningProgressView.swift"))
    check("InstallWaitNote(startedAt: session?.installStartedAt)" in progress_view,
          "R10: the single-signing sheet must explain the 93% install wait")
    check("cancelSigning()" in progress_view,
          "R10: a running signing session must expose a cancel path")
    # 运行中隐藏 footer + 禁用下滑关闭 = 弹窗内没有任何操作，用户被锁死。
    check("showsFooter: !isRunning" not in batch_view
          and "showsFooter: !isRunning" not in progress_view,
          "R10: hiding the footer while running removes the only way out of a stuck run")
    # Seal 自续签的「回主页」是 93% 的唯一出口：iOS 只有在旧进程让出前台后才完成替换。
    progress_raw = load("Seal/Features/Apps/SigningProgressView.swift")
    # 前台状态 → 动作的映射必须留在**纯函数**里：这段判断原先直接读
    # `UIApplication.shared.applicationState` 并就地 return，没有任何测试覆盖，
    # 而它的 `.inactive` 分支正是「Seal 自续签永久停在 93%」的根因（2026-09-16 真机反馈）。
    check("enum ReturnHomeStep" in progress_raw
          and "static func step(for state: UIApplication.State) -> ReturnHomeStep" in progress_raw,
          "R10: the foreground-state decision must stay a testable pure function")
    step_body = squash(strip_comments(section(
        progress_raw,
        "static func step(for state: UIApplication.State) -> ReturnHomeStep",
        "@MainActor"
    )))
    # `.inactive` 是瞬时失焦（控制中心/通知横幅/来电/App 切换器预览/系统弹窗），进程仍在前台。
    # 旧实现把它当成「用户已离开」直接 return，连 exit(0) 兜底一起跳过 ——
    # iOS 永远等不到旧进程让出前台，界面永久停在 93%（2026-09-16 真机反馈）。
    check("case .inactive: return .waitForForeground" in step_body,
          "R10: .inactive is a transient blur — returning early strands the install at 93%")
    check("case .background: return .standDown" in step_body,
          "R10: only a real background transition means the user left")
    check("@unknown default: return .waitForForeground" in step_body,
          "R10: an unknown foreground state must wait, not give up")
    return_home = squash(strip_comments(section(
        progress_raw,
        "static func returnToHomeAfterSealUpload(logStore: SealLogStore? = nil)",
        "private static func triggerHomeTransition"
    )))
    # 结构还在不等于还在用：等待循环必须真的走 step()/poll()，否则守卫守的是没人调的函数。
    #
    # 局部变量刻意叫 `currentStep`：写成 `let step = step(for:)` 会让右侧解析到尚未
    # 初始化的局部变量，直接编译失败（`use of local variable 'step' before its declaration`）。
    check("let currentStep = step(for: app.applicationState)" in return_home
          and "poll(" in return_home,
          "R10: the wait loop must route through the tested step/poll functions")
    check('await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")' in return_home
          and "try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)" in return_home,
          "R10: .inactive must actually be waited out, not merely skipped")
    # `.standDown`（用户切走了）**绝不能再「立即放弃」** —— 这是 2026-09-16 真机
    # 「续签卡在 93%」的直接原因。
    #
    # 旧实现的语义是「用户已切走了，进程已让出前台，iOS 会自己完成替换 ⇒ 返回 false、
    # 不强杀进程」。这个前提对**覆盖安装运行中的自己**不成立：iOS 需要旧进程**终止**，
    # 而后台进程不会自己终止（自续签还主动开了后台保活）。两份真机日志
    #（`Seal-log(7).txt` / `Seal-log(8).txt`）里，两次自续签都停在 93%，而进程
    # **既不转场也不退出**、照常写后台日志 —— 若 suspend 生效进程会被冻结、若 exit(0)
    # 执行进程会终止，两者都没发生，只剩「这条分支把动作丢掉了」一种解释。
    #
    # 现在断言的是**语义**：这个分支既要「等」（guard outcome == .wait + 真的 sleep），
    # 又必须在超时后 `return` 出去走 `exit(0)` 兜底。用 `section()` 切分支，不拼整句文案 ——
    # 分支里插一条日志就会让拼接式断言失效，而那种失败看着像「语义坏了」。
    #
    # ⚠️ 刻意**不**断言 `"exit(0)" in stand_down`：这段的日志文案里正好含「强制 exit(0)」
    # 字样，那是文本巧合，不是控制流。删掉真正的 `return` 时它照样通过（绿着坏掉）。
    stand_down = section(return_home, "case .standDown:", "case .waitForForeground:")
    check("guard outcome == .wait else" in stand_down
          and "return }" in stand_down
          and "try? await Task.sleep(nanoseconds: backgroundPollNanoseconds)" in stand_down,
          "R10: .standDown must wait for the user to come back, then force exit — "
          "giving up here strands the install at 93%")
    check("exit(0)" in return_home,
          "R10: the exit fallback must stay reachable on every path")
    # 轮询预算本身必须是**有界**的：无限等只是另一种形式的永久卡住。
    # `poll` 是纯函数（有单测），这里守它的形状，防止有人把某个分支改成永远 `.wait`。
    poll_body = squash(strip_comments(section(
        progress_raw,
        "static func poll(",
        "static func returnToHomeAfterSealUpload"
    )))
    check("case .triggerTransition: return .act" in poll_body,
          "R10: an active foreground must trigger the transition immediately")
    check("case .waitForForeground: return rounds < inactiveRetryLimit ? .wait : .act" in poll_body,
          "R10: the transient-blur wait must be bounded by rounds")
    check("case .standDown: return waited < backgroundWaitSeconds ? .wait : .act" in poll_body,
          "R10: the background wait must be bounded — waiting forever is another kind of freeze")
    # 预算值也要钉住：改成 0 会让转场来不及触发，改成极大等于「永远等」。
    check("private static let backgroundWaitSeconds: TimeInterval = 8" in progress_raw,
          "R10: the background wait budget must stay a concrete, small value")
    # 单测必须真的覆盖这些边界 —— 否则「测试被删空」后守卫仍然全绿。
    background_tests = load("SealTests/Apps/SelfInstallAutoBackgroundTests.swift")
    check("SelfInstallAutoBackground.poll(for: .standDown, waited: 0, rounds: 0) == .wait"
          in background_tests
          and "func everyStateEventuallyActs()" in background_tests,
          "R10: the poll boundaries must stay covered by unit tests")
    # 「回主屏」这条链路必须留下日志，而且**挂起前那条必须先落盘**。
    #
    # 2026-09-16 真机：自替换卡在 93% 时这条链路一行日志都没有，于是「转场到底有没有
    # 触发、是在 installation_proxy 返回之前还是之后触发」只能靠猜。加日志是为了让它
    # **可观测**：`安装 开始自替换安装：…` → 心跳 → `Seal 自替换：触发回主屏转场（suspend）`
    # → `安装 自替换安装调用已返回：…`。
    #
    # `suspend` 一旦生效进程即被冻结，所以「触发转场」这条**必须写在 `triggerHomeTransition`
    # 之前**，且每条都 `flush()`：顺序反了、或只 append 不 flush，下次真机排查又会退回
    # 「一片空白」—— 那正是这条缺陷最难查的地方。
    check("await store.append(category: .installation" in progress_raw
          and "await store.flush()" in progress_raw,
          "R10: the return-home path must log — silence is why the freeze was undiagnosable")
    # 断言「顺序」而不是「文案」：日志措辞可以改，但必须先落盘再挂起。
    transition_branch = section(return_home, "case .triggerTransition:", "case .standDown:")
    check("await log(logStore," in transition_branch
          and transition_branch.index("await log(logStore,")
          < transition_branch.index("triggerHomeTransition(app)"),
          "R10: the suspend log must be flushed before the process is frozen")
    # 「回主页」的触发点必须在**状态层**，不能挂在界面上。
    # 抽屉现在有「取消」按钮（软取消：立即关界面，已下发的安装由 installd 跑完），
    # 用户一旦在 Seal 安装期间点取消，SigningProgressView 就没了 ——
    # 挂在它 `.onChange` 上的触发点收不到后续阶段推进，「回主页」永远不会发生，
    # Seal 的替换**静默失败**（旧版本继续跑，用户以为更新没生效）。
    # 批量续签那条链路本来就在状态层触发（见 consumeBatchEvent），单签与它对齐。
    apps_view = squash(strip_comments(load("Seal/Features/Apps/AppsViewModel.swift")))
    check("if stage == .installing, tick == .restart, signingSession?.app.isSeal == true {"
          in apps_view,
          "R10: single signing must trigger the return-home from the state layer, once")
    # 两条链路（单签 + 批量）都必须把**真实的**日志出口交下去：
    # 只声明依赖、调用点传 nil，等于这条链路重新变回静默（下次真机又查不出卡在哪）。
    check(apps_view.count(
              "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)") == 2,
          "R10: both signing paths must trigger the return-home with a real log outlet")
    # 批量链路的「回主页」也必须带 `.restart` 闸门。`.installing` 会被重复推送
    #（安装通道的 >1.0 哨兵 + 签名侧补发），不设闸门就会排出多个任务 ——
    # 这种重复本身是良性的（第一个任务转场后进程被挂起，后续任务不执行），但**每个任务
    # 都会写一遍「上传完成 / 触发转场」日志**，把真机排查最关键的那段时序信息淹没。
    # 单签那条链路本来就有这个闸门，这里与它对齐。
    check("if stage == .installing, tick == .restart {" in apps_view,
          "R10: a repeated .installing push must not spawn a second return-home")
    # 界面自己再触发一次 = 双重「回主页」（两个系统转场 + 两个 exit(0) 兜底）。
    check("SelfInstallAutoBackground.returnToHomeAfterSealUpload" not in progress_view,
          "R10: the view must not trigger the return-home — it can be dismissed mid-install")
    # 源码断言守的是「形状」，单测守的是「行为」。`.inactive` 这条分支必须真的有单测 ——
    # 否则重构可以改掉它的返回值而守卫只看见「函数还在」（本轮把这段抽成纯函数就是为了它）。
    auto_bg_tests = load("SealTests/Apps/SelfInstallAutoBackgroundTests.swift")
    check("SelfInstallAutoBackground.step(for: .inactive) == .waitForForeground" in auto_bg_tests,
          "R10: the .inactive branch needs a real unit test, not only a source assertion")

    # R10: 安装阶段的计时起点规则（单签 / 批量）只能有一份。
    # 两处各抄一遍的漂移不会编译失败、不会跑挂单测，只会让其中一条链路的
    # 「已等待 m:ss」变成假象（永远 0:00，或带上上一项的等待时间）。
    timeline_source = strip_comments(load("Seal/Core/Signing/InstallStageTimeline.swift"))
    check("currentStage == .installing ? .keep : .restart" in timeline_source,
          "R10: repeated .installing pushes must not reset the install clock")
    for timeline_user in ("Seal/Features/Apps/AppsViewModel.swift",
                          "Seal/Core/Renewal/BatchRefreshSession.swift"):
        check("InstallStageTimeline.tick(" in strip_comments(load(timeline_user)),
              "R10: " + timeline_user + " must use the shared install-start rule")
    timeline_tests = load("SealTests/Signing/InstallStageTimelineTests.swift")
    check("InstallStageTimeline.tick(entering: .installing, currentStage: .installing) == .keep"
          in timeline_tests,
          "R10: the shared install-start rule needs a real unit test")

    # R10: 自替换安装（Seal 覆盖运行中的自己）不能「永久停在 93%」。
    #
    # 2026-09-16 真机日志给出的对照（Seal-log(7)）：
    #   16:59:06 开始安装 LiveContainer → 16:59:13「签名并安装成功」   = 7 秒
    #   16:53:57 签名产物核验通过（Seal 自替换）→ 93 秒后仍无任何安装结论，
    #            进程还活着、还在打其它后台日志，Seal 也从未被替换
    # 而旧实现的这段是裸的 `try await installation.value`：没有超时、没有日志，
    # 所以卡住时既不会结束、也查不出卡在哪。
    #
    # 这些约束改回旧写法**不会编译失败、也不会跑挂单测**，只会让真机重新永久卡住。
    #
    # 1) 自替换的等待必须带超时，且超时**只停止等待、绝不取消**底层同步 FFI：
    #    `offThread` 的默认 `cancelsWorkOnTimeout: true` 会把取消传给 Rust 侧，
    #    可能撤销已下发的 installation_proxy 命令 —— 把「可能还在装」变成「确定装不上」。
    self_replace = strip_comments(load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift"))
    check("cancelsWorkOnTimeout: false" in self_replace,
          "R10: the self-replacement wait must stop waiting without cancelling the FFI")
    # 2) 等待只允许有一处：在别处再裸等一遍 `installation.value` 等于重新引入无超时等待。
    check(self_replace.count("try await installation.value") == 1,
          "R10: installation.value may only be awaited inside the watchdog")
    check(self_replace.count("Task.detached(priority: .userInitiated)") == 1,
          "R10: the install task must be created in exactly one place (the watchdog)")
    check(self_replace.count("runSelfReplacementInstall(") == 3,
          "R10: both self-replacement branches must go through the guarded install")
    # 3) 自替换必须单飞：真机日志里 91 秒内提交了两笔，而第一笔从未返回。
    check("guard selfReplacementGate.acquire() else {" in self_replace,
          "R10: a second concurrent self-replacement install must be refused")
    check("selfReplacementGate.release(timedOut: Self.isTimeoutInstallError(error))"
          in self_replace,
          "R10: a timeout must keep the self-replacement gate closed (the FFI is still running)")
    # 4) 安装链路必须留下日志：卡住时「一片空白」本身就是最大的障碍。
    check("logStore: SealLogStore?" in self_replace
          and "await logStore.append(" in self_replace,
          "R10: the install path must log — silence is why the freeze was undiagnosable")
    check('await log("开始自替换安装：' in self_replace
          and 'await log("自替换安装调用已返回：' in self_replace,
          "R10: a self-replacement install must log both start and return")
    # 心跳必须是**共用实现**，两条路径都走它。
    # 2026-09-17 真机（构建 97）：普通安装卡了 9 分多钟，日志里从「开始安装」到
    # 用户导出日志**一行都没有** —— 因为当时心跳只加在自替换这条路径上，
    # 而这条断言也只钉住了那条路径，所以它一直是绿的（R14 补上了双路径）。
    check("private func beginInstallHeartbeat(" in self_replace
          and 'beginInstallHeartbeat("自替换安装", budget: budget)' in self_replace
          and "仍在等待：已等待" in self_replace,
          "R10: the install wait needs a heartbeat — installd reports no progress")
    # 5) 只声明可选依赖、容器不传 = 永远静默。
    #    必须限定在 installChannel 的构造段里：`logStore: logStore` 在同一个文件里
    #    也出现在 SigningCoordinator 的构造处，全局匹配会让「只改安装通道这一处」
    #    的变异检不出来（本轮实际踩到）。
    container_source = strip_comments(load("Seal/Application/AppContainer.swift"))
    channel_init = section(
        container_source,
        "let installChannel = MinimuxerInstallChannel(",
        "let operationCoordinator"
    )
    check("logStore: logStore" in channel_init,
          "R10: AppContainer must hand the install channel a real log store")
    # 6) 源码断言守「形状」，单测守「行为」：这两条新规则都容易写反，必须有单测。
    gate_tests = load("SealTests/Installation/SelfReplacementInstallGateTests.swift")
    check("func timeoutKeepsTheGateClosed()" in gate_tests,
          "R10: 'a timeout must not reopen the gate' needs a real unit test")
    hard_timeout_tests = load("SealTests/Concurrency/HardTimeoutTests.swift")
    check("func nonCancellingTimeoutLeavesTheWorkRunning()" in hard_timeout_tests,
          "R10: 'stop waiting without cancelling' needs a real unit test")

    # 模拟器切片缺符号（2026-09-16，同一类错误一天内咬了两次）。
    #
    # 症状最坑的地方是**两片 CI 一绿一红**：`build-package` 只编设备切片，永远绿；
    # 只有 `swift-regression`（模拟器切片）会红，而一轮 CI 要 13–16 分钟。第一次是
    # `diagnostic`、第二次是 `isTimeoutInstallError` —— 都是同一个形状：
    # 「定义在 `#if !targetEnvironment(simulator)` 里，却被 `#if` 之外的代码引用」。
    #
    # 检查方式：把「模拟器切片不编译」的行整段抹成空白，再看有没有**只**出现在被抹掉
    # 那部分里的顶层类型成员，出现在抹后文本中 —— 出现了，就是模拟器代码引用了它。
    simulator_leaks = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        # 先在**未去注释**的原文上做一次廉价子串判断再决定是否去注释：这个循环要
        # 跑遍 200+ 个文件、而守卫总共要把 `violations()` 跑 90 多遍，全仓只有个别
        # 文件与目标平台条件编译有关，没必要为其余文件付出去注释的代价。
        if "targetEnvironment" not in load_cached(relative):
            continue
        source = strip_cached(relative)
        kept, blanked = mask_inactive_on_simulator(source)
        if not blanked:
            continue
        kept_definitions = set(_SIMULATOR_MEMBER.findall(kept))
        lines = source.splitlines(keepends=True)
        # 重建「只保留设备专属行」的文本：非设备专属行换成等量换行，行号不变，
        # 这样 `^    ` 的锚定与真实文件一致。
        device_only = "".join(
            lines[index - 1] if index in blanked else "\n" * lines[index - 1].count("\n")
            for index in range(1, len(lines) + 1)
        )
        for match in _SIMULATOR_MEMBER.finditer(device_only):
            name = match.group(1)
            # 两片各留一份定义（模拟器桩）是合法写法，不算缺符号。
            if name in kept_definitions:
                continue
            if re.search(r"\b" + re.escape(name) + r"\b", kept):
                simulator_leaks.append(relative + " -> " + name)
    check(not simulator_leaks,
          "Simulator: device-only members must not be referenced by simulator code ("
          + " | ".join(simulator_leaks) + ")")

    # `#expect(...)` 里不能出现 mutating 方法调用（2026-09-16，紧随上一条之后踩到）。
    #
    # swift-testing 的 `#expect` 是**宏**：它把表达式重写成闭包、把子表达式绑成
    # `$0`/`$1`…，于是 mutating 成员作用在捕获值上编译不过 ——
    # `error: cannot use mutating member on immutable value: '$0' is immutable`。
    # 修法是把调用提到 `#expect` 外面（`let ok = gate.acquire(); #expect(ok)`）。
    #
    # 与上一条同样的坑：**这个错误只在 `swift-regression` 出现**（`build-package`
    # 不编译测试 target），一轮 CI 白等 13 分钟。所以必须由守卫拦。
    #
    # mutating 方法名从 `Seal/` 里现取，不写死：全仓只有个位数（`acquire` / `release` /
    # `advanceStage` / `recordInstallProgress` / 证书材料那几个），名字都很独特，
    # 按「`.名字(`」匹配不会误伤。
    mutating_names = set()
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not relative.startswith("Seal/"):
            continue
        if "mutating" not in load_cached(relative):
            continue
        mutating_names.update(
            re.findall(r"mutating\s+func\s+([A-Za-z_][A-Za-z0-9_]*)", strip_cached(relative))
        )
    check(len(mutating_names) >= 5,
          "Testing: mutating-member scan found too few names — the pattern drifted")
    mutating_call = re.compile(
        r"\.(?:" + "|".join(re.escape(name) for name in sorted(mutating_names)) + r")\s*\("
    ) if mutating_names else None
    expect_mutations = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not relative.startswith("SealTests/"):
            continue
        # 先看原文里有没有「#expect(」+ 某个 mutating 调用，再决定是否去注释。
        raw = load_cached(relative)
        if "#expect(" not in raw or mutating_call is None or mutating_call.search(raw) is None:
            continue
        source = strip_cached(relative)
        for match in re.finditer(r"#expect\(", source):
            close = match_paren(source, match.end() - 1)
            if close == -1:
                continue
            inner = source[match.end():close]
            for name in sorted(mutating_names):
                if re.search(r"\." + re.escape(name) + r"\s*\(", inner):
                    expect_mutations.append(relative + " -> " + name)
    check(not expect_mutations,
          "#expect must not call a mutating method — it is rewritten into a closure ("
          + " | ".join(expect_mutations) + ")")

    # `#expect(_:_:)` 的第二参数是 `Comment?`：**字符串字面量（含 `"\(x)"` 插值）可以，
    # `String` 变量不行**（2026-09-21 因此挂了一轮 CI，同样只在 `swift-regression` 暴露 ——
    # `build-package` 不编译测试 target，照绿）。
    #
    # `Comment` 只遵循 `ExpressibleByStringLiteral` / `ExpressibleByStringInterpolation`，
    # **没有从 `String` 的隐式转换** ⇒ 循环里想标出「是哪个键 / 哪一项失败」、
    # 顺手写成 `#expect(cond, key)` 就会报
    # `error: cannot convert value of type 'String' to expected argument type 'Comment?'`。
    # 修法是插值：`#expect(cond, "缺少 \(key) 时…")` ✓。
    #
    # 判据：`#expect(...)` 的实参**以「, 裸标识符」结尾**即为违规。只认「结尾」形态 ⇒
    # 既不误伤嵌套调用里的逗号（`#expect(State(id: "", p: "") == nil)`），
    # 也不误伤带标签参数（`#expect(x, sourceLocation: loc)` 结尾是 `: loc`，不是裸标识符）✓。
    # 加这条之前先在**全仓 1185 处 `#expect`** 上跑过一遍：**零误报** ✓。
    comment_offenders = []
    bare_comment = re.compile(r",\s*([A-Za-z_][A-Za-z0-9_]*)\s*$")
    # ⚠️ 前置过滤：**先看原文里有没有「, 标识符」**，再决定要不要去注释。
    # 这一步是**性能必需**，不是可选优化 —— 变异检查每一遍都会跑这个循环，
    # 而 `SealTests/` 里 **80 个文件**含 `#expect(`，`strip_comments` 是纯 Python
    # 字符循环（约 1–2 MB），会把守卫总时长推高 1–2 分钟，逼近命令超时（SIGTERM、
    # 且没有任何输出，极易误判成脚本崩了 —— 见下面对守卫耗时的那段注释）。
    # 实测：86 个文件 → 过滤后只剩 **6 个（66 KB）** ✓。
    # 该过滤是**可靠上界**：违规意味着实参以 `, 标识符` 结尾，后面紧跟 `)`（或行尾注释
    # 再跟 `)`）⇒ 原文里必然出现这两个形态之一（`\s` 含换行，多行写法同样命中）✓。
    raw_hint = re.compile(r",\s*[A-Za-z_][A-Za-z0-9_]*\s*(?:\)|//)")
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not relative.startswith("SealTests/"):
            continue
        raw = load_cached(relative)
        if "#expect(" not in raw or raw_hint.search(raw) is None:
            continue
        source = strip_cached(relative)
        for match in re.finditer(r"#expect\(", source):
            close = match_paren(source, match.end() - 1)
            if close == -1:
                continue
            hit = bare_comment.search(source[match.end():close])
            if hit:
                comment_offenders.append(relative + " -> " + hit.group(1))
    check(not comment_offenders,
          "#expect must not pass a bare identifier as its comment — the second parameter "
          "is `Comment?` (use an interpolated string literal instead) ("
          + " | ".join(comment_offenders) + ")")

    # `?? []` 的类型推断陷阱（2026-09-17 因此挂了一轮 CI，同样只在 `swift-regression` 暴露）。
    #
    # `Dictionary.Keys` / `Dictionary.Values` **不是** `ExpressibleByArrayLiteral`，
    # 所以 `dict.first?.keys ?? []` 里的 `[]` 无法被推断成那个类型，Swift 退化成 `[Any]`：
    #   error: cannot convert value of type '[Any]' to expected argument type
    #          'Dictionary<String, String>.Keys'
    # 正确写法：先 `guard let` 取出字典再 `Set(dict.keys)`，或用 `.map { $0 }` 显式转成数组。
    #
    # 判据（值得记住的通用形式）：**`??` 的右侧用字面量兜底时，左侧必须是可以从该字面量
    # 构造出来的类型**（`Array` / `Set` / `Dictionary` 可以，`Keys` / `Values` / 其它
    # `Collection` 不行）。
    keys_fallback_pattern = re.compile(r"\.(?:keys|values)\s*\?\?\s*\[\]")
    keys_fallback = []
    for source_path in swift_sources():
        relative = source_path.relative_to(ROOT).as_posix()
        if not (relative.startswith("Seal/") or relative.startswith("SealTests/")):
            continue
        # 廉价预筛用「坏形状」本身，不要用 `"??" in raw` —— 几乎每个 Swift 文件都含 `??`，
        # 那样每个变异遍都会去注释 200+ 文件，整轮守卫耗时翻倍（本轮实测过一次）。
        if keys_fallback_pattern.search(load_cached(relative)) is None:
            continue
        # 命中的还要确认**不在注释里**：注释里写反面示例是允许的，本轮就写了。
        for line_number, line in enumerate(strip_cached(relative).splitlines(), start=1):
            if keys_fallback_pattern.search(line):
                keys_fallback.append(f"{relative}:{line_number}")
    check(not keys_fallback,
          "`?? []` after .keys/.values cannot type-check — Dictionary.Keys is not "
          "ExpressibleByArrayLiteral, so `[]` degrades to [Any] ("
          + " | ".join(keys_fallback) + ")")

    # R04: Portal 三个服务的回调一律经 ContinuationBox 转发。裸 continuation 第二次 resume
    # 不是可捕获错误，而是 SWIFT TASK CONTINUATION MISUSE 致命崩溃（进程直接终止）。
    # AltSign 存在两条重复回调路径：「先报错、随后迟到地报成功」与「超时先到、回调才到」。
    # 2026-09-14 统一加固，22 个回调创建点全部套盒。
    box_source = load("Seal/Core/Concurrency/ContinuationBox.swift")
    check("final class ContinuationBox" in box_source and "continuation = nil" in box_source,
          "R04: ContinuationBox must clear the stored continuation on first resume")
    portal_services = ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
                       "Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
                       "Seal/Infrastructure/Signing/ApplePortalInventoryService.swift")
    raw_resume = []
    for path in portal_services:
        for line in load(path).splitlines():
            stripped = line.strip()
            if stripped.startswith("//"):
                continue
            if "Self.resume(continuation," in stripped or "continuation.resume(" in stripped:
                raw_resume.append(path + " -> " + stripped)
    check(not raw_resume,
          "R04: Portal callbacks must go through ContinuationBox (" + " | ".join(raw_resume) + ")")
    for path in portal_services:
        created = load(path).count("withCheckedThrowingContinuation")
        boxed = load(path).count("let callback = ContinuationBox(continuation)")
        check(created == boxed and created > 0,
              "R04: every continuation in " + path + " needs a ContinuationBox")

    # R04: 写 API（创建证书）超时 ≠ 失败。服务端可能已创建但响应丢失，而私钥由 AltSign 本地
    # 生成、只随响应返回 —— 响应一丢就不可恢复。必须对账后如实报告：绝不盲目重试（多占名额）、
    # 绝不自动撤销（可能撤掉正要用的证书），且「无法确认」不能当成「没有创建」。
    add_cert = section(portal, "private func addCertificate(", "enum OrphanReconciliation")
    check("isTimeoutError" in add_cert and "reconcileCertificateCreation" in add_cert,
          "R04: certificate creation timeout must reconcile instead of blindly retrying")
    check("case inconclusive" in portal and "case found(serialNumber:" in portal,
          "R04: reconciliation must distinguish unknown from not-created")

    # 日志脱敏：导出/上报的日志会离开设备。以下四类形态旧实现全都盖不住，属于真实明文外泄，
    # 2026-09-14 补齐。改脱敏器时别把这四条规则删掉或写窄。
    redactor = load("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift")
    check("redacted = redactPEMBlocks(in: redacted)" in redactor
          and "BEGIN [A-Z0-9 ]*PRIVATE KEY" in redactor,
          "Log: PEM private key blocks must be redacted as a whole")
    check("redacted = redactAuthorizationSchemes(in: redacted)" in redactor
          and "Bearer|Basic|Token|Digest" in redactor,
          "Log: credentials following an auth scheme word must be redacted")
    check('\\b"?\\s*[：:=]' in redactor,
          "Log: JSON keys are quoted, so an optional closing quote before the separator is required")

    # G（R10/R11）：缺账号不能静默省略。旧实现 `guard let accountID else { return nil }`
    # 会让「批量续签完成」掩盖「有应用根本没被处理」——用户既看不到它也不知道为什么。
    planner = load("Seal/Core/Renewal/RefreshPlanner.swift")
    planner_code = "\n".join(
        line for line in planner.splitlines() if line.strip().startswith("//") is False
    )
    check("return nil" not in planner_code,
          "G: planner must not silently drop apps without an account")
    check("state: .requiresAction" in planner and "missingAccountReason" in planner,
          "G: apps without an account must enter the queue as requiresAction with a reason")
    store = load("Seal/Infrastructure/Renewal/RefreshQueueStore.swift")
    # 2026-09-17 起签名带 `settled:`：有已定论结果的项按结果结算，不再一律降级。
    check("func recoverInterrupted(settled:" in store
          and "state == .running" in store
          and "state = .unknown" in store,
          "G: launch recovery must downgrade interrupted running items that have no "
          "result to unknown")
    check("func outstanding()" in store,
          "G: outstanding() is required so recovery never redoes completed work")
    coordinator = load("Seal/Core/Renewal/RenewalCoordinator.swift")
    check("needsAction: needsAction" in coordinator and "isBalanced" in coordinator,
          "G: batch result must count needsAction separately and expose the balance invariant")
    check("item.isExecutable" in coordinator,
          "G: requiresAction items must be counted and shown, not silently skipped")

    # F（R09）：三条安装入口必须共用同一份校验，且必须覆盖**每一个** target。
    # 只查主 target 会放过「主 profile 有效、扩展 profile 已过期」的包 ——
    # 它一路走到设备端，只换来一个 ApplicationVerificationFailed 之类的模糊错误。
    pre_install = load("Seal/Core/Signing/PreInstallValidation.swift")
    check("guard target.profileExpirationDate > now else" in pre_install
          and "for target in targets" in pre_install,
          "F: pre-install validation must check every target, not just the main one")
    check("Set(target.certificateSerialNumbers.map(" in pre_install
          and "SigningCertificateSelectionPolicy.normalizedSerialNumber" in pre_install,
          "F: certificate serial comparison must be normalized across sources")
    signing_coord = load("Seal/Core/Signing/SigningCoordinator.swift")
    check(signing_coord.count("PreInstallValidation.validate(") == 2,
          "F: both install entries must route through PreInstallValidation")

    # ── C 包（R06 检查 / 维护互斥）──────────────────────────────────────────
    # 读取路径必须是只读的：记录恢复、Seal 自注册、孤儿文件清理曾挂在 load() 里，
    # 于是「看列表」这种纯读取动作会顺手改 DB 和删文件，并与用户操作交错。
    apps_view = load("Seal/Features/Apps/AppsViewModel.swift")
    load_body = section(apps_view, "func load(force: Bool = false) async {", "func isCurrentLoad(")
    check("restoreMissingRecords" not in load_body
          and "clearOrphanedAppFiles" not in load_body
          and "ensureRegistered" not in load_body,
          "C: the app-list read path must not write records or delete files")
    check(load_body.count("await self.isCurrentLoad(generation)") >= 3,
          "C: every background write-back must be guarded by the load generation")

    job = load("Seal/Core/Maintenance/AppMaintenanceJob.swift")
    # 现在有**两处**删除步骤（孤儿文件清理、设备端旧描述文件清理），各自都要有租约复查。
    # 只写 `in job` 的话，删掉其中一处仍会被另一处掩盖 —— 守卫会变成「永远全绿」。
    check(job.count("guard gate.shouldAbort(token) == false else") >= 2,
          "C: the sweep must re-check the lease before deleting anything")
    check(job.count("gate.shouldAbort(token)") >= 4,
          "C: every maintenance stage must have an abort checkpoint")
    check("fetchAll()" in section(job, "3. 孤儿文件清理", "private static func unexpectedFailure"),
          "C: valid app ids must be re-read from the DB right before deleting")

    file_store = load("Seal/Infrastructure/Storage/AppFileStore.swift")
    sweep = section(file_store, "func clearOrphanedAppFiles(", "private static func transactionID(")
    check("liveTransactionIDs.contains(transactionID)" in sweep,
          "C: in-flight import transaction directories must never be swept")
    check("now.timeIntervalSince(modifiedAt) < minimumAge" in sweep,
          "C: freshly created directories need a grace period")

    gate = load("Seal/Core/Maintenance/MaintenanceGate.swift")
    check("beginWaiting" not in gate,
          "C: maintenance must never wait on a foreground lease")

    root_view = load("Seal/Features/Apps/AppsRootView.swift")
    maintenance_at = root_view.find("runMaintenanceIfIdle()")
    first_load_at = root_view.find("await viewModel.load()")
    check(maintenance_at != -1 and first_load_at != -1 and maintenance_at < first_load_at,
          "C: maintenance must run before the first read so recovered records are visible")

    # ── D 包（R07 自续签确认）──────────────────────────────────────────────
    # 同版本续签会换掉 profile（新 UUID、新有效期）但版本号不变 ⇒ 结算必须按 profile 身份，
    # 只比版本号会把「那次自更新其实失败了」当成成功，UI 显示一个设备上不存在的有效期。
    self_metadata = load("Seal/Core/Renewal/SelfAppMetadata.swift")
    check("provisioningProfileUUID" in self_metadata
          and "ProvisioningProfileReader().details(from:" in self_metadata,
          "D: the running bundle must expose its provisioning profile identity")
    self_registrar = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    check("reconcileSealRecordFromRunningBundleIfNeeded" in self_registrar
          and "reconcileSealRecordBindingIfNeeded" not in self_registrar,
          "D: the same-version branch must settle from the running bundle")
    same_version = section(self_registrar, "// 版本一致且文件存在", "// 版本变更或文件缺失")
    check("reconcileSealRecordFromRunningBundleIfNeeded" in same_version,
          "D: the same-version branch must reconcile from the running bundle")
    reconcile = section(
        self_registrar,
        "private func reconcileSealRecordFromRunningBundleIfNeeded(",
        "try await appStore.save(updated)"
    )
    check("if let uuid = metadata.provisioningProfileUUID," in reconcile
          and "metadata.expirationDate" in reconcile,
          "D: settlement must compare profile identity and expiry")

    # G 的 BatchRefreshResult 把 remaining 改成了计算属性，构造点必须改用 needsAction。
    # 漏改一个构造点就是编译错误（2026-09-14 真的漏了一处，CI build-package 挂掉）。
    restored_call = section(apps_view, "restored.status = .completed(.init(", ")")
    check("needsAction:" in restored_call and "remaining:" not in restored_call,
          "G: every BatchRefreshResult construction site must fill needsAction")

    # ── E 包（R08：签名产物 vs 已安装快照）──────────────────────────────────
    # UI 到期日取 `provisioningProfileExpirationDate ?? expiryDate`。签名阶段就推进顶层
    # profile 字段，安装失败/进程被杀时界面会显示设备上并不存在的日期 —— 用户以为续签成功，
    # 直到应用被吊销才发现。顶层字段必须只描述设备上正在运行的那份构建。
    apply_result = section(
        signing_coord,
        "private func applySigningResult(",
        "app.entitlementValidationStatus"
    )
    check("if advancesInstalledSnapshot {" in apply_result,
          "E: top-level profile fields must not advance before install verification")
    snapshot = load("Seal/Core/Signing/SignedArtifactSnapshot.swift")
    check("static func statusAfterSigning(" in snapshot
          and "static func advanceInstalled(" in snapshot
          and "awaitingVerification" in snapshot,
          "E: signed artifact and installed snapshot must be separated")
    # 必须排除被注释掉的调用：单纯 `in` 匹配会把 `// SignedArtifactSnapshot.advanceInstalled(`
    # 也算进去（守卫自己的变异检查抓到了这一点）。
    advance_lines = [
        line for line in signing_coord.splitlines()
        if "SignedArtifactSnapshot.advanceInstalled(" in line
        and line.strip().startswith("//") == False
    ]
    check(len(advance_lines) >= 1,
          "E: the install-verified path must advance the snapshot")

    # ── B 包（R05 安装单飞：超时不得重试）──────────────────────────────────
    # 安装 FFI 是同步阻塞、无法取消：超时只代表上层不再等待，底下那次安装很可能还在跑。
    # 重试就会在同一个 Bundle ID 上出现两个并发 installd —— 即「第二次安装」。
    install_channel = load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    install_channel_code = strip_comments(install_channel)
    # 重试循环现在**只有一份**：无进度重载已改为转发到带进度的实现。
    # 曾经是两份，规则各写一遍 —— 那正是「修了一个、漏了另一个」的来源。
    check(install_channel_code.count("if Self.isTimeoutInstallError(error) {") == 1,
          "B: the single install retry loop must treat timeout as terminal")
    # 被自替换闸门拒绝同样必须按终态处理：重试只会被同一个闸门再拒一次，
    # 而两条重试路径里的 Minimuxer.reset() / Install.resetProvider() 会把
    # **可能仍在跑的安装连接**拆掉 —— 那比不重试更糟。
    check(install_channel_code.count("if Self.isSelfReplacementBusyError(error) {") == 2,
          "B: both retry paths must treat a refused self-replacement as terminal")
    check("onProgress: { _ in }" in install_channel_code,
          "B: the no-progress install overload must delegate, not keep a second copy")
    check("error is HardTimeout.TimeoutError" in install_channel,
          "B: timeout detection must not depend on error text")

    # ── B 包（R05 · Rust 侧：RSD 创建 single-flight）───────────────────────
    # create_rppairing_rsd_connection() 是 async 的，创建期间标准库 Mutex 的锁已释放；
    # 没有门禁时两个并发调用会各自建一条隧道，后者覆盖前者 → 泄漏连接 + 设备端 RSD 状态混乱。
    rsd = load("Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs")
    check("static RSD_CREATION_GATE: OnceLock<tokio::sync::Mutex<()>>" in rsd
          and "async fn ensure_cached_rsd_connection(" in rsd,
          "B: RSD creation must be single-flight behind a creation gate")
    # 光有门禁不够：拿到门禁后必须再看一次缓存，否则只是把「两个并发创建」
    # 变成「两个顺序创建」，照样泄漏一条。用「创建调用只应有一处」来锁住这点。
    check(rsd.count("create_rppairing_rsd_connection().await?") == 1,
          "B: RSD creation must happen in exactly one place (inside the gate)")

    # ── 外围专项：更新真实性 ───────────────────────────────────────────────
    # 应用内更新是一条远程代码投递通道。browser_download_url 是不可信输入：
    # 不校验 host 就等于允许从任意域名拉 IPA；取「第一个 .ipa」则让多附件 Release
    # 的装载结果取决于 API 返回顺序 —— 「往 Release 多加一个附件」就成了投毒手法。
    update_checker = load("Seal/Infrastructure/UpdateChecker.swift")
    check("static func isTrustedDownloadURL(" in update_checker
          and "hasSuffix(\".githubusercontent.com\")" in update_checker,
          "Update: asset URLs must be pinned to GitHub over HTTPS")
    check("guard candidates.count == 1 else { return nil }" in update_checker,
          "Update: an ambiguous set of IPA assets must not yield a direct link")
    # 只校验下载域名不够：同一仓库、同一合法域名下的资产仍可被替换。
    # 必须把「API 元数据声称的版本」与「IPA 内真实版本」交叉校验。
    # 必须查比较逻辑本身：只查「函数存在/被调用」会被 return true 骗过去（变异检查当场抓到）。
    check("Version.compare(advertised, ipaVersion) == .orderedSame" in update_checker
          and "UpdateChecker.advertisedVersion(" in load("Seal/Features/UpdateNoticeView.swift"),
          "Update: the installed IPA version must be cross-checked against the advertised tag")

    # ── 外围专项：通知偏好 ─────────────────────────────────────────────────
    # leadHours 曾是个静默 no-op：getter 恒返回固定值、setter 忽略 newValue，
    # 而 init 还会无条件覆盖已存值 —— 一旦开放配置就会悄悄吞掉写入，且极难排查。
    notif_prefs = load("Seal/Core/Notifications/NotificationPreferences.swift")
    check("defaults.register(defaults:" in notif_prefs
          and "return stored > 0 ? stored : Self.fixedLeadHours" in notif_prefs,
          "Notify: lead time must read what was written and not clobber on init")

    # ── 外围专项：存储路径（符号链接逃逸）─────────────────────────────────
    # standardizedFileURL 只规范化 . / .. ，不解析 symlink：Apps/<uuid> 一旦被换成
    # 指向别处的链接，字符串前缀比较照样通过，写入就落到 Apps 之外。两侧都要解析
    # （iOS 上 Documents 本身就可能位于链接路径下，只解析一侧会得出错误结论）。
    # 明确检查两侧各自都解析：只数总数会被「另一侧还在」掩盖掉单侧退化。
    check("parent.resolvingSymlinksInPath()" in file_store
          and "candidate.resolvingSymlinksInPath()" in file_store,
          "Storage: descendant checks must resolve symlinks on both sides")

    # 证书页必须能回答「这张证书关联了哪些 App」：不能只展示截断 machineName，
    # 也不能只看顶层 serial（扩展 target 可能才有真实序列号）。
    # 「本机已安装 App」清单必须与行标签**同源**（installedAppsAssociated → associatedApps）：
    # 旧实现直接用口径更严的 affectedApps（只看顶层 serial 且要求 state == .installed），
    # 于是同一张证书会出现「行标签说本机已安装 App 在用、下面清单却说暂无」的自相矛盾，
    # Seal 自身（belongsInInstalledList 恒为真）也会被漏掉。撤销影响评估仍必须走 affectedApps。
    cert_impact = load("Seal/Core/Signing/CertificateRevocationImpact.swift")
    cert_view = load("Seal/Features/Settings/SigningCertificateSettingsView.swift")
    check("static func associatedApps(" in cert_impact
          and "app.signingTargets.contains" in cert_impact,
          "Certificates: association lookup must include extension targets")
    check("static func affectedApps(" in cert_impact
          and "static func installedAppsAssociated(" in cert_impact
          and "associatedApps(serialNumber: serialNumber, apps: apps)" in cert_impact,
          "Certificates: the installed-app list must reuse the association rule, not the stricter revocation-impact rule")
    check("installedAppsSection(account: account)" in cert_view
          and "CertificateRevocationImpact.installedAppsAssociated(" in cert_view
          and "本机已安装 App" in cert_view
          and "fullSerialText(certificate.serialNumber)" in cert_view,
          "Certificates: UI must show full identity and associated apps")
    signing_service = load("Seal/Infrastructure/Signing/ApplePortalSigningService.swift")
    # ⚠️ **2026-09-19 改**：原来是「**预判性轮换**（免费团队 + 门户已有证书 ⇒ 先撤销 ✗）
    # **或** 撞 3022 后轮换」两条并存 —— 但它的文案本来就写的是 **or** ✓。
    # 对照上游 SideStore 的 `CertificateProvisioningFlow` 后改成**只走后者** ✓：
    #     复用活跃证书 → 不行 ⇒ **直接创建** → 只有创建失败才进 `replaceCertificate`（撤销 → 再创建）
    # 理由：Seal 的「不可用」是**本地判断**（无本机私钥 / 剩余不足 7 天），
    # 可能比 Apple 的判定**更悲观** ✗ ⇒ 预判性撤销会**白撤一张本来还能用的证书** ✗✗。
    # **自动撤销能力保留** ✓（撞 3022 后仍由 `rotateCertificatesAndCreateIdentity` 撤销 + 重建）。
    # ⚠️ 断言用**带 ` {` 的形式**：文件里 `SEAL-CERT-204b` 出现两次 ——
    # 1210 是**外层触发点**（有 ` {`），1278 是轮换循环内部（没有）。
    # 只写前半段会被 1278 匹配上，变异（改掉 1210）就抓不住了 ✗。
    check('} catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b" {' in signing_service
          and "rotationCandidates(" in signing_service,
          "Certificates: unusable/stale bindings must rotate after exact 3022 (create first, revoke only on 3022)")
    settings = load("Seal/Features/Settings/SettingsViewModel.swift")
    check("let expirationDate = portalPresence == .invalid" in settings,
          "Certificates: revoked remote certificates must not show stale local expiry")
    check("func importSigningCertificate(from sourceURL: URL" not in settings,
          "Certificates: P12 backup import entry must be removed (one cert per Apple ID)")
    account_secret = load("Seal/Core/Accounts/AccountSecret.swift")
    check("certificateP12BySerial[oldKey] = oldP12" in account_secret,
          "Certificates: creating a new certificate must not discard older local P12 material")
    reuse_section = section(signing_service, "// 根治「创建新证书覆盖旧 P12」的问题", "// 运行包证书只用于安排轮换顺序")
    check("for remote in certificates" in reuse_section
          and "SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: remote.serialNumber)" in reuse_section
          and "Self.certificateReusable(local)" in reuse_section,
          "Certificates: signing must reuse any stored P12 whose remote certificate is still active")
    check("isCertificateImporterPresented" not in cert_view
          and "从 P12 备份恢复本机私钥" not in cert_view,
          "Certificates: UI must not expose P12 recovery (removed, one cert per Apple ID)")
    check("revokeCertificate(serialNumber:" in cert_view
          and "nonLocalCertificates" in cert_view
          and "CertificateRevocationImpact.isLocalCertificate(" in cert_view,
          "Certificates: manual revoke must be gated to non-local certificates")

    # Fast IPA 的产物由 build-unsigned-ipa.sh 按版本命名为 Seal_<version>.ipa。
    # 验证/上传若退回旧的 Seal.ipa 固定名，会在编译成功后误报文件不存在。
    ios_fast = load(".github/workflows/ios-fast.yml")
    check("bash Scripts/verify-ipa.sh build/Seal_*.ipa" in ios_fast
          and "build/Seal_*.ipa.sha256" in ios_fast
          and "build/Seal.ipa" not in ios_fast,
          "CI: Fast IPA verification and upload must use the versioned artifact name")

    # ensure-rustbridge 以 xcframework 内的 .source-fingerprint 判定能否复用。
    # 只缓存 target/ 会让每个新 runner 都因指纹缺失而重建并扫描整个静态库。
    rust_cache_inputs = (
        load(".github/workflows/ios.yml"),
        load(".github/workflows/ios-release.yml"),
        ios_fast,
    )
    check(all("Vendor/Minimuxer/RustBridge/lib/RustBridge.xcframework" in workflow
              and "'Vendor/Minimuxer/RustBridge/src/**'" in workflow
              for workflow in rust_cache_inputs),
          "CI: every iOS Rust cache must preserve the matched xcframework and key it by Rust sources")

    # ── 外围专项：供应链（GitHub Action 必须钉到 commit SHA）──────────────
    # actions/cache@v5 这类浮动 major tag 可以被上游移动指向任意代码 ——
    # 只要上游账号或仓库被入侵，CI 就会执行攻击者的代码，并拿到发布用的凭据。
    # 必须钉到 40 位 commit SHA（保留 `# v5` 注释便于人读与 Dependabot 识别）。
    # 注意：@v6.0.2 这种精确到 patch 的标签不在禁止之列（风险远低于 @vN）。
    floating_actions = []
    for name in ("ios.yml", "ios-release.yml", "ios-fast.yml", "pairing-assistant.yml"):
        for line in load(".github/workflows/" + name).splitlines():
            stripped = line.strip()
            if not stripped.startswith("uses:") or "@" not in stripped:
                continue
            ref = stripped.split("@", 1)[1].strip().split()[0]
            if ref.startswith("v") and ref.count(".") == 0:
                floating_actions.append(name + " -> " + stripped)
    check(not floating_actions,
          "Supply chain: GitHub Actions must be pinned to a commit SHA ("
          + " | ".join(floating_actions) + ")")

    parser = load("Seal/Core/Import/IPAParserService.swift")
    check("nestedData" not in parser and 'code: "SEAL-IPA-101b"' in parser,
          "Import: nested wrappers must not be buffered or committed as inner IPAs")
    validator = load("Seal/Infrastructure/Installation/SignedArtifactValidator.swift")
    check('guard let executableName = plist["CFBundleExecutable"]' in validator
          and "$0.uncompressedSize > 0" in validator,
          "R12: executable declaration and nonempty file must be required")
    operation = load("Seal/Application/OperationCoordinator.swift")
    check("guard Task.isCancelled == false else { return nil }" in operation,
          "Operation: cancelled waiters must not acquire a lease")
    apps = load("Seal/Features/Apps/AppsViewModel.swift")
    retry = section(apps, "func refreshFailedItems()", "func cancelBatchRefresh()")
    check("startBatchRefresh()" not in retry,
          "R10: failed-only retry must never silently rerun every app")

    # 证书页允许手动撤销「非本机在用」证书（真实永久删除），但不提供批量清理入口。
    # 撤销必须被 `nonLocalCertificates` 用 `CertificateRevocationImpact.isLocalCertificate`
    # 挡在本机在用证书之外（误删本机在用证书会让签名身份失效，2026-09-14 真机踩到）。
    ui = load("Seal/Features/Settings/SigningCertificateSettingsView.swift")
    check("prepareCertificateCleanup" not in ui,
          "Copy: certificate page must not expose batch cleanup entry")
    check("nonLocalCertificates(account: account)" in ui
          and "CertificateRevocationImpact.isLocalCertificate(" in ui,
          "Copy: manual revoke must exclude the local in-use certificate")

    # 证书清理（一个 Apple ID 本机只留一张可用证书）：
    # 撤销不可逆，候选判定与执行各有硬约束。
    cleanup_policy = load("Seal/Core/Signing/CertificateCleanupPolicy.swift")
    check("if normalizedLocalUsable.contains(serial)" in cleanup_policy,
          "Cleanup: keyful check must use normalized serial set")
    inspector = load("Seal/Infrastructure/Installation/DeviceProfileInspector.swift")
    check("removeProvisioningProfile" not in inspector,
          "Cleanup: device profile inspection must be read-only")
    check("return parsed > 0 ? serials : nil" in inspector,
          "Cleanup: unparseable dump must mean unverified, not empty")
    settings_vm = load("Seal/Features/Settings/SettingsViewModel.swift")
    cleanup_exec = section(settings_vm, "func executeCertificateCleanup(",
                           "private func persistCreatedCertificate(")
    check("fetchInventory" in cleanup_exec and "freshPlan.revocable.filter" in cleanup_exec,
          "Cleanup: revoke must re-verify against a fresh remote listing")
    check(cleanup_exec.index("createLocalCertificate") > cleanup_exec.index("for certificate in targets"),
          "Cleanup: revoke all before creating the replacement")
    inv = load("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift")
    check("hasLocalPrivateKey: localP12SerialNumbers.contains(" in inv,
          "Cleanup: hasLocalPrivateKey must consider every stored P12, not only the current one")

    # 签名/续签中的孤儿证书自动清理：撤销不可逆，约束必须硬守护。
    coord = load("Seal/Core/Signing/SigningCoordinator.swift")
    check("SEAL-CERT-204a" in coord and "SEAL-CERT-204c" in coord and "SEAL-CERT-204d" in coord,
          "Auto-cleanup: trigger must cover quota, missing-key and stale-binding errors only")
    # 名额满有两条平行归类路径（204a 文案归类 / 204b isCertificateLimitError 归类），
    # 漏挂 204b 会让真机撞上限时无感清理完全不触发（2026-09-14 真机踩到）。
    trigger_fn = section(coord, "static func isOrphanCertificateBlocking", "\n    }")
    check('failure.code == "SEAL-CERT-204b"' in trigger_fn,
          "Auto-cleanup: trigger must also cover SEAL-CERT-204b (isCertificateLimitError path)")
    check("let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()" in coord,
          "Auto-cleanup: must consult device profile inspector")
    auto_cleanup = section(coord, "private func autoCleanOrphanCertificatesIfPossible(",
                           "func installSignedArtifact(")
    check("guard let inventory = try? await inventoryService.fetchInventory(" in auto_cleanup,
          "Auto-cleanup: decisions must use a fresh remote listing, never cache")
    check("guard plan.revocable.isEmpty == false else {" in auto_cleanup
          and "guard revokedSerials.isEmpty == false else {" in auto_cleanup,
          "Auto-cleanup: bail out when nothing was or could be revoked")
    cleanup_retry = section(coord,
                            "catch let failure as ImportFailure where Self.isOrphanCertificateBlocking",
                            "account.certificateSerialNumber = portalResult.certificateSerialNumber")
    check("selectedCertificateSerialNumber: nil" in cleanup_retry,
          "Auto-cleanup: retry must drop the revoked binding")

    # Seal 自保护（前置清理绝不碰 Seal 真实签名证书）：
    # 签其他 App 时前置清理如果撤了 Seal 的真实签名证书（比如覆盖安装 keychain 丢私钥后，
    # Seal 正用一张无私钥证书跑着），Seal 下次启动就「不再可用」直接变砖。
    # makePlan 必须只认真实 CMS 签名者（sealActualSignerSerialNumber + identityConfidence），
    # 真实签名者读不出来时整份计划必须 blocked（一张都不撤）。
    check("sealActualSignerSerialNumber" in cleanup_policy
          and "identityConfidence" in cleanup_policy
          and "static func blocked(reason: String)" in cleanup_policy
          and "serial == normalizedSealSigner" in cleanup_policy,
          "Seal self-protection: makePlan must protect the actual CMS signer and block when unknown")
    check("installedIdentity" in auto_cleanup
          and "sealActualSignerSerialNumber: sealActualSigner" in auto_cleanup,
          "Seal self-protection: auto cleanup must pass Seal's actual signer from installedIdentity")

    # Seal 自保护（注册/结算时只能以运行包主程序的真实 CMS 签名者为准）：
    # 描述文件授权证书列表不等于实际签名者；身份读取失败时保留既有记录，
    # 绝不回退到 profile 授权列表（2026-09-15 真机确认误撤会变砖）。
    registrar = load("Seal/Core/Renewal/SelfAppRegistrar.swift")
    check("metadata.installedIdentity?.mainTarget?.signerSerialNumber" in registrar
          and "metadata.certificateSerialNumbers.first" not in registrar,
          "Seal self-protection: registrar must use the actual CMS signer, never the profile-authorized list")
    metadata = load("Seal/Core/Renewal/SelfAppMetadata.swift")
    check("certificateSerialNumbers: profileDetails?.certificateSerialNumbers" in metadata,
          "Seal self-protection: SelfAppMetadata must read certificateSerialNumbers from profile")

    # Seal 自保护（所有证书清理路径都必须只相信真实 CMS 签名者）：
    # 描述文件授权列表可能包含并未实际签名的证书，DB 记录可能是旧值；
    # 两处协调器路径（前置清理 / 一键全撤）与设置页两处路径（分析 / 执行）
    # 都必须从 installedIdentity 读真实签名者，且身份不完整时整体停止。
    check("SelfAppMetadata.current()?.installedIdentity" in coord
          and "runningIdentity?.isComplete == true" in coord,
          "Seal self-protection: coordinator paths must read the actual CMS signer identity")
    check("SelfAppMetadata.current()?.installedIdentity" in settings_vm
          and "runningIdentity?.isComplete == true" in settings_vm,
          "Seal self-protection: settings paths must read the actual CMS signer identity")
    # 一键全撤路径（revokeKeylessCertificatesAfterConfirmation）身份不可读时必须拒绝撤销。
    revoke_keyless = section(coord, "func revokeKeylessCertificatesAfterConfirmation(",
                             "private func autoCleanOrphanCertificatesIfPossible(")
    check("SelfAppMetadata.current()?.installedIdentity" in revoke_keyless
          and "SEAL-CERT-230" in revoke_keyless,
          "Seal self-protection: revoke keyless must stop when the actual signer is unreadable")
    # 危险推断已被根除：描述文件授权列表首项 / 运行包授权集合不得再用于保护决策。
    for path in ("Seal/Core/Signing/SigningCoordinator.swift",
                 "Seal/Features/Settings/SettingsViewModel.swift",
                 "Seal/Infrastructure/Signing/ApplePortalSigningService.swift"):
        text = load(path)
        check("SelfAppMetadata.current()?.certificateSerialNumbers.first" not in text
              and "runningSealSerials" not in text,
              f"Seal self-protection: profile-based signer inference must be gone in {path}")
    # 接管决策：空槽位直接建、满槽位只能请求撤销非 A 候选、签名者未知一律阻断。
    takeover = load("Seal/Core/Signing/CertificateTakeoverPolicy.swift")
    check("case reuseLocal(serialNumber: String)" in takeover
          and "case createLocal" in takeover
          and "case requestRevocation(candidateSerialNumbers: [String])" in takeover
          and "case blocked(reason: String)" in takeover
          and "guard identityComplete," in takeover
          and "remoteSerialNumbers.filter { normalize($0) != protected }" in takeover,
          "Takeover: decision policy must cover reuse/create/requestRevocation/blocked and never offer A")
    # 手动撤销（证书页逐张撤销）必须先挡住真实签名者 A；身份不可读时拒绝一切撤销。
    check("CertificateRevocationImpact.isActualSealSigner(" in settings_vm
          and "SEAL-CERT-230a" in settings_vm,
          "Seal self-protection: manual revoke must refuse the actual Seal signer")

    # 自续签事务化结构断言：旧 handoff 模式必须绝迹，单次提交与真实身份读取必须在场。
    forbidden_patterns = {
        "Seal/Core/Signing/SigningCoordinator.swift": [
            "for attempt in 1...2",
            "recoverPendingSelfReplacement",
        ],
        "Seal/Core/Renewal/SelfAppRegistrar.swift": [
            "pendingSelfReplacementRecovery",
            "claimAutomaticRecovery",
        ],
    }
    for path, patterns in forbidden_patterns.items():
        text = load(path)
        for pattern in patterns:
            check(pattern not in text,
                  f"Transaction: forbidden legacy pattern '{pattern}' must be gone in {path}")
    required_patterns = {
        "Seal/Core/Renewal/SelfReplacementTransactionStore.swift": [
            "claimSubmission",
            "alreadySubmitted",
        ],
        "Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift": [
            "checkMachOCodeSignatures",
            "signerNotAuthorizedByProfile",
        ],
    }
    for path, patterns in required_patterns.items():
        text = load(path)
        for pattern in patterns:
            check(pattern in text,
                  f"Transaction: required pattern '{pattern}' missing in {path}")

    # 一键确认盘活（SEAL-CERT-204e）：在用的无钥匙证书绝不静默撤，必须经失败页确认。
    check("if case .blockedByInUseKeylessCerts" in cleanup_retry,
          "204e must surface when keyless certificates are still in use")
    # Seal 自身续签绝不撤自己的证书（会立刻打不开，2026-09-14 真机踩到）。两道护栏：
    # ① 命中「在用的无钥匙证书」时不抛 204e，回退原错误；② 一键全撤跳过 Seal 在用的证书。
    check("if app.isSeal {" in cleanup_retry,
          "Seal self-renewal must never surface 204e (revoke makes Seal unlaunchable)")
    check("sealProtectedSerials" in coord and "sealProtectedSerials.contains" in coord,
          "Sacrifice: one-tap full revoke must skip Seal's own in-use certificate")
    check("func revokeKeylessCertificatesAfterConfirmation(" in coord,
          "Sacrifice: coordinator must expose the confirmation-gated revoke entry")
    check("SEAL-CERT-204e" in coord and "SEAL-CERT-204f" in coord,
          "Sacrifice: error codes 204e/204f must stay unique and present")
    check("CertificateCleanupPolicy.sacrificeCandidates(" in coord,
          "Sacrifice: candidates must come from the shared policy")
    apps_vm = load("Seal/Features/Apps/AppsViewModel.swift")
    check("func confirmCertificateSacrificeAndRetry()" in apps_vm
          and 'failure.code == "SEAL-CERT-204e"' in apps_vm,
          "Sacrifice: ViewModel one-tap entry must be gated on the 204e failure")
    check("resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)" in apps_vm,
          "Sacrifice: affected installed apps must be re-signed after the retry succeeds")
    progress_view = load("Seal/Features/Apps/SigningProgressView.swift")
    check('"撤销并继续签名"' in progress_view
          and "viewModel.confirmCertificateSacrificeAndRetry()" in progress_view,
          "Sacrifice: failure page must wire the one-tap button to the ViewModel")

    # 证书回收已收敛为无感自动清理 + 204e 一键确认；证书页只读，不再提供手动撤销入口。
    # 任何 recovery 文案都不许再引导用户「去撤销证书」（那是死链接），唯一允许保留的
    # 「撤销」措辞是 204e 失败页的「撤销并继续签名」（有真实按钮，见 SigningProgressView）。
    manual_revoke_copy = []
    for path in ("Seal/Core/Signing/SigningCoordinator.swift",
                 "Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
                 "Seal/Infrastructure/Signing/ApplePortalSigningService.swift"):
        for line in load(path).splitlines():
            if "recovery:" in line and "撤销" in line and "撤销并继续签名" not in line:
                manual_revoke_copy.append(path + " -> " + line.strip())
    check(not manual_revoke_copy,
          "Copy: recovery must not instruct manual certificate revocation ("
          + " | ".join(manual_revoke_copy) + ")")

    versions = re.findall(r"MARKETING_VERSION:\s*(\S+)", load("project.yml"))
    check(len(versions) == 1,
          "Release: Seal must declare a single MARKETING_VERSION (no extension target)")
    for workflow in ("ios.yml", "ios-release.yml"):
        text = load(".github/workflows/" + workflow)
        check("inputs.publish_release == true" in text
              and re.search(r"publish_release:[\s\S]*?default: false", text) is not None,
              workflow + ": publishing must be explicit and default off")
        check(re.search(r"\n  publish-release:[\s\S]{0,600}?\n    if: github\.event_name == 'workflow_dispatch'",
                        text) is not None,
              workflow + ": publish job must stay gated to workflow_dispatch (never run on push)")
        check('${TAG#v}' in text and '!= "$VER"' in text,
              workflow + ": release tag must match built IPA version")

    # UI 回归已从 build-package 拆成独立的 swift-regression job。它一旦脱离发布依赖，
    # 发布就可能在回归尚未跑完时把包发出去。测试失败原因必须能直接看到（GitHub 原始日志要登录，
    # 注解不用），否则只会留下「exit 65」这种无法定位的失败。
    ios = load(".github/workflows/ios.yml")
    check(re.search(r"\n  publish-release:[\s\S]{0,600}?\n    needs: \[[^\]]*swift-regression", ios) is not None,
          "ios.yml: publish must wait for the swift-regression gate")
    check("tee build/TestLog.txt" in ios and "::error::" in ios,
          "ios.yml: test failures must be surfaced as annotations")

    # 任何构建 App 的 job 都必须先跑 ensure-rustbridge.sh：本仓允许预编译 RustBridge.xcframework
    # 落后于 Rust 源码（脚本按源码指纹当场重编）。漏跑就会链接到缺符号的旧库，
    # 报一堆 `_rust_bridge_*` undefined symbols —— 2026-09-14 拆分 job 时真实踩到。
    check("ensure-rustbridge.sh" in section(ios, "\n  build-package:", "\n  swift-regression:"),
          "ios.yml: build-package must run ensure-rustbridge.sh")
    check("ensure-rustbridge.sh" in section(ios, "\n  swift-regression:", "\n  signer-tests:"),
          "ios.yml: swift-regression must run ensure-rustbridge.sh")
    # ⚠️ **区段止标记是 `\n  signer-tests:`** ✗ —— 本 job 2026-09-19 由 `rork-sign-tests`
    # **改名而来** ✓（签名器换成上游 `SideSign` + `CodeSignKit` 后，
    # `Vendor/rork-sign` 整个目录已删除 ✗）。改 job 名时**必须同步改这里**，
    # 否则 `section()` 找不到标记 ⇒ 整轮守卫**带 Python 栈崩掉** ✗（R09c 同款）。
    check("\n  signer-tests:" in ios,
          "R56: `ios.yml` 必须保留**签名内核的独立回归门**（`signer-tests`）✗ —— "
          "它测的是上游 `CodeSignKit`（Mach-O 签名 / CodeDirectory / CodeResources / "
          "签名校验 ✓）；删掉它等于「换签名器之后没有任何回归网」✗")
    check("working-directory: Vendor/CodeSignKit" in ios
          and "working-directory: Vendor/rork-sign" not in ios
          and "working-directory: Vendor/SideSign" not in ios,
          "R56: `signer-tests` 必须真的测**签名内核 `Vendor/CodeSignKit`** ✗ —— "
          "只留 job 名而把 `working-directory` 指回已删的 `Vendor/rork-sign` 是最坏情况"
          "（名字看着还在、其实什么都没测 ✗）。"
          "⚠️ **不测 `Vendor/SideSign`** ✓（2026-09-20）：它的测试**上游自己就编译不过** ✓"
          "（缺 `import Foundation` ✓），且剩下的用例只测 `Device` 模型与 `Archive` 往返，"
          "而 Seal **完全不用 `SideSign.Archive`** ✓ ⇒ 零价值 ✓")

    # R61: **就绪探测不许用 15 秒的设备轮询预算**（2026-09-20 真机，构建 184）✗
    #
    # 症状：iOS 17.0–17.3.1（lockdown 路径）配对后界面停在「验证中」**十几分钟**
    # 没有任何结论（真机日志：12 分钟后既无成功行、也无失败行）—— 用户会直接判成死机 ✗。
    #
    # 根因：`MinimuxerInstallChannel.diagnose()` 的设备探测是 `for attempt in 0..<36`
    # ＋ 500ms 睡眠（**设计意图 = 给 RSD 握手约 18 秒**），但每轮里的
    # `Minimuxer.ready()` / `fetchUDIDDetailed()` 都要走 `Device.getFirstDevice()`，
    # 而它默认轮询 `deviceFetchTimeoutMs`（**15 秒**）才抛 `NoDevice`
    # ⇒ 36 轮 × 15 秒 ≈ **9 分钟**（两个调用都轮询则 ≈18 分钟）；
    # 而且**设备不可达时每轮都走满** —— 最坏路径恰好是最常见的那条 ✗✗。
    #
    # ⇒ 四条判据，缺一不可：
    #   ① 存在**专用**的短预算常量且 ≤ 2000ms；
    #   ② `getFirstDevice` 可**显式传预算**（默认值仍必须是 15 秒 —— 一次性路径要用它）；
    #   ③ `ready()` 与 `fetchUDIDDetailed()` 两个探测点都**显式**传短预算；
    #   ④ `ready()` 里**便宜判据在前**：`getFirstDevice()` 必须出现在那个逻辑与 guard
    #      **之后**（原实现无条件先跑它 ⇒ 隧道没通时每轮白等 15 秒 ✗）。
    #
    # ⚠️ **只查「传了短预算」会被骗** ✗：把上游写法（无条件先 `getFirstDevice()`）
    # 和短预算**同时**留在文件里，③ 照样绿，而每轮仍然白等 15 秒 ✓
    # ⇒ ④ 必须按**下标顺序**判 ✓（变异锚点就改这个顺序 ✓）。
    probe_budget_match = re.search(
        r"public static let probeDeviceFetchTimeoutMs: UInt16 = (\d+)",
        load("Vendor/Minimuxer/Sources/Constants.swift"),
    )
    minimuxer_source = load("Vendor/Minimuxer/Sources/Minimuxer.swift")
    ready_body = squash(section_or_empty(
        minimuxer_source,
        "public static func ready() -> Bool {",
        "public static func setDebug(",
    ))
    detailed_body = squash(section_or_empty(
        minimuxer_source,
        "public static func fetchUDIDDetailed() throws -> String {",
        "public static func testDeviceConnection(",
    ))
    cheap_guard = ("guard deviceConnection, Heartbeat.lastBeatSuccessful, "
                   "Muxer.started, Muxer.usbmuxdReady else")
    probe_call = "try Device.getFirstDevice(timeoutMs: MuxerConstants.probeDeviceFetchTimeoutMs)"
    check(probe_budget_match is not None and int(probe_budget_match.group(1)) <= 2000,
          "R61①: 必须有**专用**的探测预算 `probeDeviceFetchTimeoutMs` 且 ≤ 2000ms ✗ —— "
          "就绪探测不负责等待，等待由外层那 36 轮重试负责 ✓")
    check("timeoutMs: UInt16 = MuxerConstants.deviceFetchTimeoutMs"
          in squash(load("Vendor/Minimuxer/Sources/Device.swift")),
          "R61②: `getFirstDevice` 必须可**显式传预算**，且默认仍是 15 秒 ✗ —— "
          "一次性路径（dump / 安装 / DDI / JIT）没有外层重试，多等是对的 ✓")
    check(probe_call in ready_body and probe_call in detailed_body,
          "R61③: `ready()` / `fetchUDIDDetailed()` 必须显式传**短预算** ✗ —— "
          "它们在 36 轮探测循环里，用默认的 15 秒会让最坏路径变成十几分钟 ✗")
    cheap_at = ready_body.find(cheap_guard)
    check(cheap_at >= 0 and ready_body.find(probe_call) > cheap_at,
          "R61④: `ready()` 里便宜判据必须在 `getFirstDevice()` **之前** ✗ —— "
          "无条件先跑它会让「设备不可达」这条最坏路径每轮白等 15 秒（36 轮 ≈ 9 分钟）✗")

    # R62: iOS 17.0–17.3.1 只支持 Lockdown。这个分支的三个必要条件必须同时存在：
    # ① 文件中是可 pair-verify 的完整 Lockdown 身份，而非只有 UDID 的占位 plist；
    # ② Device/RustAfc/RustInstProxy 指向 Seal 自己监听的 usbmuxd socket；
    # ③ 安装不能误走只接受 RPPairing/RSD 的 Rust 合并入口，而要 AFC + instproxy。
    pairing_store_source = strip_comments(load("Seal/Infrastructure/Pairing/PairingStore.swift"))
    pairing_tests = load("SealTests/Pairing/PairingStoreTests.swift")
    check("static func isCompleteLockdownPairing" in pairing_store_source
          and all(key in pairing_store_source for key in (
              "HostID", "SystemBUID", "HostCertificate", "HostPrivateKey",
              "RootCertificate", "RootPrivateKey"
          ))
          and "func rejectsIncompleteLockdownPairingBeforeRuntimeValidation()" in pairing_tests,
          "R62①: Lockdown 导入必须拒绝缺 pair-verify 身份材料的占位文件")
    muxer_source = strip_comments(load("Vendor/Minimuxer/Sources/Muxer.swift"))
    lockdown_start = section_or_empty(
        muxer_source,
        "if remotePairing {",
        "print(\"[minimuxer] minimuxer has started!\")"
    )
    retarget_at = lockdown_start.find("retargetUsbmuxdAddr()")
    listener_at = lockdown_start.find("Thread.detachNewThread { listenLoop")
    check(retarget_at >= 0 and listener_at > retarget_at,
          "R62②: Lockdown 启动必须先把 USBMUXD_SOCKET_ADDRESS 指向本地监听器")
    channel_source = strip_comments(load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift"))
    transport_body = section_or_empty(
        channel_source,
        "private func installIPAUsingActivePairingTransport(",
        "actor MinimuxerInstallChannel: InstallChannel"
    )
    check("switch pairingInstallTransport(isRemotePairing: Minimuxer.isRemotePairing)" in transport_body
          and "case .remotePairing:" in transport_body
          and "Minimuxer.stageAndInstall" in transport_body
          and "case .lockdown:" in transport_body
          and "Minimuxer.yeetAppAfc" in transport_body
          and "Minimuxer.installIpa" in transport_body
          and "func installationTransportFollowsPairingFileType()" in load("SealTests/Installation/InstallChannelDiagnosticClassificationTests.swift"),
          "R62③: 安装必须按配对类型分流；Lockdown 不得调用 RSD 合并安装入口")

    # R63: `Minimuxer.reset()` 里「清 RSD 缓存连接」的判据必须在 `Muxer.reset()` **之前**读
    #（2026-09-21 审计发现）✗。
    #
    # 旧实现写成 `Muxer.reset()` 之后 `if Muxer.isrppairing { RustIdevice.invalidateConnection() }`
    # ⇒ **恒为假**：`Muxer.reset()` 内部的 `teardownLocked()` 已经把 `_isrppairing` 清成
    # `false`，之后再问只能是 false ✗ ⇒ 这条恢复手段**从未执行过**。
    #
    # 后果正是本仓三处注释反复记着的那个失败模式：`Install.resetProvider()` 只清 Swift 侧
    # 对象、**清不掉 Rust 的会话缓存** ⇒ 重试一直复用同一条死连接 ⇒ 真机表现为
    # 「安装静默卡住」（2026-09-17 那 9 分多钟的形态之一）✗。
    #
    # ⚠️ 光断言「有 invalidateConnection」不够 ✗ —— 旧代码也有它，只是永远走不到。
    # ⇒ 必须按**下标顺序**判：读取点要在 `Muxer.reset()` 之前 ✓（R61④ 同款手法）。
    reset_body = squash(section_or_empty(
        strip_comments(minimuxer_source),
        "public static func reset() {",
        "public static func retargetUsbmuxdAddr()",
    ))
    reset_read_at = reset_body.find("let wasRemotePairing = Muxer.isrppairing")
    reset_call_at = reset_body.find("Muxer.reset()")
    check(reset_read_at >= 0
          and reset_call_at > reset_read_at
          and "if wasRemotePairing {" in reset_body
          and "if Muxer.isrppairing {" not in reset_body,
          "R63: 「清 RSD 缓存连接」的判据必须在 `Muxer.reset()` **之前**读 ✗ —— "
          "`Muxer.reset()` 会把 remotePairing 清成 false，之后再问恒为假 ⇒ "
          "`RustIdevice.invalidateConnection()` 永远不执行，重试一直复用死连接 ✗")

    # R65: `SC_Info`（FairPlay DRM 元数据）必须**整目录递归删**，不许回到
    # 「按 Manifest.plist 里的键逐条过滤」那种枚举式修补（2026-09-21）。
    #
    # 真机闭环（构建 184，源阅读）：`SC_Info/Manifest.plist` 登记的 root sinf 路径越界
    # ⇒ installd 报 `ApplicationSINFCaptureFailed (Root sinf URL points outside of bundle)`
    # 拒绝安装；而图标**已经**注册给 SpringBoard 且失败路径不回收
    # ⇒ 用户看到「桌面有图标、点开无反应」✗。
    #
    # ⚠️ 旧实现（已删）找的是 `SinfOptions` / `SinfIDs` 两个键，而真实 Manifest.plist
    # 只有 `SinfPaths` / `SinfReplicationPaths` ⇒ `as? [String: Any]` 恒 nil ⇒
    # `changed` 恒 false ⇒ **一个字节都没写过**（代码在、注释在、行为不在）✗✗。
    # 上游 AltStore/SideStore 逐字相同、只处理 `SinfReplicationPaths`，**不碰 `SinfPaths`**
    # —— 而错误说的正是 "**Root** sinf" ⇒ **照抄上游也解决不了** ✗。
    signing_ws = strip_comments(load("Seal/Infrastructure/Signing/SigningWorkspace.swift"))
    check("static func drmMetadataDirectories(in appURL: URL) -> [URL]" in signing_ws,
          "R65: SC_Info 清理必须抽成可单测的 `drmMetadataDirectories(in:)` ✗ —— "
          "`private` 在 `@testable import` 下不可见，写成 private 就测不到")
    check("for case let url as URL in enumerator where url.lastPathComponent == \"SC_Info\"" in signing_ws,
          "R65: 必须**递归**枚举找 SC_Info ✗ —— 嵌套 bundle（Frameworks/*.framework、"
          "PlugIns/*.appex）里也有，只删 app 根目录那一个会漏掉大多数引用")
    check("enumerator.skipDescendants()" in signing_ws,
          "R65: 命中 SC_Info 后要 `skipDescendants()` ✗ —— 它的子目录（Manifest.plist 等）"
          "没有继续遍历的价值")
    check("try removeDRMMetadata(in: appURL)" in signing_ws,
          "R65: `prepare` 阶段必须调用 `removeDRMMetadata` ✗ —— 函数定义了没人调，"
          "等于原地留下第二份「写了但没生效」")
    check("SinfOptions" not in signing_ws and "SinfIDs" not in signing_ws,
          "R65: 不许回到按 `SinfOptions`/`SinfIDs` 逐条过滤 ✗ —— 真实 Manifest.plist "
          "没有这两个键（实测只有 SinfPaths/SinfReplicationPaths），会**静默空转**")

    # R66: 「确定性安装拒绝」与「最终归类」两张词表必须同时认得 `sinf`（2026-09-21）。
    #
    # 真机（构建 184）：`ApplicationSINFCaptureFailed` 被判成「可重试」
    # ⇒ 28.7 MB 的包**白传 3 轮**（日志里 `第 1/3 次 → 2/3 次 → 3/3 次`），
    # 违反「确定性拒绝必须立即终止」。同一份 IPA 必然同错，重传毫无意义 ✗。
    # 两张表还要各司其职：前者决定**要不要重传**，后者决定**给用户什么动作** ——
    # sinf 的恢复动作是「重新砸壳导出」，与「免费账号 3 应用上限」完全不同，
    # 混进同一个分支会把用户引向换账号 / 卸载 App 这些**无效**操作 ✗。
    install_channel = strip_comments(
        load("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift")
    )
    terminal_body = section_or_empty(
        install_channel,
        "static func isTerminalInstallError(",
        "private static func isTimeoutInstallError("
    )
    check('|| lower.contains("sinf")' in terminal_body,
          "R66: `isTerminalInstallError` 必须把 sinf 判为确定性拒绝 ✗ —— "
          "否则同一份包会被白传 3 轮")
    check('if lower.contains("sinf") {' in install_channel,
          "R66: `installationFailure` 必须有 sinf 专属分支 ✗ —— "
          "落到「免费账号 3 应用上限」那条会给用户无效指引")
    check('code: "SEAL-INSTALL-702f"' in install_channel,
          "R66: sinf 分支必须带专属码 `SEAL-INSTALL-702f` ✗ —— "
          "并在 `InstallFailureActionPolicy.acknowledgeCodes` 里登记为「不重试」")

    # R67: 「未砸壳的加密 IPA」必须在**导入期**拒绝，不许降级成一条可忽略的警告（2026-09-21）。
    #
    # 闭环链条：`cryptid != 0`（App Store 加密版）⇒ 重签会换掉整个签名，而 FairPlay 的
    # 解密密钥与原签名绑定 ⇒ 装上了也**启动即闪退**（`set_code_unprotect() error 7`）。
    # 让用户走完「导入 → 签名 → 安装 → 闪退」再回头找原因，等于白折腾一轮真机 ✗ ——
    # 与安装侧那条「确定性拒绝必须立即终止」（R66）同源。
    #
    # ⚠️ 此前的实现**只 `warnings.append`**，而
    # `docs/qa/2026-09-18-signing-coverage-gap-report.md` 里却写着「**导入时就拦**」
    # ⇒ **文档与代码不符** ✗。本次让代码追上文档。
    # ⚠️ 删警告时的陷阱：只删 `if` 而留着那句 `warnings.append`（或反之）会留下
    # **永远不会触发的死警告** ＝ 又一处「代码在、行为不在」✗ ⇒ 必须整段移除并钉住。
    import_service = strip_comments(load("Seal/Core/Import/IPAParserService.swift"))
    check('code: "SEAL-IPA-107"' in import_service,
          "R67: 未砸壳的加密 IPA 必须在导入期拒绝并带专属码 `SEAL-IPA-107` ✗ —— "
          "只发警告会让用户走完签名 → 安装 → 闪退")
    check('title: "IPA 未砸壳（App Store 加密版）"' in import_service,
          "R67: 拒绝文案必须点明「未砸壳」✗ —— 用户要知道下一步是砸壳，而不是换个包再试")
    check("主二进制已加密（App Store 版本），需要砸壳后才能签名" not in import_service,
          "R67: `detectImportWarnings` 里那条加密警告必须删掉 ✗ —— 拒绝路径已经拦下，"
          "留着它就是**永远不会触发的死警告**（又一处「代码在、行为不在」）")
    check(import_service.count("isEncryptedBinary(appRoot:") == 1,
          "R67: `isEncryptedBinary` 只应保留**拒绝路径**这一个调用点 ✗ —— "
          "多处调用会让「拦不拦」取决于哪一处先跑")

    # R68: 最低支持版本必须统一为 iOS 16.0，六处声明一处都不许漏回 17.0（2026-09-21）。
    #
    # 背景：`9fed6f3`（2026-09-12）曾把最低版本提到 17，理由是「iOS 16 及以下设备无 RSD 服务，
    # 无法无线配对且安装链路（Minimuxer 硬编码 RSD）不可用」—— 而后来的 `6d990e4` 补上了
    # Lockdown 安装（AFC + instproxy），且 iOS 16 与 17.0–17.3.1 **走同一条 Lockdown 路**
    # （`Muxer.start` 只看配对文件有没有 `private_key`/`UDID`，零版本判断）
    # ⇒ 该理由**已过期** ⇒ 恢复 16.0。
    #
    # ⚠️ 为什么必须钉住**每一处**，而不是「文件里出现过 16.0」：
    #   部署目标分散在 **1 个 xcconfig + 5 个 project.yml 声明**上（options 全局 ＋ 4 个 target），
    #   漏掉任意一处 ⇒ 那个 target 仍按 17.0 编译 ⇒ **装到 iOS 16 设备上起不来** ✗。
    #   而本机**无 Swift 工具链**，这类问题只能靠云 CI 暴露 ⇒ 守卫是唯一能提前拦住的地方 ✓。
    #   ⚠️ `Config/Base.xcconfig` 那一处**最容易漏** —— 只 grep `project.yml` 会少数一处 ✗。
    #
    # ⚠️ 为什么用「计数 ＋ 禁 17.0」而不是逐个 target 切块：
    #   `section()` 的止标记若是 `\n  ` 这种短前缀，会被 target 内部 4 空格缩进的行误命中
    #   ⇒ 切出来的块是空的 ⇒ 断言退化成「整段里有没有这个串」✗（正是「取函数体只能用
    #   section()、且标记要能限定范围」那条坑）。计数式断言对「删掉一个 target」同样会红
    #   （4 → 3）✓，且不依赖缩进形状 ✓。
    base_xcconfig = load("Config/Base.xcconfig")
    check("IPHONEOS_DEPLOYMENT_TARGET = 16.0" in base_xcconfig,
          "R68: `Config/Base.xcconfig` 的 `IPHONEOS_DEPLOYMENT_TARGET` 必须是 16.0 ✗ —— "
          "Debug/Release 两个配置都 `#include` 它，漏了这处两个配置会一起按 17.0 编")
    project_yml = load("project.yml")
    check('deploymentTarget:\n    iOS: "16.0"' in project_yml,
          "R68: `project.yml` 的 `options.deploymentTarget.iOS` 必须是 16.0 ✗ —— "
          "它是全部 target 的默认值")
    check(project_yml.count('deploymentTarget: "16.0"') == 4,
          "R68: `project.yml` 里 4 个 target（Seal / DeviceSupport / SealTests / SealUITests）"
          "的部署目标必须**都是** 16.0 ✗ —— 漏一个，那个 target 就装不上 iOS 16；"
          "新增或删除 target 时请同步这个数字")
    check('"17.0"' not in project_yml,
          "R68: `project.yml` 里不许再出现 17.0 ✗ —— 恢复 iOS 16 支持后，"
          "任何一处 17.0 都会让对应 target 在 iOS 16 设备上装不上")

    # R69: 配对助手的「按设备版本分流」必须**两侧同时**钉住 iOS 16（2026-09-21）。
    #
    # 助手对 iOS 16 的行为是「本机配对（Lockdown）＋ 照常生成配对文件」—— 这一条
    # **没有任何真机验证记录**（iOS 17.0–17.3.1 已验、16 未验）⇒ 只能靠判据钉住。
    #
    # ⚠️ 为什么必须是**两处**：`patch_upstream.py` 的 `verify()` 与
    # `.github/workflows/pairing-assistant.yml` 的 `required` 清单是**两道互相独立**的闸门。
    # 只留 patch 那一道 = **自洽判据** —— 实现与判据一起被改掉照样绿 ✗（R60b 的教训）。
    # ⚠️ 而且**这两道闸门在本分支（`fix/**`）上都不会自动跑** ——
    # `pairing-assistant.yml` 的 `on.push.branches` 只有 `main` 与 `feature/**`
    # ⇒ **守卫这一条是唯一会在本分支上跑的那道** ✓。
    #
    # ⚠️ 标记必须是**短片段**：workflow 那份清单跑在 `cargo fmt --all` **之后**，
    # 长表达式被 rustfmt 折行会**误判为缺失** ⇒ 白烧一轮 CI ✗。
    # 这里选的 `seal_ios_supports_remote_pairing("16.0")`（约 42 字符）与
    # `seal_mode_for_ios("16.0", PairingMode::RemotePairing)`（约 54 字符）都远低于
    # rustfmt 默认 `max_width = 100`，不会被折 ✓。
    assistant_markers = (
        'seal_ios_supports_remote_pairing("16.0")',
        'seal_mode_for_ios("16.0", PairingMode::RemotePairing)',
    )
    assistant_patch = load("Tools/SealPairingAssistant/patch_upstream.py")
    for marker in assistant_markers:
        check(marker in assistant_patch,
              "R69: `patch_upstream.py` 注入的 Rust 单测必须覆盖 iOS 16 ✗（缺 `"
              + marker + "`）—— 助手对 iOS 16 没有真机验证记录，判据是唯一的凭证")
    assistant_workflow = load(".github/workflows/pairing-assistant.yml")
    for marker in assistant_markers:
        check(marker in assistant_workflow,
              "R69: 助手 workflow 的 `required` 清单必须**独立**钉住 iOS 16 ✗（缺 `"
              + marker + "`）—— 只留 `patch_upstream.py` 那一道就是自洽判据，"
              "实现与判据一起被改掉照样绿")

    handoff_failures = HANDOFF_GUARD["violations"](load)
    checks += 6
    failures.extend(handoff_failures)
    return checks, failures

def main():
    # 基准内容缓存：见下面变异循环处的说明。整轮里源文件不会变，只有被替换的那个
    # 走闭包里的 `changed`，所以这个缓存不会让变异检查读到陈旧文本。
    base_cache = {}

    def base_read(path):
        if path not in base_cache:
            base_cache[path] = read(path)
        return base_cache[path]

    count, failures = violations(base_read)
    # Mutation checks prove the key deletion guards actually reject their old patterns.
    mutations = [
        ("Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs",
         "    let candidates = install_candidates(bundle_id, file_name);",
         "    let _ = inst_client.uninstall(bundle_id, None).await;\n    let candidates = install_candidates(bundle_id, file_name);",
         "R01:"),
        ("Seal/Core/Signing/SigningCoordinator.swift", "        var updated = app\n",
         "        var updated = app\n        // InstalledAppDeviceVerifier.isInstalled\n", "R02:"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "            try await persistRevokedSigningMaterial(updatedSecret, [candidate.serialNumber])\n            await diagnostic(\"证书轮换：已撤销",
         "            // revoked state persistence removed\n            await diagnostic(\"证书轮换：已撤销", "R03:"),
        (".github/workflows/ios.yml",
         "if: github.event_name == 'workflow_dispatch' && inputs.publish_release == true",
         "if: inputs.publish_release == true",
         "ios.yml: publish job"),
        (".github/workflows/ios.yml",
         "needs: [build-package, signer-tests, swift-regression]",
         "needs: [build-package, signer-tests]",
         "ios.yml: publish must wait"),
        (".github/workflows/ios.yml",
         "run: bash Scripts/ensure-rustbridge.sh",
         "run: echo skipped",
         "ios.yml: build-package must run ensure-rustbridge"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "return try await HardTimeout.run(seconds: TimeInterval(seconds), operation)",
         "return try await withThrowingTaskGroup(of: T.self) { group in try await group.next()! }",
         "R04: withAppleTimeout must use HardTimeout"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "callback.resume(returning: LegacyBox(teams))",
         "continuation.resume(returning: LegacyBox(teams))",
         "R04: Portal callbacks must go through ContinuationBox"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "let callback = ContinuationBox(continuation)",
         "let callback = (continuation)",
         "R04: every continuation in"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "guard Self.isTimeoutError(error) else { throw error }",
         "guard false else { throw error }",
         "R04: certificate creation timeout"),
        ("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift",
         "redacted = redactPEMBlocks(in: redacted)",
         "",
         "Log: PEM private key blocks"),
        ("Seal/Core/Renewal/RefreshPlanner.swift",
         "state: .requiresAction,",
         "state: .pending,",
         "G: apps without an account must enter the queue"),
        ("Seal/Infrastructure/Renewal/RefreshQueueStore.swift",
         "items[index].state = .unknown",
         "items[index].state = .completed",
         "G: launch recovery must downgrade"),
        ("Seal/Core/Signing/PreInstallValidation.swift",
         "guard target.profileExpirationDate > now else",
         "guard true else",
         "F: pre-install validation must check every target"),
        ("Seal/Core/Signing/PreInstallValidation.swift",
         "Set(target.certificateSerialNumbers.map(",
         "Set(target.certificateSerialNumbers",
         "F: certificate serial comparison"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if case .rejected = PreInstallValidation.validate(",
         "if false {",
         "F: both install entries"),
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         'recovery: "请在「我的」中重新同步证书状态后重试"',
         'recovery: "在「我的」页面撤销一个旧签名证书后重试"',
         "Copy: recovery must not instruct manual certificate revocation"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard gate.shouldAbort(token) == false else",
         "guard true else",
         "C: the sweep must re-check the lease"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "liveTransactionIDs.contains(transactionID)",
         "false",
         "C: in-flight import transaction directories"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "now.timeIntervalSince(modifiedAt) < minimumAge",
         "false",
         "C: freshly created directories need a grace period"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "await self.isCurrentLoad(generation)",
         "true",
         "C: every background write-back must be guarded"),
        ("Seal/Features/Apps/AppsRootView.swift",
         "await viewModel.runMaintenanceIfIdle()",
         "",
         "C: maintenance must run before the first read"),
        ("Seal/Core/Renewal/SelfAppMetadata.swift",
         "ProvisioningProfileReader().details(from:",
         "ProvisioningProfileReader().summary(from:",
         "D: the running bundle must expose its provisioning profile identity"),
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "// 后者是 R07：同版本续签会换掉 profile 但版本号不变，只比版本就会漏掉结算。\n            try await reconcileSealRecordFromRunningBundleIfNeeded(",
         "// 后者是 R07\n            try await cleanupDuplicateSealRecords(",
         "D: the same-version branch must reconcile"),
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "if let uuid = metadata.provisioningProfileUUID,",
         "if let uuid = existing.provisioningProfileUUID,",
         "D: settlement must compare profile identity and expiry"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "needsAction: max(0, total - succeeded - failed)",
         "remaining: max(0, total - succeeded - failed)",
         "G: every BatchRefreshResult construction site"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if advancesInstalledSnapshot {",
         "if true {",
         "E: top-level profile fields must not advance"),
        ("Seal/Core/Signing/SignedArtifactSnapshot.swift",
         "return isSeal ? .installed : .awaitingVerification",
         "return .installed",
         "E: signed artifact and installed snapshot must be separated"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "SignedArtifactSnapshot.advanceInstalled(",
         "// SignedArtifactSnapshot.advanceInstalled(",
         "E: the install-verified path must advance the snapshot"),
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "if Self.isTimeoutInstallError(error) {",
         "if false {",
         "B: the single install retry loop must treat timeout as terminal"),
        # 去掉「被闸门拒绝 = 终态」：重试会 reset 掉可能仍在跑的安装连接，
        # 把第一笔安装彻底弄坏（比不重试更糟）。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                if Self.isSelfReplacementBusyError(error) {\n                    throw error\n                }\n",
         "",
         "B: both retry paths must treat a refused self-replacement as terminal"),
        ("Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs",
         "ensure_cached_rsd_connection().await?;",
         "create_rppairing_rsd_connection().await?;",
         "B: RSD creation must happen in exactly one place"),
        ("Seal/Infrastructure/UpdateChecker.swift",
         "guard candidates.count == 1 else { return nil }",
         "guard candidates.isEmpty == false else { return nil }",
         "Update: an ambiguous set of IPA assets"),
        ("Seal/Infrastructure/UpdateChecker.swift",
         "Version.compare(advertised, ipaVersion) == .orderedSame",
         "true",
         "Update: the installed IPA version must be cross-checked"),
        ("Seal/Core/Notifications/NotificationPreferences.swift",
         "return stored > 0 ? stored : Self.fixedLeadHours",
         "return Self.fixedLeadHours",
         "Notify: lead time must read what was written"),
        ("Seal/Infrastructure/Storage/AppFileStore.swift",
         "candidate.resolvingSymlinksInPath().standardizedFileURL.path",
         "candidate.standardizedFileURL.path",
         "Storage: descendant checks must resolve symlinks"),
        ("Seal/Core/Signing/CertificateRevocationImpact.swift",
         "return app.signingTargets.contains { signingTarget in",
         "return false // extension association removed",
         "Certificates: association lookup must include extension targets"),
        ("Seal/Features/Settings/SigningCertificateSettingsView.swift",
         "CertificateRevocationImpact.installedAppsAssociated(",
         "CertificateRevocationImpact.installedAppsAssociatedUnused(",
         "Certificates: UI must show full identity and associated apps"),
        ("Seal/Core/Signing/CertificateRevocationImpact.swift",
         "associatedApps(serialNumber: serialNumber, apps: apps)",
         "apps.filter { _ in false }",
         "Certificates: the installed-app list must reuse the association rule"),
        # 2026-09-19：改成「先创建、撞 3022 才撤销」后，变异锚点移到 **3022 兜底**上 ✓
        #（关掉它 ⇒ 账号满时不再轮换 ⇒ 断言必须红 ✓）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '} catch let failure as ImportFailure where failure.code == "SEAL-CERT-204b" {',
         "} catch let failure as ImportFailure where false {",
         "Certificates: unusable/stale bindings must rotate after exact 3022 (create first, revoke only on 3022)"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "let expirationDate = portalPresence == .invalid",
         "let expirationDate = false",
         "Certificates: revoked remote certificates must not show stale local expiry"),
        ("Seal/Features/Settings/SigningCertificateSettingsView.swift",
         "CertificateRevocationImpact.isLocalCertificate(",
         "true // ",
         "Copy: manual revoke must exclude the local in-use certificate"),
        ("Seal/Core/Accounts/AccountSecret.swift",
         "certificateP12BySerial[oldKey] = oldP12",
         "certificateP12BySerial.removeValue(forKey: oldKey)",
         "Certificates: creating a new certificate must not discard older local P12 material"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "for remote in certificates {\n            guard let local = SigningCertificateMaterialPolicy.availableCertificate(secret: secret, serialNumber: remote.serialNumber),\n                  Self.certificateReusable(local) else { continue }",
         "if false {",
         "Certificates: signing must reuse any stored P12 whose remote certificate is still active"),
        (".github/workflows/ios.yml",
         "uses: actions/cache@caa296126883cff596d87d8935842f9db880ef25 # v5",
         "uses: actions/cache@v5",
         "Supply chain: GitHub Actions must be pinned"),
        ("Seal/Core/Signing/CertificateCleanupPolicy.swift",
         "if normalizedLocalUsable.contains(serial)",
         "if localUsableSerials.contains(serial) // ",
         "Cleanup: keyful check must use normalized serial set"),
        ("Seal/Infrastructure/Installation/DeviceProfileInspector.swift",
         "return parsed > 0 ? serials : nil",
         "return serials",
         "Cleanup: unparseable dump"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "let targets = freshPlan.revocable.filter {",
         "let targets = plan.revocable.filter {",
         "Cleanup: revoke must re-verify"),
        ("Seal/Infrastructure/Signing/ApplePortalInventoryService.swift",
         "hasLocalPrivateKey: localP12SerialNumbers.contains(",
         "hasLocalPrivateKey: false // ",
         "Cleanup: hasLocalPrivateKey"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "let deviceReferenced = await DeviceProfileInspector.referencedCertificateSerials()",
         "let deviceReferenced: Set<String>? = nil // ",
         "Auto-cleanup: must consult device profile inspector"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                    selectedCertificateSerialNumber: nil,\n                    allowDroppingExtensions: allowDroppingExtensions,",
         "                    selectedCertificateSerialNumber: effectiveCertificateSerialNumber,\n                    allowDroppingExtensions: allowDroppingExtensions,",
         "Auto-cleanup: retry must drop the revoked binding"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "if case .blockedByInUseKeylessCerts(let appNames, let deviceOnlyCount) = cleanupOutcome {",
         "if false { // blocked in-use keyless certs no longer surface 204e ",
         "204e must surface when keyless certificates are still in use"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "resignAppsAffectedByCertificateSacrificeIfNeeded(signingSucceeded: signingSucceeded)",
         "// affected apps left dead after certificate sacrifice",
         "Sacrifice: affected installed apps must be re-signed after the retry succeeds"),
    ]
    mutations += [
        # R67: 换掉专属码 ⇒ 导入期的拒绝失去可检索标识（用户/日志都对不上号）✓ 报红。
        ("Seal/Core/Import/IPAParserService.swift",
         '                code: "SEAL-IPA-107"\n            )',
         '                code: "SEAL-IPA-999"\n            )',
         "R67: 未砸壳的加密 IPA 必须在导入期拒绝并带专属码"),
        # R67: 把那条死警告加回 `detectImportWarnings` ⇒ 拒绝路径之外又留一份「看着在管、
        #      其实永远不会触发」的代码，「代码在、行为不在」重演 ✓ 报红。
        ("Seal/Core/Import/IPAParserService.swift",
         "        // 检测 Watch app（免费账号不支持）",
         "        if isEncryptedBinary(appRoot: appRoot, entries: entries, archive: archive) {\n"
         "            warnings.append(\"主二进制已加密（App Store 版本），需要砸壳后才能签名\")\n"
         "        }\n"
         "        // 检测 Watch app（免费账号不支持）",
         "R67: `detectImportWarnings` 里那条加密警告必须删掉"),
        # R65: 把「递归删所有 SC_Info」退回「只删 app 根目录那一个」——
        # 嵌套 bundle（Frameworks/PlugIns）里的 SC_Info 会留下来，真机上仍然装不上。
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "        for case let url as URL in enumerator where url.lastPathComponent == \"SC_Info\" {\n"
         "            directories.append(url)\n"
         "            enumerator.skipDescendants()\n"
         "        }",
         "        let root = appURL.appendingPathComponent(\"SC_Info\")\n"
         "        if FileManager.default.fileExists(atPath: root.path) { directories.append(root) }",
         "R65:"),
        # R66: 删掉确定性拒绝那一侧的 sinf ⇒ 28.7 MB 的包又会被白传 3 轮。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            || lower.contains(\"sinf\")\n",
         "",
         "R66:"),
        ("Seal/Infrastructure/Pairing/PairingStore.swift",
         '"HostCertificate", "HostPrivateKey", "RootCertificate", "RootPrivateKey"',
         '"HostCertificate", "RootCertificate"',
         "R62①:"),
        ("Vendor/Minimuxer/Sources/Muxer.swift",
         "                retargetUsbmuxdAddr()\n                Thread.detachNewThread { listenLoop(generation: startGeneration) }",
         "                Thread.detachNewThread { listenLoop(generation: startGeneration) }",
         "R62②:"),
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "    case .lockdown:\n        try Minimuxer.yeetAppAfc(bundleId: bundleID, ipaBytes: ipaData)\n        progress(1.0)\n        try Minimuxer.installIpa(bundleId: bundleID)",
         "    case .lockdown:\n        try Minimuxer.stageAndInstall(bundleId: bundleID, ipaBytes: ipaData, progress: progress)",
         "R62③:"),
        ("Vendor/Minimuxer/Sources/Minimuxer.swift",
         "        let wasRemotePairing = Muxer.isrppairing\n        Muxer.reset()",
         "        Muxer.reset()\n        let wasRemotePairing = Muxer.isrppairing",
         "R63:"),
        ("Vendor/Minimuxer/Sources/Minimuxer.swift",
         "        if wasRemotePairing {",
         "        if Muxer.isrppairing {",
         "R63:"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "CertificateRequestFailurePolicy.requestFailure", "LegacyCertificateFailure.requestFailure",
         "both certificate creation paths must use the shared error policy"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "selfReplacement.prepare(", "selfReplacement.skippedPrepare(",
         "a self replacement transaction must persist"),
        ("Seal/Features/Settings/SettingsViewModel.swift",
         "preservingSigningMaterial(from:", "discardingSigningMaterial(from:",
         "reauthentication must retain historical P12 material"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "    await AppleRequestThrottle.shared.wait()\n", "",
         "R05: every Apple request must pass through the throttle"),
        # ⚠️ 2026-09-18 更新到新形状：判据已挪进 `let retryable = …`，
        # 旧的 `guard Self.isSessionExpiredError(error) else` 锚点已不存在。
        # 改成「用裸错误码替代共用判据」——同样能证明断言会红。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                let retryable = Self.isSessionExpiredError(error)\n"
         "                    || (retriesOnTimeout && Self.isTimeoutError(error))",
         "                let retryable = (error as NSError).code == 1100\n"
         "                    || (retriesOnTimeout && Self.isTimeoutError(error))",
         "R05: 1100 must back off and retry"),
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            await self.installChannel?.clearFailureCooldown()\n            self.beginSigningChannel()\n            await self.runBatchRefresh(appIDs: appIDs)",
         "            guard await self.refreshSigningChannel() else { return }\n            await self.runBatchRefresh(appIDs: appIDs)",
         "R06: batch renewal must not block"),
        ("Seal/Core/Installation/InstallChannel.swift",
         "    func clearFailureCooldown() async\n    func pushIpa",
         "    func pushIpa",
         "R06: clearFailureCooldown must be a protocol requirement"),
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        UIControl().sendAction(selector, to: app, for: nil)\n    }",
         "        return UIControl().sendAction(selector, to: app, for: nil)\n    }",
         "R07: UIControl.sendAction returns Void"),
        ("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift",
         "for entry in archive where isInstalledAppProvision(entry.path) {",
         "for entry in archive where isMainProvision(entry.path) {",
         "R08: cleanup must know every installed profile"),
        ("Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift",
         'return container.hasSuffix(".app") || container.hasSuffix(".appex")',
         'return container.hasSuffix(".app")',
         "R08: extensions are .appex"),
        # 把 keep-map 命中改成「恒真 + keeping 为空」⇒ 每个 profile 的 UUID 都 ≠ ""，
        # 于是**全部**被当成旧份删掉，包括正在用的那一份（App 立刻起不来）。
        # 2026-09-17 重构成两段式后锚点跟着改：原来那行 `guard let keepingUUID = ...` 已不存在。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "            if let keepingUUID = keepingByBundleID[loweredBundleID] {",
         "            let keepingUUID = keepingByBundleID[loweredBundleID] ?? \"\"\n            if true {",
         "R08: a profile may only be deleted after its managed bundle-id lookup succeeded"),
        # 把 dump 重试次数改回 1：撞上瞬时 NoDevice 就整轮白丢 —— 原样重演 2026-09-16 真机
        # 的 `扫描 0，匹配 0，删除 0，中断于 dump`，而 profile 在此期间继续累积。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "    private static let dumpAttemptLimit = 3",
         "    private static let dumpAttemptLimit = 1",
         "R08: a transient NoDevice must not throw away the whole cleanup round"),
        # 重试前不重置 provider：三条重试全走同一条已经断开的 RSD 连接，等于没重试
        #（循环还在、次数还在，约束已经失效）。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "                Provision.resetProvider()\n"
         "                try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)",
         "                try? await Task.sleep(nanoseconds: dumpRetryDelayNanoseconds)",
         "R08: retrying the dump without resetting the cached provider retries the same dead link"),
        # 绕过带重试的包装、直接调 FFI：重试形同虚设，函数与单测都还在。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "dump = try await dumpProfiles(docsPath: workingDir.path)",
         "dump = (path: try Provision.dumpProfiles(docsPath: workingDir.path), attempts: 1)",
         "R08: the sweep must go through the retrying dump wrapper"),
        # `.skipped` 退回「只有一句 break」：用户看到 profile 一直在堆，
        # 却查不出「这一轮到底跑没跑」—— 真机排查直接断线。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            try? await logStore?.append(\n"
         "                category: .system,\n"
         '                message: "维护作业本轮跳过：有前台操作正在进行（下次启动或空闲时再试）",\n'
         '                code: "SEAL-STORAGE-009"\n'
         "            )\n"
         "        case .completed",
         "            break\n"
         "        case .completed",
         "R08: every non-.completed maintenance outcome must leave a trace"),
        # `.failed` 退回「只弹窗不写日志」：用户划掉弹窗后日志里什么都没留下，
        # 事后完全查不出是哪一步失败。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            try? await logStore?.append(\n"
         "                category: .system,\n"
         "                level: .warning,\n"
         '                message: "维护作业失败：\\(failure.title)（\\(failure.code)）",\n'
         '                code: "SEAL-STORAGE-010"\n'
         "            )\n"
         "            alertFailure = failure",
         "            alertFailure = failure",
         "R08: every non-.completed maintenance outcome must leave a trace"),
        # 自替换结算清理退回「只写事务审计、不写日志」：排障时拿到的日志里永远看不到
        # Seal 自己的旧 profile 有没有被回收，16 份堆积看起来像清理逻辑根本不存在。
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "            try? await logStore?.append(\n"
         "                category: .installation,\n"
         '                message: "自替换结算清理：\\(cleanup.logMessage)",\n'
         '                code: "SEAL-PROFILE-322"\n'
         "            )\n"
         "            try await selfReplacement.finishCleanup(cleanup)",
         "            try await selfReplacement.finishCleanup(cleanup)",
         "R08: the self-replacement cleanup must log before closing the transaction"),
        # 把单测里的关键判定改宽（`hasPrefix("自")` 什么都通过）：
        # 「单测文件里有这几行」这类断言必须真的会红，否则测试被改宽后守卫照样绿。
        ("SealTests/Renewal/SelfAppPendingHandoffTests.swift",
         '$0.message.hasPrefix("自替换结算清理：")',
         '$0.message.hasPrefix("自")',
         "R08: the self-replacement cleanup log needs a real unit test"),
        # 把重试次数的单测改回「只试一次」：断言「单测覆盖了重试」的那条必须真的会红。
        ("SealTests/Installation/DeviceProfileCleanerTests.swift",
         "dumpAttempts: 3",
         "dumpAttempts: 1",
         "R08: the retry count must stay covered by a real unit test"),
        # 导出时不透传构建标识：表头还在，但「这份日志来自哪个构建」重新变成靠猜 ——
        # 正是 2026-09-17 那轮白跑的成因。
        ("Seal/Infrastructure/Diagnostics/SealLogStore.swift",
         "            notice: notice,\n"
         "            buildLabel: SealLogTextFormatter.currentBuildLabel\n"
         "        )",
         "            notice: notice\n"
         "        )",
         "R08: the store must pass the build label through"),
        # 表头不再渲染构建号（字段还在、属性还在，只是没进文本）。
        ("Seal/Core/Diagnostics/SealLogEntry.swift",
         '"构建 \\(buildLabel)',
         '"构建"',
         "R08: the build label must actually be rendered into the export header"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard let uuid = record.provisioningProfileUUID,",
         "let uuid = record.provisioningProfileUUID ?? \"\",",
         "R08: records without a profile UUID must be skipped"),
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "guard record.signedArtifactStatus == .installed else { continue }",
         "guard true else { continue }",
         "R08: extension profile ids are optimistic"),
        # ── R11: 旧 Team 变体回收的安全边界 ──────────────────────────────────
        # 把「查询失败」当成「没装」：这是最危险的一条 —— 隧道抖动时**所有**候选
        # 都被读成「没装」，于是删掉正在用的 profile，对应 App 立刻无法启动。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "            return .abortPass\n        case .installed:",
         "            return .notInstalled\n        case .installed:",
         "R11: a failed probe must abort the pass"),
        # 去掉阳性对照：`.reclaim` 变成只要「答未安装」就给，
        # 而「答未安装」恰恰是通道不可信时最容易出现的答案。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "return positiveControlPassed ? .reclaim : .abortPass",
         "return .reclaim",
         "R11: .reclaim must require a passed positive control"),
        # 用 `lookupApp` 替掉会抛错的 `isAppInstalled`：把「没装」与「查询失败」
        # 折叠成同一个 `nil`，正是上面那条灾难的入口。
        # ⚠️ 缩进跟着实现走：`probeInstalled` 现在把它包在 `BlockingCall.bounded` 的闭包里（12 空格）。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "            try Minimuxer.isAppInstalled(bundleId: bundleID)",
         "            Minimuxer.lookupApp(bundleId: bundleID) != nil",
         "R11: the reclaim path must use the throwing isAppInstalled"),
        # 让阳性对照永远通过：对照形同虚设，通道不可信时照样全删。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "let positiveControlPassed = firstControlProbe.probe == .installed",
         "let positiveControlPassed = true",
         "R11: the positive control must be an actual probe of a definitely-installed app"),
        # 中止改成「只记原因、继续往下删」：后面的候选（以及已经问过的那几条）
        # 继续被一条已经不可信的通道判定并删除 —— 但代码看起来仍然「有中止逻辑」，
        # 是最容易漏掉的一种退化。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "        guard reclaimAbortReason == nil else {\n"
         "            summary.reclaimAborted = reclaimAbortReason\n"
         "            return summary\n"
         "        }",
         "        if reclaimAbortReason != nil {\n"
         "            summary.reclaimAborted = reclaimAbortReason\n"
         "        }",
         "R11: .abortPass must record why and stop the whole pass"),
        # 中止不落日志：`回收 0` 会被读成「形态没匹配上」，而实际是通道不可信 ——
        # 两者的后续动作完全不同（前者要查判据，后者要查设备连接）。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "        if let reclaimAborted {\n",
         "        if false, let reclaimAborted {\n",
         "R11: an aborted reclaim must be visible"),
        # 把 keep-map 命中判断退回「精确查表」：key 大小写不一致时会把「正在用的那个」
        # 判成可回收 ⇒ 删掉活着的 profile。（2026-09-17 真的这样挂过一次 CI。）
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "guard keepingByBundleID.keys.contains(where: { normalized($0) == lowered }) == false else {",
         "guard keepingByBundleID[lowered] == nil else {",
         "R11: the keep-map membership test must be case-insensitive"),
        # 删掉宽松受保护集合那一句：扩展 ID 重新变成候选，而设备端核验对扩展恒答「没装」
        # ⇒ 已装 App 的扩展 profile 被删（2026-09-17 真机事故）。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "guard protectedBundleIDs.contains(where: { normalized($0) == lowered }) == false else {",
         "guard true else {",
         "R11: the candidate rule needs a separate protected set"),
        # 给宽松集合加回 `.installed` 门槛：与严格 keep-map 变成同一个集合，
        # 标记一陈旧扩展就掉出保护范围 —— 这正是事故的形态。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "            for extensionRecord in record.extensions {\n"
         "                if let extensionID = effectiveBundleID(",
         "            guard record.signedArtifactStatus == .installed else { continue }\n"
         "            for extensionRecord in record.extensions {\n"
         "                if let extensionID = effectiveBundleID(",
         "R11: the protected set must collect extensions unconditionally"),
        # 调用点漏传受保护集合（传空集）：判据本身没被改，但保护等于没有。
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: records),",
         "protectedBundleIDs: [],",
         "R11: idle maintenance must pass a record-derived protected set"),
        # 结算路径漏传：它的 keep-map 只有 Seal 自己，别的 App 的扩展全靠这个集合。
        ("Seal/Core/Renewal/SelfAppRegistrar.swift",
         "protectedBundleIDs: ProfileReclaimPolicy.protectedBundleIDs(records: allRecords)",
         "protectedBundleIDs: []",
         "R11: self-replacement settle must pass a record-derived protected set"),
        # 去掉 fail closed：保护范围未知时照样按「现有信息尽量删」办。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "let reclaimEnabled = reclaimSealOrphans && protectedBundleIDs.isEmpty == false",
         "let reclaimEnabled = reclaimSealOrphans",
         "R11: an empty protected set must disable reclaim entirely"),
        # 把那条「混合大小写 key」的单测改成小写：源码断言（实现里写了 lowercased() 比较）
        # 仍然全绿，但测试已经守不住这个行为了。
        ("SealTests/Maintenance/ProfileReclaimPolicyTests.swift",
         "    func currentBundleIdentifierIsNeverACandidate() {\n"
         '        let keep = ["com.kdt.livecontainer.seal.KYRJV2U7WS": "LIVE-UUID"]',
         "    func currentBundleIdentifierIsNeverACandidate() {\n"
         '        let keep = ["com.kdt.livecontainer.seal.kyrjv2u7ws": "LIVE-UUID"]',
         "R11: the keep-map case-insensitivity needs a real unit test with a mixed-case key"),
        # 把决策分支的单测删掉：源码断言证明不了「每个分支真的被测过」。
        ("SealTests/Maintenance/ProfileReclaimPolicyTests.swift",
         "    func unavailableNeverReclaims() {",
         "    func unavailableNeverReclaimsRenamed() {",
         "R11: every branch of the reclaim decision needs a real unit test"),
        # 维护作业不再开启孤儿回收：编译不失败、别的单测也不红，
        # 只是「换 Apple ID 后旧 Team 后缀的 profile」永远清不掉 —— 正是用户报的现象。
        ("Seal/Core/Maintenance/AppMaintenanceJob.swift",
         "reclaimSealOrphans: true",
         "reclaimSealOrphans: false",
         "R11: idle maintenance must opt in explicitly"),
        # 把「调用方真的开了回收」这条单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "    func maintenanceSweepEnablesSealOrphanReclaim() async throws {",
         "    func maintenanceSweepEnablesSealOrphanReclaimRenamed() async throws {",
         "R11: the opt-in flag must stay covered by a real unit test"),
        # ── R12：批量续签的逐项成功日志（2026-09-17 真机反馈）──
        # 删掉逐项成功日志：批量路径重新变成「日志里没有结论」，
        # 用户无法判断「某个 App 到底成没成、描述文件是不是新申请的」。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         '                    code: "SEAL-RENEW-020"',
         '                    code: "SEAL-RENEW-020-REMOVED"',
         "R12: the batch renewal path must log a per-item success line"),
        # 日志还在，但不再带描述文件身份：看起来「有留痕」，
        # 实际回答不了那个真正的问题（换的是新申请的那份，还是旧的那份）。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "描述文件 \\(Self.describeProfile(updated))",
         "描述文件已更新",
         "R12: the batch renewal path must log a per-item success line"),
        # 描述文件身份里丢掉到期时间：UUID 与创建时间都在，唯独少了「还能用多久」。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "let expires = record.provisioningProfileExpirationDate",
         "let expires: Date? = nil",
         "R12: the per-item success line must carry the profile identity"),
        # 把 ISO8601 换成本地化格式：导出日志的人可能不在中文环境里，
        # 而且没法直接和 Apple 门户返回的时间对照。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "let formatter = ISO8601DateFormatter()",
         "let formatter = DateFormatter()",
         "R12: the per-item success line must carry the profile identity"),
        # 构造点漏传日志库：编译不失败，只是这条日志重新变空白。
        ("Seal/Application/AppContainer.swift",
         "                logStore: logStore\n            )\n            let appRecordRecovery = AppRecordRecovery(",
         "                logStore: nil\n            )\n            let appRecordRecovery = AppRecordRecovery(",
         "R12: the batch coordinator must be given a log store"),
        # 把那条 ISO8601 单测改宽成单字符断言：源码断言仍然全绿，
        # 但测试已经守不住「时间真的是 ISO8601」了（单字符会同时匹配 Character 重载）。
        ("SealTests/Renewal/RenewalCoordinatorLogTests.swift",
         '        #expect(text.contains("2026-09-17T05:28:58Z"))',
         '        #expect(text.contains("T"))',
         "R12: the ISO8601 unit test must assert the full form"),
        # ── R12：轮询日志降噪（2026-09-17 真机日志量化：30% 是噪音）──
        # 把「有待恢复数据才留痕」改回无条件留痕：`load()` 每 9 秒一次，
        # 立刻回到「三成日志是噪音、真实信号被挤出环形缓冲」的状态。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            if pendingPayload != nil, hasRestoredPendingBatchResult == false {\n",
         "            if true {\n",
         "R12: the restore poll path must stay silent on the normal path"),
        # 去掉「已经恢复进会话」这个条件：载荷要等抽屉关闭才清，于是每次 `load()` 轮询
        # 都会重复报同一条「被跳过」警告 —— 真警报被自己的重复埋掉。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "            if pendingPayload != nil, hasRestoredPendingBatchResult == false {\n",
         "            if pendingPayload != nil {\n",
         "R12: the restore poll path must stay silent on the normal path"),
        # 重新引入临时脚手架：证明「[BatchDebug] 已清干净」这条 not-in 断言真的会红。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        let pendingPayload = loadPendingBatchResultPayload()",
         "        let pendingPayload = loadPendingBatchResultPayload()\n        Task { try? await logStore?.append(category: .renewal, level: .info, message: \"[BatchDebug] restore poll\", code: \"SEAL-BATCH-DEBUG-9\") }",
         "R12: the temporary [BatchDebug] scaffolding must stay removed"),
        # ── R13：「Apple 要求双重认证」的专门分类与提示（2026-09-17 真机取证）──
        # 换掉错误码：Apple 只会用它这个稳定的数字，描述文案会随语言与措辞变。
        ("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift",
         "static let twoFactorRequiredCode = 3018",
         "static let twoFactorRequiredCode = 9999",
         "R13: the two-factor error code must stay 3018"),
        # 只按描述判断：文案一改就再也认不出来，而「认不出来」的后果是把用户
        # 引去「核对 Apple ID 与密码」——一个完全正确的密码。
        ("Seal/Infrastructure/Accounts/AppleAuthenticationDiagnosis.swift",
         "if nsError.code == twoFactorRequiredCode { return true }",
         "if false { return true }",
         "R13: the code check must come first"),
        # 只在其中一条链路上做分类（这里删的是 `validate` 那条）：
        # 编译不失败、其它单测也不红，只是那条路径重新给出错误引导。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n",
         "",
         "R13: every error-mapping entry point must route"),
        # 分支还在、顺序被换到限流之后：同一个错误在两条路径上给出不同提示。
        # 这是「顺序也是设计」那条断言唯一能抓到它的地方。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n"
         "            if AppleServiceFailurePolicy.isRateLimited(error) {\n"
         "                throw AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)\n"
         "            }\n",
         "            if AppleServiceFailurePolicy.isRateLimited(error) {\n"
         "                throw AppleServiceFailurePolicy.rateLimitedFailure(underlying: error)\n"
         "            }\n"
         "            if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "                throw AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "            }\n",
         "R13: AppleAccountClient.validate must check two-factor before"),
        # 分支留着、但自己手写一份泛化提示（`make` 那条）：
        # 看起来「有分支」，实际又回到了「核对 Apple ID 与密码」。
        ("Seal/Infrastructure/Accounts/AppleAccountClient.swift",
         "        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n"
         "            return AppleAuthenticationDiagnosis.twoFactorFailure(for: error)\n"
         "        }\n",
         '        if AppleAuthenticationDiagnosis.isTwoFactorRequired(error) {\n'
         '            return ImportFailure(title: "无法添加账号", reason: "Apple ID 验证失败。", recovery: "重试；如持续失败请核对 Apple ID 与密码", code: "SEAL-AUTH-107a")\n'
         "        }\n",
         "R13: every entry point must use the shared factory"),
        # 把那条「绝不能叫用户去核对密码」的单测改名：
        # 证明「单测文件里有这几个字」的断言真的会红，而不是永远绿着。
        ("SealTests/Accounts/AppleAuthenticationDiagnosisTests.swift",
         "    func twoFactorFailureNeverTellsTheUserToCheckThePassword() {",
         "    func twoFactorFailureNeverTellsTheUserToCheckThePasswordRenamed() {",
         "R13: the 'never send the user to check the password' rule"),
        # ── R14：安装心跳双路径 + 扩展随父保留（2026-09-17 真机，构建 97）──
        # 只给自替换路径留心跳、普通路径退回静默：真机上普通安装卡住时日志重新一片空白，
        # 「在装」与「死了」再次分不开。这是本轮最直接的成因。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '                    let heartbeat = beginInstallHeartbeat("安装", budget: mergedTimeout)',
         "                    // heartbeat removed",
         "R14: BOTH install paths must use the shared heartbeat"),
        # 前缀不在点边界上收口：同一 Team 下的兄弟变体会互相「保护」，回收功能整体失效。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         'if lowered.hasPrefix(parent + ".") { return true }',
         "if lowered.hasPrefix(parent) { return true }",
         "R14: the parent prefix must end on a DOT boundary"),
        # 调用还在、但传空集合：代码看起来「有父 App 判定」，实际一份都不保护 ——
        # 正是真机上丢掉三个扩展 profile 的那条路径。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "                    ofAnyOf: installedCandidates",
         "                    ofAnyOf: []",
         "R14: the pass must consult the parent rule with the real candidate set"),
        # 受保护集合规模不进日志：下次再看到「候选很多」又只能靠推断。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         '            text += "，受保护 \\(protectedCount)"',
         "            // protected count removed",
         "R14: the protected-set size must be in the log"),
        # 把新计数的单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Installation/DeviceProfileCleanerTests.swift",
         "    func protectedSetSizeIsReported() {",
         "    func protectedSetSizeIsReportedRenamed() {",
         "R14: the new attribution counters need real unit tests"),
        # 把超时文案改回「系统已自动重试」：用户会继续等一个并不存在的重试，
        # 而超时路径其实是原样抛出、不重试的（R05）。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '            + "底层安装调用不会被取消（同步调用没有取消机制），也不会自动重试 —— "',
         '            + "系统已自动重试。"',
         "R14: the timeout message must not claim a retry"),
        # ── R15：脱敏不得吃掉 ISO 时间戳（2026-09-17 真机日志发现）──
        # 退回原来的结尾断言：匹配又能停在日期中间，`2026-09` 被当成手机号吃掉。
        ("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift",
         '(?![A-Za-z0-9\\-:])',
         '(?![A-Za-z0-9])',
         "R15: the phone pattern must not stop inside a date"),
        # 日期形状判据留着但不调用：代码看着「有保护」，实际时间戳照样被毁。
        ("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift",
         "guard looksLikeDateFragment(match) == false else { return match }",
         "// date guard removed",
         "R15: the phone redactor must actually consult the date guard"),
        # 把日期形状判据放宽到只认「4 位数字-2 位数字」：`1234-56` 这类手机号会被放过去，
        # 脱敏出现口子（这是**放宽**的方向，比多脱敏危险）。
        ("Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift",
         '^(?:19|20)\\d{2}-(?:0[1-9]|1[0-2])(?:-(?:0[1-9]|[12]\\d|3[01]))?$',
         '^\\d{4}-\\d{2}$',
         "R15: a date-shaped match must be left alone"),
        # 把「时间戳原样保留」那条单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Diagnostics/LogPrivacyRedactorTests.swift",
         "    func keepsISOTimestampsIntact() {",
         "    func keepsISOTimestampsIntactRenamed() {",
         "R15: keeping ISO timestamps intact needs a real unit test"),
        # ── R16：缓存设备会话的活性探测（2026-09-17 加）──
        # 去掉调用点：探测留着但从不执行，代码看着「有保护」。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                if attempt == 1 { await probeCachedSessionIfStale() }",
         "                // probe removed",
         "R16: the probe must run before the FIRST attempt"),
        # 把探测的上限放到 600 秒：它自己就变成了那个「会卡住的东西」。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "private static let cachedSessionProbeTimeoutSeconds: Double = 5",
         "private static let cachedSessionProbeTimeoutSeconds: Double = 600",
         "R16: the probe must be bounded"),
        # 把探测换成标志位检查：正是「分不出死活」的那个判据。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            try Minimuxer.fetchUDIDDetailed()",
         "            Minimuxer.ready()",
         "R16: the probe must use a real round-trip that throws"),
        # 在探测里顺手重建连接（最像「好心」的改法）：会拆掉可能仍在跑的上一笔安装
        # 连接（R05），而我们连「会话是不是死的」都还不知道。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "        guard let lastStart = lastSuccessfulStart,\n"
         "              Date().timeIntervalSince(lastStart) > Self.cachedSessionProbeThresholdSeconds else {\n"
         "            return\n"
         "        }",
         "        Minimuxer.reset()\n"
         "        guard let lastStart = lastSuccessfulStart,\n"
         "              Date().timeIntervalSince(lastStart) > Self.cachedSessionProbeThresholdSeconds else {\n"
         "            return\n"
         "        }",
         "R16: the probe must stay observation-only"),
        # ── R17：批量续签被自己替换中断，不许自相矛盾（2026-09-17 真机，构建 102）──
        # 退回「一律降级为 unknown」：同一个批次会同时说「成功 2/2」和「1 个结果未知」。
        ("Seal/Infrastructure/Renewal/RefreshQueueStore.swift",
         "            if let known = settled[items[index].appID] {",
         "            if false {",
         "R17: an interrupted item with a known result must be SETTLED, not downgraded"),
        # **顺序反了**（本修复的核心）：先结算队列、再恢复载荷 ⇒ 那个 running 项在载荷被读
        # 之前就变成了 unknown，假警报与幽灵条目原样回来。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        restorePendingBatchResultIfNeeded()\n"
         "        let settled = settledQueueStates(from: loadPendingBatchResultPayload())",
         "        let settled = settledQueueStates(from: loadPendingBatchResultPayload())\n"
         "        restorePendingBatchResultIfNeeded()",
         "R17: the payload must be restored and read BEFORE the queue is settled"),
        # 忘了先恢复载荷：`settled` 永远是空的，等于这条修复不存在。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        restorePendingBatchResultIfNeeded()\n"
         "        let settled = settledQueueStates(from: loadPendingBatchResultPayload())",
         "        let settled: [UUID: RefreshQueueItem.State] = [:]",
         "R17: the payload must be restored and read BEFORE the queue is settled"),
        # 把 `running` 也映射成已定论：等于替那个**正在被杀死**的项宣布结果。
        ("Seal/Core/Renewal/BatchRefreshSession.swift",
         "        case .completed: return .completed",
         "        case .completed, .running: return .completed",
         "R17: only settled states may be mapped"),
        # 把这组映射收回成 file 级：读取侧与单测在别的文件里 ⇒ 云构建直接编译不过
        # （2026-09-17 真实踩到一次）。
        ("Seal/Core/Renewal/BatchRefreshSession.swift",
         "extension BatchRefreshSession.Item.State {",
         "private extension BatchRefreshSession.Item.State {",
         "R17: the payload mapping must be internal and live with the type"),
        # ── R18：安装等待「明显超常」的记录（2026-09-17 加）──
        # 把阈值退回写死 120 秒：**大包会报假警报**（抖音 779 MB 的上限是 2400 秒，
        # 等两分钟完全正常）—— 假警报会把真信号埋掉。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "    private static func abnormalInstallWaitSeconds(budget: Double) -> Double {\n"
         "        max(120.0, budget / 4.0)\n"
         "    }",
         "    private static func abnormalInstallWaitSeconds(budget: Double) -> Double {\n"
         "        120.0\n"
         "    }",
         "R18: 阈值必须**按本次等待上限**算"),
        # 去掉「只写一次」的门：13 分钟的等待会写出 6 条一模一样的警告，
        # 把真实信号埋掉（本仓已有一次「脚手架占 30% 日志」的教训）。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                if didReportAbnormal == false, Double(waited) >= threshold {",
         "                if Double(waited) >= threshold {",
         "R18: the abnormal record must fire exactly ONCE"),
        # 其中一条链路漏传自己的预算：它会用另一条链路的阈值（892 vs 804 不是同一个数）。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '        let heartbeat = beginInstallHeartbeat("自替换安装", budget: budget)',
         '        let heartbeat = beginInstallHeartbeat("自替换安装", budget: 804)',
         "R18: both install paths must pass their OWN budget to the heartbeat"),
        # 把心跳改成「看门狗」（顺手重建连接）：真正的慢安装会被提前判死，
        # 而上限本来就是按包大小算的。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "        return Task.detached(priority: .utility) { [weak self] in\n"
         "            var didReportAbnormal = false",
         "        return Task.detached(priority: .utility) { [weak self] in\n"
         "            await self?.reset()\n"
         "            var didReportAbnormal = false",
         "R18: the heartbeat must stay observation-only"),
        # ── R19：Seal 早期的裸 Bundle ID 也要能回收（2026-09-17 加）──
        # 去掉那条分支：那份陈旧的「Seal」profile 又变成永远清不掉。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "        if lowered == SelfManagedSealMigrationPolicy.canonicalBundleIdentifier { return true }",
         "        // bare id removed",
         "R19: Seal 早期的裸 Bundle ID 也必须能回收"),
        # 把精确相等改成前缀匹配：`com.mjorb.sealX` 这类无关 ID 也会被当成候选。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "        if lowered == SelfManagedSealMigrationPolicy.canonicalBundleIdentifier { return true }",
         "        if lowered.hasPrefix(SelfManagedSealMigrationPolicy.canonicalBundleIdentifier) { return true }",
         "R19: 裸 ID 必须精确相等"),
        # **顺序反了**（本修复最危险的方向）：裸 ID 分支插到两条守卫**之前**，
        # 「正在用的那一份」就会被判成候选 ⇒ 删掉 Seal 自己。
        # ⚠️ 锚点带上函数签名：`let lowered = normalized(...)` + 那句 guard 在
        # `isExtensionBundleID` 里也有一份（同文件两处），只写这两行不唯一。
        ("Seal/Core/Maintenance/ProfileReclaimPolicy.swift",
         "        protectedBundleIDs: Set<String>\n"
         "    ) -> Bool {\n"
         "        let lowered = normalized(bundleID)\n"
         "        guard lowered.isEmpty == false else { return false }",
         "        protectedBundleIDs: Set<String>\n"
         "    ) -> Bool {\n"
         "        let lowered = normalized(bundleID)\n"
         "        if lowered == SelfManagedSealMigrationPolicy.canonicalBundleIdentifier { return true }\n"
         "        guard lowered.isEmpty == false else { return false }",
         "R19: the bare-ID branch must come AFTER both guards"),
        # 把单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Maintenance/ProfileReclaimPolicyTests.swift",
         "    func sealCanonicalBareIdentifierIsACandidate() {",
         "    func sealCanonicalBareIdentifierIsACandidateRenamed() {",
         "R19: 三个方向都要有单测"),
        # ── R20：把 anisette 准备这段静默括起来（2026-09-17 加）──
        # 去掉「开始」那条：那段静默又变成无法归因的空白。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '            await diagnostic("签名：正在准备设备环境（anisette）")\n',
         "",
         "R20: the anisette step must be bracketed"),
        # **顺序反了**：留痕放到 `fetch()` 之后 ⇒ 「正在准备」在慢步骤结束时才写，
        # 时间线上看不出它是从哪一刻开始的。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '            await diagnostic("签名：正在准备设备环境（anisette）")\n'
         "            let anisette = try await anisetteProvider.fetch()",
         "            let anisette = try await anisetteProvider.fetch()\n"
         '            await diagnostic("签名：正在准备设备环境（anisette）")',
         "R20: the anisette step must be bracketed"),
        # 去掉耗时：无法判断「是不是这步慢」。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '                "签名：设备环境已就绪，耗时 \\(Int(Date().timeIntervalSince(anisetteStartedAt))) 秒"',
         '                "签名：设备环境已就绪"',
         "R20: 完成那条必须带耗时"),
        # ── R21：「证书轮换失败」必须说清后果（2026-09-17 加）──
        # 去掉「后果」那句：用户只会看到「App 莫名启动不了」。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '            reason: "已释放 \\(revokedSerials.count) 张不可用证书，但 Apple 仍未允许创建新的本机签名身份。\\n"\n'
         '                + "用这些证书签名的 App 现在无法启动 —— 需要先让这个 Apple ID 恢复可用，"\n'
         '                + "再把那些 App 重新签一次才能恢复。",',
         '            reason: "已释放 \\(revokedSerials.count) 张不可用证书，但 Apple 仍未允许创建新的本机签名身份。",',
         "R21: 「证书轮换失败」必须写明后果"),
        # 把 recovery 退回「稍后重试」：失败原因常常是会话失效，那种情况下重试无效。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '            recovery: "先确认这个 Apple ID 的登录仍然有效（必要时到「我的」重新验证），再重试",',
         '            recovery: "稍后重试",',
         "R21: recovery 不能只说「稍后重试」"),
        # ── R22：日志码索引必须与源码一致（2026-09-17 加）──
        # 往主表塞一个源码里没有的码：正是「文档漂移」的样子，会误导排查。
        ("docs/qa/log-code-index.md",
         "| `SEAL-VPN-001` | 签名完成后仍无法连接设备完成安装 | `SigningCoordinator.swift` |",
         "| `SEAL-VPN-001` | 签名完成后仍无法连接设备完成安装 | `SigningCoordinator.swift` |\n"
         "| `SEAL-GHOST-999` | 这条码源码里并不存在 | 无 |",
         "R22: 索引里这些码在源码里已不存在"),
        # 把「已移除」表里的一行换成**仍然存在**的码：两侧断言都要能发现。
        ("docs/qa/log-code-index.md",
         "| `SEAL-CERT-224` | 源码里已不存在（历史码） |",
         "| `SEAL-VPN-001` | 源码里已不存在（历史码） |",
         "R22: 「已移除」表里的码又回到源码里了"),
        # 去掉「已从源码移除」这一节：旧日志里的历史码就没有归处了。
        ("docs/qa/log-code-index.md",
         "## 已从源码移除（旧日志里还会看到，**别当成现在还在报**）",
         "## 历史码",
         "R22: 日志码索引必须有「已从源码移除」一节"),
        # ── R23：证书阶段不许只给「去重新验证」一条路（2026-09-17 用户反馈）──
        # 退回旧文案：用户会陷入「重新验证 → 再签 → 又被限流 → 又被要求验证」的死循环。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '                recovery: "先等几分钟重试；若多次重试仍失败，再到「我的」页面重新验证这个 Apple ID，"\n'
         '                    + "或改用其它 Apple ID 签名",',
         '                recovery: "前往「我的」页面重新登录该 Apple ID",',
         "R23: 不能退回「只让用户去重新验证」这一条路"),
        # 去掉「限流」这个成因：只剩「登录失效」一种解释，用户就会去反复重新验证。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '                    + "这个错误有两种常见成因：登录真的失效，或者短时间内请求过密被 Apple 限流"\n'
         '                    + "（扩展较多的 App 一次签名要连续注册多个 App ID，最容易触发）。\\n"',
         '                    + "这个错误的成因是登录失效。\\n"',
         "R23: 证书阶段必须点明「可能是限流」"),
        # ── R24：三个 portal 变更都要过退避重试（2026-09-17 补）──
        # 把证书创建退回「直接请求」：它是流程里第一个真正落到 Apple 侧的变更，
        # 最容易撞上限流，而漏掉它会让限流被误报成「账号需要重新验证」。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         '            let created = try await withSessionRecovery("创建证书") {\n'
         '                try await addCertificate(\n'
         '                    team: team,\n'
         '                    session: session,\n'
         '                    deviceName: deviceName\n'
         '                )\n'
         '            }',
         '            let created = try await addCertificate(\n'
         '                team: team,\n'
         '                session: session,\n'
         '                deviceName: deviceName\n'
         '            )',
         # ⚠️ 期望文案必须与**真实断言文案前缀一致**。R24 的检查已改成「按操作逐个点名 + 理由」，
         # 所以这里也要跟着改 —— 不同步的话会报成 `Guard failed mutation check`，
         # 看着像「变异没被抓到」，其实是断言已触发、只是消息对不上。
         "R24: 创建证书 —— 它是整条流程里第一个真正落到 Apple 侧的变更"),
        # 把 updateFeatures 退回「直接请求」：它是 Phase 1 里每个 bundle ID 的**第二次**写请求，
        # 与 addAppID 同等密集。主 App 撞 1100 会直接让整个签名失败、扩展撞 1100 会被静默清空 entitlements。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                        let updated: (appID: ALTAppID, downgradedToEmptyEntitlements: Bool) =\n"
         "                            try await withSessionRecovery(\"更新应用能力 \\(mappedBundleID)\") {\n"
         "                                try await updateFeatures(\n"
         "                                    appID: appID,\n"
         "                                    application: application,\n"
         "                                    team: team,\n"
         "                                    session: session\n"
         "                                )\n"
         "                            }\n"
         "                        appID = updated.appID",
         "                        appID = try await updateFeatures(\n"
         "                            appID: appID,\n"
         "                            application: application,\n"
         "                            team: team,\n"
         "                            session: session\n"
         "                        )",
         "R24: 更新应用能力（updateFeatures）"),
        # 把 Phase 1 的 applications 查询退回 original ID：键错位会让 entitlements 恒空、
        # 签出的包不带任何能力（2026-09-18 真机日志「远端 ["APG3427HIY"] vs 本次 []」实锤）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                if let application = applications[mappedBundleID] {",
         "                if let application = applications[originalBundleID] {",
         "R24b: Phase 1 的 applications 查询必须用 mapped ID"),
        # 把 App Group 分配退回「直接请求」：同一条规则不该只落在免费路径上。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                            try await withSessionRecovery(\"分配 App Group \\(mappedBundleID)\") {\n"
         "                                try await assignAppGroups(\n"
         "                                    appID: appID,\n"
         "                                    application: application,\n"
         "                                    team: team,\n"
         "                                    session: session\n"
         "                                )\n"
         "                            }",
         "                            try await assignAppGroups(\n"
         "                                appID: appID,\n"
         "                                application: application,\n"
         "                                team: team,\n"
         "                                session: session\n"
         "                            )",
         "R24: 分配 App Group（付费账号才走"),
        # ── R25：同步阻塞 FFI 的每一处等待都要有界（2026-09-17 审计）──
        # 把设备核验退回「只 Task.detached、无超时」：死会话上它会永久阻塞。
        ("Seal/Features/Apps/InstalledAppDeviceVerifier.swift",
         "        let outcome = await BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds) {\n"
         "            // 查询前重置连接，避免使用已断开的 RSD 缓存连接导致误判\n"
         "            Install.resetProvider()\n"
         "            return try Minimuxer.isAppInstalled(bundleId: identifier)\n"
         "        }",
         "        let outcome = await Task.detached(priority: .userInitiated) {\n"
         "            Install.resetProvider()\n"
         "            return Result { try Minimuxer.isAppInstalled(bundleId: identifier) }\n"
         "        }.value",
         "R25: 设备核验的同步 FFI 必须有界"),
        # 把维护期探测退回「只 Task.detached、无超时」：一次无界阻塞会让整轮维护永远完不成。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "        guard let outcome = await BlockingCall.bounded(seconds: BlockingCall.queryTimeoutSeconds, {\n"
         "            try Minimuxer.isAppInstalled(bundleId: bundleID)\n"
         "        }) else {\n"
         "            return .unavailable\n"
         "        }",
         "        guard let outcome = await Task.detached(priority: .utility, {\n"
         "            Result { try Minimuxer.isAppInstalled(bundleId: bundleID) }\n"
         "        }).value as Result<Bool, Error>? else {\n"
         "            return .unavailable\n"
         "        }",
         "R25: 维护期的设备探测必须有界"),
        # 让通道不再委托：又变成两份实现，迟早漂移。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "        await BlockingCall.bounded(seconds: seconds, work)",
         "        return Result { try await work() }",
         "R25: 安装通道的 offThread 必须委托给共用实现"),
        # 安装后验证退回无界查询：死会话上会在 8 次循环里一直卡住。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            let probe = await offThread(seconds: BlockingCall.queryTimeoutSeconds) {\n"
         "                Minimuxer.lookupApp(bundleId: bundleID) != nil\n"
         "            }",
         "            let probe: Result<Bool, Error>? = .some(.success(Minimuxer.lookupApp(bundleId: bundleID) != nil))",
         "R25: 安装后验证里的 lookupApp 也必须是有界查询"),
        # ── R26：创建 App ID 的顺序 —— 主 App 必须优先（2026-09-17）──
        # 让「主 App 优先」失效：退回纯字母序 ⇒ 扩展先吃掉共享名额，主 App 反而签不上。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                if lhsIsMain != rhsIsMain { return lhsIsMain }",
         "                if lhsIsMain && rhsIsMain { return lhsIsMain }",
         "R26: preparationOrder 必须真的把主 App 排到最前"),
        # 把稳定排序反过来：同一份输入的顺序会抖，真机现象与日志对不上。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                return lhs.original < rhs.original",
         "                return lhs.original > rhs.original",
         "R26: 主 App 之外的条目仍要按原序稳定排序"),
        # 退回字母序调用（同时丢掉 preparationOrder 的调用点）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "        for (originalBundleID, mappedBundleID) in ApplePortalAppIDResolver.preparationOrder(\n"
         "            mappings: mappings,\n"
         "            mappedMainBundleID: mappedMainBundleID\n"
         "        ) {",
         "        for (originalBundleID, mappedBundleID) in mappings.sorted(by: { $0.key < $1.key }) {",
         "R26: 不能退回「按 Bundle ID 字母序创建 App ID」"),
        # 去掉名额诊断：两种成因在日志里又变得无法区分。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         r'            "App ID 名额：本次需 \(mappings.count) 个（主 App 1 + 扩展 \(extensionAppIDCount)），"',
         r'            "本次需要注册 \(mappings.count) 个 App ID",',
         "R26: 必须无条件写一条「App ID 名额」诊断"),
        # 把单测改宽：只断言「非空」，主 App 是否在最前就不管了。
        ("SealTests/Signing/ApplePortalSigningFailureTests.swift",
         "        #expect(order.first?.mapped == main)",
         "        #expect(order.isEmpty == false)",
         "R26: 主 App 优先的顺序必须由单测钉住"),
        # 把 tapStage 退回裸 tap：切 tab 的抖动又会回来（只在 CI 上间歇性暴露）。
        ("SealUITests/ImportFlowUITests.swift",
         "        tapStage(app.buttons[\"已安装，0 个\"])",
         "        app.buttons[\"已安装，0 个\"].tap()",
         "R28: 切 tab 的 UI 测试必须用 tapStage"),
        # 把断言退回「目标页文字出现」：依赖 TabView 翻页，CI 会间歇性红（2026-09-18 实测）。
        ("SealUITests/ImportFlowUITests.swift",
         "        XCTAssertTrue(\n            button.isSelected,",
         "        XCTAssertTrue(\n            app.staticTexts[\"已安装应用\"].waitForExistence(timeout: 5),",
         "R28: 切 tab 的断言必须落在**确定性的选中态**"),
        # 把滑动退回裸手势：滑动的抖动又会回来（只在 CI 上间歇性暴露，2026-09-18 构建 131 实测）。
        ("SealUITests/ImportFlowUITests.swift",
         "        swipeStage(pager, to: .left, expecting: app.buttons[\"已安装，0 个\"])",
         "        pager.swipeLeft()",
         "R28b: 滑动路径也必须走 swipeStage"),
        # 把滑动断言退回「目标页文字出现」：依赖 TabView 翻页，CI 会间歇性红。
        ("SealUITests/ImportFlowUITests.swift",
         "        XCTAssertTrue(\n            selected.isSelected,",
         "        XCTAssertTrue(\n            app.staticTexts[\"已安装应用\"].waitForExistence(timeout: 5),",
         "R28b: 滑动路径的断言必须落在**确定性的选中态**"),
        # ── R29：证书轮换路径的「创建证书」也要过退避重试（2026-09-17）──
        # 退回「直接请求」：它前面刚 revoke 过，创建失败会让账号变成 0 张证书
        # ⇒ 用它签过的所有 App 立刻打不开。
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         "            requested = try await withSessionRecovery(\"创建证书（证书轮换）\") {\n"
         "                try await addCertificate(\n"
         "                    team: context.team,\n"
         "                    session: context.session,\n"
         "                    deviceName: deviceName\n"
         "                )\n"
         "            }",
         "            requested = try await addCertificate(\n"
         "                team: context.team,\n"
         "                session: context.session,\n"
         "                deviceName: deviceName\n"
         "            )",
         "R29: 证书轮换路径的「创建证书」也必须过退避重试"),
        # 在新链路里抄一份自己的判据：两边迟早漂移。
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         "                guard ApplePortalSigningService.isSessionExpiredError(error) else { throw error }",
         "                guard (error as NSError).code == 1100 else { throw error }",
         "R29: 退避重试的判据与间隔必须共用 ApplePortalSigningService 那一份"),
        # ── R31：2026-09-18 真机（构建 118）的三处修复 ──
        # 把 catch 退回「无差别替换」：`appIDFailure` 的正确文案又被覆盖，用户重回死循环。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                title: failure.title,",
         "                title: \"Apple ID 会话已过期\",",
         "R31: `sign()` 不能把 SEAL-AUTH-107 无差别替换成「去重新验证」"),
        # 去掉 Phase 1 的入口留痕：`fetchAppIDs` 一失败，日志里就看不出走到哪一步。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "        await diagnostic(\n"
         "            \"App ID 阶段开始：本次需 \\(mappings.count) 个 App ID（主 App 1 + 扩展 \\(extensionAppIDCount)），准备读取账号已有列表\"\n"
         "        )\n",
         "",
         "R31: Phase 1 的入口必须先留痕"),
        # 去掉证书列表失败的原因与耗时：又只剩「暂不可用」，查不出是限流还是超时。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                await diagnostic(\"证书列表拉取失败：耗时 \\(fetchSeconds) 秒；\\(fetchReason)\")",
         "                _ = fetchReason",
         "R31: 证书列表拉取失败必须记下**原因与耗时**"),
        # ── R32：2026-09-18 真机 —— 进度文案撒谎（解压 780 MB 却说「正在验证 Apple ID」）──
        # 把新阶段的文案改回「正在验证 Apple ID」：用户又会以为是 Apple ID 卡住。
        ("Seal/Core/Signing/SigningStage.swift",
         "            return \"正在准备应用文件\"",
         "            return \"正在验证 Apple ID\"",
         "R32: `preparingBundle` 阶段必须存在，且文案不能是「正在验证 Apple ID」"),
        # ── R36：2026-09-18 用户反馈「进度条和底部 5 横杠跳着走」──
        # 破坏预算表的首尾相接：阶段切换时进度会跳一下 / 数字往回退。
        ("Seal/Core/Signing/SigningProgressBudget.swift",
         # ⚠️ 锚点**刻意不含 `timeConstant`**（2026-09-18）：那是**会随实测调整**的调参值，
         # 把它写进锚点 ⇒ 「按实测重标 τ」这种**正当改动**会让守卫误报 anchor missing ✗
         #（本轮实际踩到：τ 从 24 改到 45，守卫立刻报 anchor missing）。
         # 变异只改 `ceiling`，所以锚点覆盖到 `ceiling` 为止就够。
         # **规矩：变异锚点不要包含「本来就该被调参的值」**（τ / 超时阈值 / 上限…）。
         "floor: 14, ceiling: 38,",
         "floor: 14, ceiling: 30,",
         "R36: 阶段预算必须首尾相接"),
        # 把某个阶段的 case 标签写歪（`switch` 会编译不过，但守卫是文本检查）：
        # 「每个阶段都必须有预算」这条就此失去约束力。
        ("Seal/Core/Signing/SigningProgressBudget.swift",
         "        case .preparingCertificate:\n"
         "            return Plan(\n",
         "        case .preparingCertificat:\n"
         "            return Plan(\n",
         "R36: 阶段 `preparingCertificate` 没有进度预算"),
        # 界面不再走预算表、自己算一个数：数值来源不再唯一，「跳着走」会回来。
         # ⚠️ 2026-09-19：锚点从 `overallProgress(`（估算，已被用户要求移除）
         # 改成 `confirmedProgress(` —— 意图不变：**界面不许自己写死一个进度数** ✓。
         ("Seal/Features/Apps/SigningProgressView.swift",
          "        let confirmed = SigningProgressBudget.confirmedProgress(",
          "        let confirmed = 0.93 + 0 * Double(",
          "R36: `SigningProgressView` 必须用 SigningProgressBudget.confirmedProgress("),
        # 界面里重新写死一个进度常数（死代码也一样算）：这是「跳着走」的原样重演。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "    private func stageElapsed(_ now: Date) -> TimeInterval {",
         "    private func legacyHardcodedProgress(for stage: SigningStage) -> Double {\n"
         "        switch stage {\n"
         "        case .installing: return 0.93\n"
         "        default: return 0\n"
         "        }\n"
         "    }\n"
         "\n"
         "    private func stageElapsed(_ now: Date) -> TimeInterval {",
         "R36: `SigningProgressView` 不许再写死进度"),
        # 把单测改宽：只断言「涨了」而不锁住「明显爬升」，约束就没了。
        ("SealTests/Signing/SigningProgressBudgetTests.swift",
         "        #expect(bundle > 30)",
         "        #expect(bundle > 0)",
         "R36: 单测必须断言「两个长阶段不再一动不动」"),
        # 把 `progress(.preparingBundle)` 撤掉：文案又变回「正在验证 Apple ID」。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "            await progress(.preparingBundle)\n"
         "            let prepareStartedAt = Date()",
         "            let prepareStartedAt = Date()",
         "R32: `progress(.preparingBundle)` 必须发在"),
        # 给 `AppState` 加 case：它 Codable 且持久化，会波及所有 switch 与旧数据。
        ("Seal/Core/Apps/AppState.swift",
         "enum AppState: String, Codable, CaseIterable, Equatable, Sendable {\n"
         "    case imported",
         "enum AppState: String, Codable, CaseIterable, Equatable, Sendable {\n"
         "    case preparingBundle\n"
         "    case imported",
         "R32: **不要**给 `AppState` 加 case"),
        # ── R33：读可重试超时、写绝不可（2026-09-18）──
        # 让「创建证书」也重试超时：会多占一个证书名额（addCertificate 的注释明确禁止）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "try await withSessionRecovery(\"创建证书\") {",
         "try await withSessionRecovery(\"创建证书\", retriesOnTimeout: true) {",
         "R33: **写操作绝不允许重试超时**"),
        # 让「读取 App ID 列表」不再重试超时：限流时的慢响应会直接失败。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "withSessionRecovery(\"读取 App ID 列表\", retriesOnTimeout: true)",
         "withSessionRecovery(\"读取 App ID 列表\")",
         "R33: 读操作必须允许重试超时"),
        # ── R34：features 取证点（2026-09-18）──
        # 删掉它：减请求优化就只能靠猜（盲改会静默丢掉 entitlements）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "            \"App ID features 诊断：账号已有 \\(existing.count) 个 App ID，\"\n",
         "",
         "R34: 必须保留 `fetchAppIDs` 是否回填 `features` 的取证诊断"),
        # 把取证诊断退回「只说 features 非空」：判断不了能不能跳过 updateFeatures。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                + \"（一致的那些理论上可跳过 updateFeatures ⇒ 能省 \\(skipCandidates) 次请求）\"\n",
         "",
         "R34: 取证诊断必须把"),
        # 抽掉「值类型」那一段：判据就缺了最后一块（有列表值时不能跳过）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "                + (typeSample.map { \"；本次要设置的能力与值类型 \\($0)\" } ?? \"\")\n",
         "",
         "R34: 取证诊断必须报出**值类型**"),
        # ── R35：解压前按解压后体积判空间（2026-09-18）──
        # 删掉这次检查：高压缩比的包又会被低估，可能在签名中途写满磁盘。
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "        try validateFreeSpace(\n"
         "            expandedBytes: expandedBytes,\n"
         "            ipaBytes: ipaBytes,\n"
         "            at: workspaceRoot\n"
         "        )\n",
         "",
         "R35: 解压前必须按解压后体积判空间"),
        # 把**前置**磁盘检查退回「压缩体积 × 4」的启发式：它会先拦住能签的机器（假警报）。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "            if let requiredBytes = try? signingWorkspace.requiredTemporarySpace(\n"
         "                forIPAAt: originalIPAURL\n"
         "            ) {",
         "            if let requiredBytes = ((try? FileManager.default.attributesOfItem(\n"
         "                atPath: originalIPAURL.path\n"
         "            ))?[.size] as? NSNumber).map({ UInt64($0.int64Value) * 4 + 200 * 1024 * 1024 }) {",
         "R35: 前置的磁盘检查必须用"),
        # 让 `validate` 不再返回解压总量：空间判断就拿不到真实数字了。
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "    private func validate(_ entries: [Entry]) throws -> UInt64 {",
         "    private func validate(_ entries: [Entry]) throws {",
         "R35: `validate` 必须把解压后总量**返回出去**"),
        # ── R36：先读 4 字节判 magic（2026-09-18）──
        # 退回「先整体读入」：全树遍历会把 1.46 GB 读进内存，有 jetsam 风险。
        # ⚠️ **R37 的锚点是跨多行的块** ✗ —— 在它覆盖的行区间里插任何注释都会让它失配
        #（报成 `Mutation anchor missing`，看着像变异本身有问题 ✓）。
        # 2026-09-19 已经踩了 **三次** ✗ ⇒ 改这段代码时，**注释一律写在
        # `guard let handle = try? FileHandle(...)` 这一行之前** ✓。
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "        guard let handle = try? FileHandle(forReadingFrom: machOURL) else { return }\n"
         "        defer { try? handle.close() }\n"
         "        guard let magicData = try? handle.read(upToCount: 4),\n"
         "              magicData.count == 4 else {\n"
         "            return\n"
         "        }\n"
         "        // MH_MAGIC_64 = 0xfeedfacf（strip arm64e 后全树 thin arm64）\n"
         "        let magic = magicData.withUnsafeBytes {\n"
         "            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)\n"
         "        }\n"
         "        guard magic == 0xfeedfacf else { return }\n"
         "\n"
         "        let rpathNeedle = Data(" + chr(34) + "@executable_path/Frameworks" + chr(34) + ".utf8)\n"
         "        guard containsBytes(rpathNeedle, in: machOURL) else { return }\n"
         "\n"
         "        guard var data = try? Data(contentsOf: machOURL) else { return }\n"
         "        guard data.count >= 32 else { return }\n",
         "        guard var data = try? Data(contentsOf: machOURL, options: .mappedIfSafe) else { return }\n"
         "        guard data.count >= 32 else { return }\n"
         "        guard data.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })\n"
         "            == 0xfeedfacf else { return }\n",
         "R37: 判 Mach-O magic 必须"),
        # ── R38：签名缓存（2026-09-18）──
        # ⚠️ **已随 `Vendor/rork-sign` 删除**（2026-09-19）✗ —— 断言与锚点的对象都是
        # `Seal/Infrastructure/Signing/RorkAppSigner.swift`，那个文件已删 ✓。
        # 🔴 **知识留档**：上游 `SideSign` / `CodeSignKit` **没有签名缓存** ✗
        # ⇒ Seal 现在每次续签都是**全量重签** ✗，大包的 CPU 预算压力因此更大 ✓。
        # ── R39：阶段进入落日志（2026-09-18）──
        # 删掉它：阶段切换在日志里又没了时间戳 ⇒ 「每阶段耗时」拿不到。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        if stage != currentStage {\n"
         "            let entered = stage\n"
         "            Task { [logStore] in\n"
         "                try? await logStore?.append(\n"
         "                    category: .signing,\n"
         "                    level: .info,\n"
         "                    message: \"阶段进入：\\(entered)\",\n"
         "                    code: \"SEAL-STAGE-001\"\n"
         "                )\n"
         "            }\n"
         "        }\n",
         "",
         "R39: 阶段进入必须落日志"),
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "            let freshSession = { (label: String) async -> ALTAppleAPISession? in\n",
         "",
         "R43: `prepare` 之后必须**重建会话**"),
        # ── R44：阳性对照的判别性诊断（2026-09-19）──
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "            for sample in [\"com.apple.Preferences\", \"com.apple.mobilesafari\"] {\n",
         "",
         "R44: 阳性对照失败时必须输出**判别性诊断**"),
        # ── R58：阳性对照失败的诊断必须带耗时（2026-09-20 真机）──
        # 去掉耗时：日志里「超时」与「抛错」又分不开了。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         'String(format: "(%.1fs)", seconds)',
         "",
         "R58: 阳性对照失败时必须输出**带耗时的**探测结果"),
        # ── R58b：TimedProbe 必须显式遵循 CustomStringConvertible（2026-09-20 真机）──
        # 去掉遵循：插值走合成的 memberwise 描述 ⇒ 日志里打出原始结构体并被截断 ✗。
        ("Seal/Infrastructure/Installation/DeviceProfileCleaner.swift",
         "struct TimedProbe: CustomStringConvertible",
         "struct TimedProbe",
         "R58b: `TimedProbe` 必须显式遵循 `CustomStringConvertible`"),
        # ── R59：QQ 加群的两条路径（2026-09-20）──
        # 删掉短链兜底：没装 QQ 的用户点进去没有任何反应。
        ("Seal/Features/Settings/SealCommunityView.swift",
         "private let qqJoinURL",
         "private let qqFallbackRemoved",
         "R59: 「加入 QQ 群」必须保留**两条路径**"),
        # ── R60：发布正文只取当前版本一节（2026-09-20）──
        # 换回 `cat` 整个文件：更新弹窗会列出所有历史版本（含内部术语）。
        # ⚠️ 锚点是**两条 shell 行**（含续行反斜杠）✗ —— 在它区间里插东西会失配，
        #    改这段时把锚点一起更新 ✓。
        (".github/workflows/ios.yml",
         "          NOTES=\"$(awk '/^# /{ if (found) exit; found=1 } found' RELEASE_NOTES.md \\\n"
         "            | sed -e '/^---[[:space:]]*$/d' -e 's/[[:space:]]*$//' | cat -s)\"",
         '          NOTES="$(cat RELEASE_NOTES.md)"',
         "R60: 发布正文必须**只取第一个版本一节**"),
        # ── R60b：发布说明的第一个版本必须是最高的（2026-09-20）──
        # 把**第一个** `# ` 标题降级成 `## `：它就不再被 `^# (\d+)` 认作版本标题 ✗
        # ⇒ 解析出的「第一个版本」变成 1.1.16 ≠ 最高版本 ⇒ R60b 失败 ✓。
        #
        # ⚠️ 锚点**故意只写 `# `**（不带版本号、不带标题文案）✗ ——
        # 第一版我写成 `# 1.2.0：修好「签大包时 Seal 被系统杀掉」` ✗，
        # 结果**当天就把标题改了两次**（→「优化部分应用无法签名」→ 去掉全角冒号）✗✗
        # ⇒ CI 报 `Mutation anchor missing` ✗（本地那次 PASS 是在改标题**之前**跑的 ✗）。
        # ⇒ **发布说明的标题每次发版都会改** ✓ ⇒ 锚点绝不能依赖它 ✓。
        ("RELEASE_NOTES.md",
         "# ",
         "## ",
         "R60b: `RELEASE_NOTES.md` 的**第一节版本必须等于 `MARKETING_VERSION`**"),
        # ── R61：就绪探测必须用**短预算**、且**便宜判据在前**（2026-09-20 真机，构建 184）──
        # ① 把**就绪探测**改回默认的 15 秒预算（= 上游写法）⇒ 每轮白等 15 秒、
        #    36 轮 ≈ 9 分钟 ⇒ R61③ 失败 ✓。
        #    ⚠️ 锚点写**完整调用**（含 `try` 与参数）✓ —— 只写 `getFirstDevice(` 会先命中
        #    别处，且读起来不知道改的是哪个调用点 ✗。
        #    ⚠️ `replace(old, new, 1)` 只改**第一处** ✓ —— 文件里第一处正是 `ready()` ✓
        #    （`fetchUDIDDetailed()` 在它后面）⇒ ③ 会因 `ready_body` 里没有短预算而失败 ✓。
        ("Vendor/Minimuxer/Sources/Minimuxer.swift",
         "try Device.getFirstDevice(timeoutMs: MuxerConstants.probeDeviceFetchTimeoutMs)",
         "try Device.getFirstDevice()",
         "R61③: `ready()` / `fetchUDIDDetailed()` 必须显式传**短预算** ✗"),
        # ② **只把预算改短、没改顺序**（探测仍无条件跑在便宜判据之前）⇒
        #    ③ 照样绿（预算确实短了），但「隧道没通」这条最坏路径每轮仍要多付一轮探测 ⇒
        #    R61④ 失败 ✓。**这条专门证明 ④ 不是空转** ✓
        #    （否则「只查短预算」的写法能把上游顺序一起骗过去 ✗）。
        ("Vendor/Minimuxer/Sources/Minimuxer.swift",
         "        guard deviceConnection, Heartbeat.lastBeatSuccessful, "
         "Muxer.started, Muxer.usbmuxdReady else {",
         "        _ = try Device.getFirstDevice(timeoutMs: MuxerConstants.probeDeviceFetchTimeoutMs)\n"
         "        guard deviceConnection, Heartbeat.lastBeatSuccessful, "
         "Muxer.started, Muxer.usbmuxdReady else {",
         "R61④: `ready()` 里便宜判据必须在 `getFirstDevice()` **之前** ✗"),
        # ── R45：重签前的分界日志（2026-09-19）──
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "签名：开始重签（逐 Mach-O 串行）",
         "签名：重签开始（分界日志已删）",
         "R45: 重签前必须有「分界日志」"),
        # ── R46：签名器逐 bundle 诊断必须打开（2026-09-19）──
        # ⚠️ **已随 `Vendor/rork-sign` 删除**（2026-09-19）✗ —— 断言与锚点的对象都是
        # `Seal/Infrastructure/Signing/RorkAppSigner.swift`，那个文件已删 ✓。
        # 🔴 **知识留档**：换签名器后「死在哪个 bundle」**看不出来了** ✗ ——
        # 上游 `SideSign` 的 `verboseLog` 走 `print`（进不了 Seal 的导出日志 ✗），
        # `signApp(progress:)` 只有计数、没有回调 ✓ ⇒ 真机回归时靠「日志戛然而止」推断 ✓。
        # ── R47：Bundle ID 报错要说清是 Apple 的规定（2026-09-19）──
        ("Seal/Core/Signing/BundleIDPolicy.swift",
         "Apple 规定", 
         "Seal 规定", 
         "R47: Bundle ID 的报错必须说清「这是 Apple 的规定」"),
        # ── R48：签名器诊断必须过滤（2026-09-19）──
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "static func isUsefulSigningDiagnostic(",
         "static func isUsefulSigningDiagnosticREMOVED(", 
         "R48: 签名器诊断的**过滤规则**必须保留"),
        # ── R49：判 Mach-O 不许整块读入（2026-09-19）──
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "guard var data = try? Data(contentsOf: machOURL) else { return }",
         "guard var data = try? Data(contentsOf: machOURL, options: .mappedIfSafe) else { return }",
         "R49: `rewriteExecutablePathReferences` 会**原地改写**这份 Data"),
        # ── R50：会被**原地改写**的 Data 绝不许 mmap（2026-09-19 真机 SIGBUS）──
        # ⚠️ **已随 `Vendor/rork-sign` 删除**（2026-09-19）✗ ⇒ **判据改由 R57 承接** ✓
        #（同一条「mmap 读 + 复制后改」现在钉在上游 `CodeSignKit` 上 ✓）。
        #
        # ── R52：签名器 FairPlay 补丁（2026-09-19）──
        # ⚠️ **已随 `Vendor/rork-sign` 删除**（2026-09-19）✗ ——
        # 🔴 **但这是换签名器引入的「最高严重级」已知风险** ✗：
        #   `CodeSignKit/MachOParser.swift:555` 只有「读 cryptid」、**没有清零** ✓，
        #   `SideSign` / `SideStore` 也完全不处理 ✗ ⇒ **可能「装完启动崩」** ✗✗。
        # ⇒ 真机回归**必须专门验证「装完能不能启动」** ✓；
        #    若真的启动崩，把那个补丁移植到 `CodeSignKit` ✓
        #   （原型见 `Vendor/rork-sign` 的历史提交 `b548021` ✓）。
        #
        # ── R57：上游签名内核的内存策略（2026-09-19，承接 R50）──
        # 改成整块读 ⇒ 抖音签名的内存峰值回到 2.11 GB ⇒ jetsam 批量杀后台 ✗。
        ("Vendor/CodeSignKit/Sources/MachOParser.swift",
         "Data(contentsOf: execURL, options: .mappedIfSafe)",
         "Data(contentsOf: execURL)",
         "R57: 上游 `CodeSignKit/MachOParser` 必须**用 mmap 读**"),
        # ── R53：分块预扫描必须在整块读之前（2026-09-19）──
        ("Seal/Infrastructure/Signing/SigningWorkspace.swift",
         "        guard containsBytes(rpathNeedle, in: machOURL) else { return }\n",
         "",
         "R53: `rewriteExecutablePathReferences` 必须先**分块预扫描**"),
        # ── R54：ios.yml 触发路径必须覆盖整个 Vendor（2026-09-19）──
        (".github/workflows/ios.yml",
         '      - "Vendor/**"',
         '      - "Vendor/Minimuxer/**"',
         "R54: `ios.yml` 的 push 触发路径必须覆盖整个 `Vendor/**`"),
        # ── R55：身份读取必须走 MachOParser（2026-09-19）──
        ("Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift",
         "try? MachOParser(url: executableURL)",
         "try? RorkSigner.checkMachOCodeSignatures(at: executableURL)",
         "R55: 签名身份读取必须走上游 `MachOParser`（mmap ✓）"),
        # ── R40：102c 不得标失效（2026-09-18 真机）──
        # 删掉排除：账号又会在「紧接 3 次限流退避之后」被标成失效 ⇒ 死循环。
        ("Seal/Core/Accounts/AppleServiceFailurePolicy.swift",
         "        if code == \"SEAL-AUTH-102c\" { return nil }\n",
         "",
         "R40: `SEAL-AUTH-102c` 不得标记账号失效"),
        # ── R41：拆出各段耗时（2026-09-19）──
        # 把日志里「改写」那一段删掉：四段又只剩三段，定位能力退化。
        ("Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
         "prepared.rewriteSeconds",
         "",
         "R41: `prepare` 的耗时必须**拆到每一段**"),
        # 去掉 1100 的专门文案：又落回「没有返回明确失败原因」，
        # 用户不知道账号可能已经被清空、需要立刻重新创建一张证书。
        ("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift",
         "            if ApplePortalSigningService.isSessionExpiredError(error) {\n"
         "                throw Self.failure(\n"
         "                    title: \"新证书没有创建成功\",",
         "            if false {\n"
         "                throw Self.failure(\n"
         "                    title: \"新证书没有创建成功\",",
         "R30: 证书创建遇 1100 的文案必须写明"),
        # 把结算单测改名：证明「单测文件里有这几个字」的断言真的会红。
        ("SealTests/Renewal/RefreshQueueStoreTests.swift",
         "    func recoverInterruptedSettlesItemsThatAlreadyHaveAResult() async throws {",
         "    func recoverInterruptedSettlesItemsThatAlreadyHaveAResultRenamed() async throws {",
         "R17: settling instead of downgrading needs real unit tests"),
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "            ipaRelativePath: \"Apps/\\(appID.uuidString)/Original.ipa\",\n            signedArtifactStatus: signedArtifactStatus,",
         "            signedArtifactStatus: signedArtifactStatus,\n            ipaRelativePath: \"Apps/\\(appID.uuidString)/Original.ipa\",",
         "R09: AppRecord call-site labels must follow the declaration order"),
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                        selectedCertificateSerialNumber: nil,\n                        forceResign: true,",
         "                        forceResign: true,\n                        selectedCertificateSerialNumber: nil,",
         "R09: signAndInstall call-site labels must follow the declaration order"),
        ("Seal/Core/Signing/InstallStageBridge.swift",
         "uploadProgress > uploadCompletionSentinel",
         "uploadProgress >= uploadCompletionSentinel",
         "R10: 1.0 means 'upload finished', not 'installing'"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                onProgress: bridgedInstallProgress(\n                    broadcastsInstallStage: broadcastsInstallStage,\n                    progress: progress,\n                    onInstallProgress: onInstallProgress\n                )",
         "                onProgress: onInstallProgress",
         "R10: the ordinary-app install path is the one that used to stall"),
        ("Seal/Core/Signing/SigningCoordinator.swift",
         "                await progress(.installing)\n            }\n            await onInstallProgress(installProgress)",
         "                _ = progress\n            }\n            await onInstallProgress(installProgress)",
         "R10: the bridge must actually emit .installing"),
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                        onInstallProgress: { installProgress in",
         "                        onInstallProgressUnused: { installProgress in",
         "R10: batch renewal must subscribe to the upload percentage"),
        # 把新事件「收编」回旧事件：编译通过、事件流还在，但抽屉重新变成没有分母的黑盒。
        ("Seal/Core/Renewal/RenewalCoordinator.swift",
         "                                .appInstallProgress(\n                                    index: offset + 1,\n                                    total: queue.count,\n                                    app: latestApp,\n                                    progress: installProgress\n                                )",
         "                                .appProgress(\n                                    index: offset + 1,\n                                    total: queue.count,\n                                    app: latestApp,\n                                    stage: .pushing\n                                )",
         "R10: batch renewal must forward the real upload percentage"),
        ("Seal/Features/Apps/BatchRefreshView.swift",
         "        SealDrawer(title: drawerTitle, showsFooter: true) {",
         "        SealDrawer(title: drawerTitle, showsFooter: !isRunning) {",
         "R10: hiding the footer while running removes the only way out of a stuck run"),
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        SealDrawer(title: title, showsFooter: true) {",
         "        SealDrawer(title: title, showsFooter: !isRunning) {",
         "R10: hiding the footer while running removes the only way out of a stuck run"),
        # 把 `.inactive` 改回「放弃」= 原样重演 2026-09-16 的「永久停在 93%」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        case .inactive:\n            return .waitForForeground",
         "        case .inactive:\n            return .standDown",
         "R10: .inactive is a transient blur"),
        # 把 `.background` 也接上转场：后台状态下 `suspend` 不一定生效（进程本来就不在前台），
        # 而 `.standDown` 这条路径承担的是「等用户回来、等不到就强杀」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "        case .background:\n            return .standDown",
         "        case .background:\n            return .triggerTransition",
         "R10: only a real background transition means the user left"),
        # `.inactive` 等够 3 秒改成直接放弃等待：控制中心一遮挡就会走到 exit(0)，
        # 在用户还在前台时把进程杀掉，安装永远完不成。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "                inactiveRounds += 1\n"
         '                await log(logStore, "Seal 自替换：当前为瞬时失焦，等待回到前台")\n'
         "                try? await Task.sleep(nanoseconds: inactiveRetryNanoseconds)",
         "                return",
         "R10: .inactive must actually be waited out"),
        # 让 `.standDown` 恢复旧实现那套「立即放弃」：进程既不转场也不退出、永久占着前台，
        # iOS 永远等不到替换时机 —— 这正是 2026-09-16 真机两次自续签都停在 93% 的原因。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            case .standDown:\n"
         "                guard outcome == .wait else {",
         "            case .standDown:\n"
         "                guard false else {",
         "R10: .standDown must wait for the user to come back, then force exit"),
        # `.standDown` 的等待改成无限：不再是「放弃」，却变成了另一种永久卡住。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            return waited < backgroundWaitSeconds ? .wait : .act",
         "            return .wait",
         "R10: the background wait must be bounded"),
        # 把等待循环里 `poll` 的结果丢掉：函数还在、单测还在，约束已经失效。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            let outcome = poll(\n"
         "                for: currentStep,\n"
         "                waited: Date().timeIntervalSince(startedAt),\n"
         "                rounds: inactiveRounds\n"
         "            )",
         "            let outcome = SelfInstallAutoBackground.PollOutcome.wait",
         "R10: the wait loop must route through the tested step/poll functions"),
        # 让「触发转场」的日志排在 `triggerHomeTransition` **之后**：`suspend` 生效即冻结
        # 进程，这行日志就永远出不来 —— 下次真机排查又只剩「一片空白」。
        ("Seal/Features/Apps/SigningProgressView.swift",
         '                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")\n'
         "                triggerHomeTransition(app)",
         "                triggerHomeTransition(app)\n"
         '                await log(logStore, "Seal 自替换：触发回主屏转场（suspend）")',
         "R10: the suspend log must be flushed before the process is frozen"),
        # 调用点传 nil = 「回主页」这条链路重新变回静默（只声明依赖不等于接上了）。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: logStore)",
         "SelfInstallAutoBackground.returnToHomeAfterSealUpload(logStore: nil)",
         "R10: both signing paths must trigger the return-home with a real log outlet"),
        # 去掉批量链路的 `.restart` 闸门：`.installing` 重复推送时会排出多个「回主页」任务，
        # 每个都写一遍日志，把真机排查要看的时序淹没。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "                if stage == .installing, tick == .restart {",
         "                if stage == .installing {",
         "R10: a repeated .installing push must not spawn a second return-home"),
        # 让等待循环不再走被测过的 step()：函数还在，约束已经失效。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "            let currentStep = step(for: app.applicationState)",
         "            let currentStep = SelfInstallAutoBackground.ReturnHomeStep.triggerTransition",
         "R10: the wait loop must route through the tested step/poll functions"),
        # 重复推送也重置起点 = 「已等待」永远停在 0:0x，比不显示更像卡死。
        ("Seal/Core/Signing/InstallStageTimeline.swift",
         "        return currentStage == .installing ? .keep : .restart",
         "        return currentStage == .installing ? .restart : .restart",
         "R10: repeated .installing pushes must not reset the install clock"),
        # 让单签的「回主页」永不触发：Seal 的替换静默失败（旧版本继续跑）。
        ("Seal/Features/Apps/AppsViewModel.swift",
         "        if stage == .installing,\n           tick == .restart,\n           signingSession?.app.isSeal == true {",
         "        if stage == .installing,\n           tick == .restart,\n           signingSession?.app.isSeal == false {",
         "R10: single signing must trigger the return-home from the state layer"),
        # 界面又自己触发一次 = 双重「回主页」（两个转场 + 两个 exit(0) 兜底）。
        ("Seal/Features/Apps/SigningProgressView.swift",
         "                withAnimation(.easeInOut(duration: 0.45)) {\n                    isReturningHome = true\n                }",
         "                withAnimation(.easeInOut(duration: 0.45)) {\n                    isReturningHome = true\n                }\n                SelfInstallAutoBackground.returnToHomeAfterSealUpload()",
         "R10: the view must not trigger the return-home"),
        # 批量链路自己再抄一份规则：漂移不会编译失败，只会让抽屉的计时变成假象。
        ("Seal/Core/Renewal/BatchRefreshSession.swift",
         "        let tick = InstallStageTimeline.tick(entering: stage, currentStage: currentStage)",
         "        let tick = stage == .installing ? InstallStageTimeline.Tick.restart : InstallStageTimeline.Tick.clear",
         "R10: Seal/Core/Renewal/BatchRefreshSession.swift must use the shared install-start rule"),
        # 自替换等待改用「超时就取消工作」：取消信号会传回 Rust 侧，
        # 可能撤销已经下发的 installation_proxy 命令 —— 把「可能还在装」变成「确定装不上」。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            _ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: false) {",
         "            _ = try await HardTimeout.run(seconds: budget, cancelsWorkOnTimeout: true) {",
         "R10: the self-replacement wait must stop waiting without cancelling the FFI"),
        # 在别处再裸等一遍 `installation.value` = 重新引入一条没有超时的等待路径。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "                try await installation.value\n                return true\n            }",
         "                try await installation.value\n                return true\n            }\n            try await installation.value",
         "R10: installation.value may only be awaited inside the watchdog"),
        # 去掉单飞闸门：91 秒内两笔自替换安装会在同一 Bundle ID 上造出两个 installd。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "        guard selfReplacementGate.acquire() else {",
         "        guard true else {",
         "R10: a second concurrent self-replacement install must be refused"),
        # 超时也解锁闸门：底层同步 FFI 很可能还在跑，第二笔就成了并发安装。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "            selfReplacementGate.release(timedOut: Self.isTimeoutInstallError(error))",
         "            selfReplacementGate.release(timedOut: false)",
         "R10: a timeout must keep the self-replacement gate closed (the FFI is still running)"),
        # 去掉共用心跳里的日志：两条路径同时重新变成「卡住时一片空白」，
        # 无法区分在装和死了。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         '                await self?.log("\\(label)仍在等待：已等待 \\(waited) 秒（installd 安装阶段不回报进度）")',
         "                _ = waited",
         "R10: the install wait needs a heartbeat — installd reports no progress"),
        # 容器不再把日志出口交给安装通道 = 日志通道永远静默（只声明依赖不等于接上了）。
        ("Seal/Application/AppContainer.swift",
         "                logStore: logStore\n            )",
         "                logStore: nil\n            )",
         "R10: AppContainer must hand the install channel a real log store"),
        # 把设备专属符号的定义挪回 `#if !targetEnvironment(simulator)` 里 = 原样重演
        # 2026-09-16 的「模拟器切片缺符号」：`build-package` 照样绿，只有
        # `swift-regression` 红。这条变异同时证明上面的检查确实在检查，而不是空转。
        ("Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
         "    private static func isTimeoutInstallError(_ error: Error) -> Bool {\n"
         "        if error is HardTimeout.TimeoutError { return true }\n"
         "        if let failure = error as? ImportFailure,\n"
         "           failure.code == installTimeoutFailure.code {\n"
         "            return true\n"
         "        }\n"
         "        return false\n"
         "    }",
         "    #if !targetEnvironment(simulator)\n"
         "    private static func isTimeoutInstallError(_ error: Error) -> Bool {\n"
         "        if error is HardTimeout.TimeoutError { return true }\n"
         "        if let failure = error as? ImportFailure,\n"
         "           failure.code == installTimeoutFailure.code {\n"
         "            return true\n"
         "        }\n"
         "        return false\n"
         "    }\n"
         "    #endif",
         "Simulator: device-only members"),
        # 把 mutating 调用挪回 `#expect(...)` 里 = 原样重演 2026-09-16 的
        # `cannot use mutating member on immutable value: '$0' is immutable`
        # （同样只在 `swift-regression` 红）。
        ("SealTests/Installation/SelfReplacementInstallGateTests.swift",
         "        #expect(first)",
         "        #expect(gate.acquire())",
         "#expect must not call a mutating method"),
        # 把 `Set(keepMap.keys)` 写回 `Set(keepMaps.first?.keys ?? [])`：原样重演
        # `cannot convert value of type '[Any]' to expected argument type
        # 'Dictionary<String, String>.Keys'`（同样只在 `swift-regression` 红）。
        ("SealTests/Maintenance/AppMaintenanceJobTests.swift",
         "        let keptKeys = Set(keepMap.keys)",
         "        let keptKeys = Set(keepMaps.first?.keys ?? [])",
         "`?? []` after .keys/.values cannot type-check"),
        # 把带插值的注释参数换回 `String` 变量：原样重演 2026-09-21 的
        # `cannot convert value of type 'String' to expected argument type 'Comment?'`
        # （同样只在 `swift-regression` 红，一轮白等 4.5 分钟）。
        ("SealTests/Pairing/PairingStoreTests.swift",
         r'                "缺少 \(key) 时不应判定为完整的 Lockdown 配对文件"',
         "                key",
         "#expect must not pass a bare identifier as its comment"),
        # R68: 把全局默认改回 17.0 ⇒ 所有 target 一起退回 iOS 17（本轮要守的核心）✓ 报红。
        ("Config/Base.xcconfig",
         "IPHONEOS_DEPLOYMENT_TARGET = 16.0",
         "IPHONEOS_DEPLOYMENT_TARGET = 17.0",
         "R68:"),
        # R68: **只**把 Seal 这一个 target 改回 17.0 —— 这是「漏改一处」的真实形态，
        # 比整份退回更隐蔽（其它三个 target 还是 16.0，粗看像没事）✓ 报红。
        # ⚠️ 锚点带上 target 名与 `type: application`：`deploymentTarget: "16.0"`
        # 在文件里出现 4 次，只写它虽然也能命中（`replace(…, 1)` 取第一个），
        # 但带上下文能保证**变异打在 Seal 这个 target 上**、与注释一致 ✓。
        ("project.yml",
         '  Seal:\n    type: application\n    platform: iOS\n    deploymentTarget: "16.0"',
         '  Seal:\n    type: application\n    platform: iOS\n    deploymentTarget: "17.0"',
         "R68:"),
        # R69: 把 iOS 16 用例从 workflow 的 `required` 清单里删掉 ⇒ 「外部」那道闸门失效，
        # 只剩 `patch_upstream.py` 自己那份 = 自洽判据 ✓ 报红。
        (".github/workflows/pairing-assistant.yml",
         "            'seal_ios_supports_remote_pairing(\"16.0\")',\n",
         "",
         "R69:"),
    ]
    # 变异检查每一遍都会把所有源文件**重新读一遍**：200+ 文件 × 90 多遍 ≈ 2 万次磁盘读。
    # 本仓在 OneDrive 同步目录里，单次读延迟不稳定 —— 实测同一份代码整轮耗时在
    # 61–117 秒之间波动，已经贴到命令默认 120 秒超时（超时会被 SIGTERM，且**没有任何
    # 输出**，很容易误判成脚本崩了）。`base_read` 就是上面那个按路径缓存的读取器。
    for path, old, new, expected in mutations:
        original = base_read(path)
        if old not in original:
            # ⚠️ 报错必须带**锚点文本**：只说文件名的话，一个文件里有十几个变异时
            # 根本不知道是哪一个（2026-09-18 为此白跑了一整轮守卫）。
            failures.append(
                "Mutation anchor missing: " + path + "\n  anchor=" + repr(old[:160])
            )
            continue
        changed = original.replace(old, new, 1)
        try:
            _, mutated_failures = violations(lambda p: changed if p == path else base_read(p))
        except AssertionError as error:
            # 变异把某条 `section()` 的标记删掉了 ⇒ 守卫崩掉，一条失败都报不出来。
            # 这**本身就是**「变异破坏了被断言的结构」，按失败报出来 ——
            # 别让调用者看到一段 Python 栈，误以为守卫自己坏了（2026-09-17 实际踩到）。
            # 修法是那一处改用 `section_or_empty()`。
            failures.append(
                "Guard crashed while checking a mutation (a section() marker was removed "
                "by the mutation — that call site should use section_or_empty()): "
                + str(error)
            )
            continue
        if not any(item.startswith(expected) for item in mutated_failures):
            failures.append("Guard failed mutation check: " + expected)
    print("Source regression checks: " + str(count))
    print("Guard mutation checks: " + str(len(mutations)))
    if failures:
        for failure in failures:
            print("FAIL: " + failure)
        return 1
    print("PASS. Static guards only; Swift/Rust compilation and device regression still required.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
