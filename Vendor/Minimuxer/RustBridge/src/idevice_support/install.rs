// Jackson Coxson

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::{Mutex, OnceLock};

use idevice::{
    afc::{errors::AfcError, opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};
use tokio::io::AsyncWriteExt;

use crate::idevice_support::rsd::connect_to_rsd_services;

/// AFC 暂存根目录（相对 AFC jail 根）。
const STAGING_DIR: &str = "PublicStaging";

/// 暂存文件统一用固定 ASCII 名。
/// installd 只按 PackagePath 读包、不依赖文件名，固定名等价且排除非 ASCII 编码问题。
pub(crate) const IPA_STAGING_NAME: &str = "app.ipa";

/// 暂存布局：`PublicStaging/<bundleId>/app.ipa`——与经典 lockdown 通道完全一致。
/// 本设备 PublicStaging 里留有 bundleId 目录（历史成功安装的痕迹），对齐它最稳。

/// yeet / install 两次独立 FFI 之间传递暂存信息（文件名+字节数）的进程内缓存。
///
/// 背景：jas 的 `install_ipa` 在同一个函数内完成签名→打包→AFC 上传→installd 安装，
/// ipa_name 已知，install 从不做 AFC `list_dir` 回读。Seal 因 FFI 边界把 yeet（上传）
/// 与 install（触发安装）拆成两次调用，install 只收 `bundle_id`，此前被迫 list_dir 回读
/// ——而 RSD / CoreDevice 隧道下 AFC `list_dir` 在部分设备上不可靠。此处用进程内缓存
/// 传递文件名与期望大小（install 阶段校验文件仍在且大小一致），list_dir 仅作 fallback。
static IPA_NAME_CACHE: OnceLock<Mutex<HashMap<String, (String, usize)>>> = OnceLock::new();

fn cache_ipa_name(bundle_id: &str, ipa_name: &str, size: usize) {
    let map = IPA_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = map.lock() {
        guard.insert(bundle_id.to_string(), (ipa_name.to_string(), size));
    }
}

fn cached_ipa(bundle_id: &str) -> Option<(String, usize)> {
    let map = IPA_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    map.lock().ok().and_then(|guard| guard.get(bundle_id).cloned())
}

/// 构造 InstallationProxy 的 ClientOptions（RSD / CoreDevice 通道）。
///
/// 逐行对齐 jas `install_ipa`（第 675-679 行）：只放 `PackageType = Developer`。
/// Bundle 标识交给 installd 从 .ipa 包内 Info.plist 自读，不传 CFBundleIdentifier。
fn developer_client_options() -> Value {
    let mut opts = Dictionary::new();
    opts.insert("PackageType".into(), "Developer".into());
    Value::Dictionary(opts)
}

/// 建目录，忽略「已存在」（afcd 对已存在目录回 ObjectExists，幂等创建），
/// 其余错误照常上抛。
async fn mkdir_idempotent(afc: &mut AfcClient, path: &str) -> Result<(), IdeviceError> {
    match afc.mk_dir(path.to_string()).await {
        Ok(()) => Ok(()),
        Err(IdeviceError::Afc(AfcError::ObjectExists)) => Ok(()),
        Err(other) => Err(other),
    }
}

fn zip_error(error: zip::result::ZipError) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("无法读取 IPA 压缩包: {error}"))
}

/// 从 IPA（内存字节）定位唯一主程序目录 `Payload/<Name>.app/`，返回 `<Name>.app`。
/// 用于派生设备端暂存文件名 `<Name>.ipa`（对齐 jas：app_name.trim_end(".app") + ".ipa"）。
fn detect_application_name(ipa_bytes: &[u8]) -> Result<String, IdeviceError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(ipa_bytes)).map_err(zip_error)?;
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(zip_error)?;
        let name = entry.name();
        let tail = match name.strip_prefix("Payload/") {
            Some(value) => value,
            None => continue,
        };
        let top = tail.split('/').next().unwrap_or("");
        if top.ends_with(".app") {
            return Ok(top.to_string());
        }
    }
    Err(IdeviceError::UnexpectedResponse(
        "IPA 内未找到 Payload/*.app 主程序目录".into(),
    ))
}

/// 给错误附加上下文（阶段名 + 现场快照），保留原始 Debug 信息。
/// 远程排障时设备弹窗里能直接看到失败发生在哪一步、暂存目录里有什么。
fn ctx(error: IdeviceError, stage: &str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("{stage}: {error:?}"))
}

/// 把签名后的 IPA 逐字节上传到设备 AFC 暂存区（RSD / CoreDevice 通道）。
pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let mut afc = connect_to_rsd_services::<AfcClient>()
        .await
        .map_err(|e| ctx(e, "yeet/连接AFC"))?;
    stage_via_afc(&mut afc, &bundle_id, ipa_bytes).await
}

/// 上传 + 安装合并调用：**安装主链路（唯一路径）**。
///
/// 会话不变量（真机验证的官方形态，jas install_ipa 与 SideStore IdeviceGateway 一致）：
/// 上传与安装必须发生在同一条缓存的 RemotePairing 隧道会话上
/// （connect_to_rsd_services 的进程内缓存）。隧道 RSD 只暴露 *.shim.remote 服务，
/// shim afcd 的暂存视图绑定在该会话上——跨会话（每次新建隧道）暂存包对 installd
/// 完全不可见，正是历史 MissingPackagePath 的根因。因此禁止把上传与安装拆到
/// 各自新建的隧道；上传后 drop AFC 客户端是安全的（jas 同样如此）。
pub async fn stage_and_install_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let mut afc = connect_to_rsd_services::<AfcClient>()
        .await
        .map_err(|e| ctx(e, "yeet/连接AFC"))?;
    stage_via_afc(&mut afc, &bundle_id, ipa_bytes).await?;
    drop(afc);
    install_ipa_rppairing(bundle_id).await
}

/// 在给定 AFC 连接上完成暂存（幂等建目录、整包写入、同连接回读校验）。
/// 供 shim 通道与 CoreDevice 隧道通道复用。
pub(crate) async fn stage_via_afc(
    afc: &mut AfcClient,
    bundle_id: &str,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    // 结构校验：IPA 内必须存在 Payload/*.app（上传前拦截损坏包）
    let _application_name = detect_application_name(ipa_bytes)?;
    let staged_dir = format!("{STAGING_DIR}/{bundle_id}");
    let afc_path = format!("{staged_dir}/{IPA_STAGING_NAME}");

    // 幂等建目录（afcd 对已存在目录回 ObjectExists）
    mkdir_idempotent(afc, STAGING_DIR)
        .await
        .map_err(|e| ctx(e, "yeet/建PublicStaging目录"))?;
    mkdir_idempotent(afc, &staged_dir)
        .await
        .map_err(|e| ctx(e, "yeet/建暂存子目录"))?;

    // WrOnly=3（O_WRONLY|O_CREAT|O_TRUNC），文件不存在时创建。
    // 与原版 SideStore minimuxer 一致：不做预删除（TRUNC 已保证覆盖），
    // 且 shim 通道上 remove 与 write 的提交顺序不可控，不做多余操作。
    let mut handle = afc
        .open(afc_path.clone(), AfcFopenMode::WrOnly)
        .await
        .map_err(|e| ctx(e, "yeet/打开暂存包"))?;

    if !ipa_bytes.is_empty() {
        // 对齐上游 jas install_ipa：分块写入并在每块后按已写字节折算为 0-100 上报。
        // 底层 AFC 本就按 1MiB 自动分块，这里只为了让大 IPA 传输阶段有可见进度
        // （带宽不变，纯进度反馈），并避免一次性整块写入占住内存。
        let total = ipa_bytes.len();
        let chunk = (total / 20).max(256 * 1024);
        let mut written = 0usize;
        let mut last_pct = 0u64;
        for piece in ipa_bytes.chunks(chunk) {
            handle
                .write_all(piece)
                .await
                .map_err(|e| ctx(IdeviceError::Socket(e), "yeet/写入暂存包"))?;
            written += piece.len();
            let pct = (written * 100 / total) as u64;
            if pct > last_pct {
                upload_cb(pct);
                last_pct = pct;
            }
        }
        if last_pct < 100 {
            upload_cb(100);
        }
    }

    // close 显式刷写；afc 仍可继续用于回读校验
    handle
        .close()
        .await
        .map_err(|e| ctx(e, "yeet/关闭暂存包"))?;

    // 上传后同连接回读校验：文件必须存在且大小与源字节一致。
    let info = afc
        .get_file_info(afc_path.clone())
        .await
        .map_err(|e| ctx(e, "yeet/回读校验暂存包"))?;
    if info.size != ipa_bytes.len() {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "yeet/暂存包大小校验失败：{afc_path} 设备上 {} 字节，期望 {} 字节",
            info.size,
            ipa_bytes.len()
        )));
    }

    // 把暂存文件名与期望大小存入进程内缓存，供 install 阶段使用。
    // 仅在上传成功且校验通过后写入；yeet 失败时不污染缓存。
    cache_ipa_name(bundle_id, IPA_STAGING_NAME, ipa_bytes.len());

    Ok(())
}

/// 原版 SideStore minimuxer 的 ClientOptions：只带 CFBundleIdentifier。
/// RSD shim 的 instproxy 与经典 lockdown instproxy 行为一致，依赖它定位暂存包；
/// 不带它（jas 式只传 PackageType=Developer）时 installd 报 MissingPackagePath。
fn original_client_options(bundle_id: &str) -> Value {
    let mut dict = Dictionary::new();
    dict.insert("CFBundleIdentifier".into(), bundle_id.into());
    Value::Dictionary(dict)
}

/// 安装命令候选（PackagePath, ClientOptions）：按已验证形态优先。
/// 首选 = 官方 SideStore minimuxer（develop 分支 IdeviceGateway.swift）的精确形态：
/// 无 ./ 前缀 + ClientOptions 传空（FFI 侧传 nil）。iOS 17/18 上大量验证过。
fn install_candidates(bundle_id: &str, file_name: &str) -> Vec<(String, Value)> {
    let empty = Value::Dictionary(Dictionary::new());
    let original = original_client_options(bundle_id);
    let developer = developer_client_options();
    vec![
        // 官方精确形态：无 ./ 前缀 + 空 ClientOptions
        (
            format!("{STAGING_DIR}/{bundle_id}/{file_name}"),
            empty.clone(),
        ),
        (
            format!("./{STAGING_DIR}/{bundle_id}/{file_name}"),
            empty.clone(),
        ),
        // 原版路径 + CFBundleIdentifier
        (
            format!("{STAGING_DIR}/{bundle_id}/{file_name}"),
            original.clone(),
        ),
        (
            format!("./{STAGING_DIR}/{bundle_id}/{file_name}"),
            original.clone(),
        ),
        // 单文件形态
        (format!("{STAGING_DIR}/{file_name}"), empty.clone()),
        (format!("./{STAGING_DIR}/{file_name}"), empty),
        // jas 式 Developer 选项
        (format!("{STAGING_DIR}/{bundle_id}/{file_name}"), developer),
        (
            format!("/{STAGING_DIR}/{bundle_id}/{file_name}"),
            original.clone(),
        ),
        (
            format!("/var/mobile/Media/{STAGING_DIR}/{bundle_id}/{file_name}"),
            original_client_options(bundle_id),
        ),
    ]
}

/// 触发 installd 安装已上传的 .ipa 文件（RSD / CoreDevice 通道）。
///
/// PackagePath/ClientOptions 的组合随通道不同而不一致。设备对「路径/包定位不到」
/// 统一报 MissingPackagePath，而对「包找到但安装失败」报其他错误——利用这一点
/// 按候选链逐一尝试：只要某个组合返回了非 MissingPackagePath 错误，说明 installd
/// 已定位到包，立即停止换路径并把真实错误抛出。
pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    // 优先用 yeet 阶段缓存的暂存文件名（同一进程内已知，无需回读）。
    let file_name = match cached_ipa(&bundle_id) {
        Some((name, _expected_size)) => name,
        None => {
            // fallback（跨进程重启场景）：列暂存子目录回读 .ipa 文件。
            let staged_dir = format!("{STAGING_DIR}/{bundle_id}");
            let mut afc = connect_to_rsd_services::<AfcClient>()
                .await
                .map_err(|e| ctx(e, "install/连接AFC"))?;
            let entries: Vec<String> = afc
                .list_dir(staged_dir.clone())
                .await
                .map_err(|e| ctx(e, &format!("install/回读暂存目录（{staged_dir}）")))?;
            let name = entries
                .iter()
                .map(|name| name.trim_end_matches('/').to_string())
                .find(|name| name.ends_with(".ipa") && name != "." && name != "..")
                .ok_or_else(|| {
                    IdeviceError::UnexpectedResponse(format!(
                        "install/暂存目录 {staged_dir} 下未找到 .ipa 安装包（实际条目: {:?}）",
                        entries
                    ))
                })?;
            name
        }
    };

    // 对齐 jas 第 670-673 行：InstallationProxyClient::connect_rsd
    // （不做安装前 AFC 预校验：隧道抖动时预校验自身的 socket 错误会把安装
    //   挡死在 installd 之前，上传校验已由 yeet 的同连接回读完成。）
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>()
        .await
        .map_err(|e| ctx(e, "install/连接instproxy"))?;

    let already_installed = lookup_app_rppairing(bundle_id.clone())
        .await
        .ok()
        .flatten()
        .is_some();


    // 预检快照（不阻断安装，只记录事实）：合并调用后上传刚完成、
    // 若此刻 afcd 侧仍看不到文件，说明写入未持久化；若看得到而 installd
    // 全部候选仍报 MissingPackagePath，则说明 installd 视图 ≠ afcd 视图。
    let mut afcd_snapshot = "预检未执行".to_string();
    {
        let staged_dir = format!("{STAGING_DIR}/{bundle_id}");
        if let Ok(mut afc) = connect_to_rsd_services::<AfcClient>().await {
            let entries = afc.list_dir(staged_dir.clone()).await.unwrap_or_default();
            match afc.get_file_info(format!("{staged_dir}/{file_name}")).await {
                Ok(info) => {
                    afcd_snapshot = format!(
                        "{staged_dir}/{file_name} 存在（{} 字节），目录条目: {entries:?}",
                        info.size
                    );
                }
                Err(e) => {
                    afcd_snapshot = format!(
                        "{staged_dir}/{file_name} 不可见: {e:?}，目录条目: {entries:?}"
                    );
                }
            }
        } else {
            afcd_snapshot = "预检 AFC 连接失败".to_string();
        }
    }

    run_install_chain(&mut inst_client, already_installed, &bundle_id, &file_name)
        .await
        .map_err(|e| match e {
            // 把 afcd 侧快照附加到最终错误上（快照仅 shim 通道产生）
            IdeviceError::UnexpectedResponse(msg) => {
                IdeviceError::UnexpectedResponse(format!("{msg}；{afcd_snapshot}"))
            }
            other => other,
        })
}

/// 在给定 instproxy 客户端上执行安装候选链：
/// 第一轮按（路径, 选项）组合逐一尝试；全部 MissingPackagePath 则卸载残留记录
/// 后再以全新 Install 重试一轮。任何组合返回非 MissingPackagePath 错误，说明
/// installd 已定位到包，立即停止换路径抛出真实错误。
pub(crate) async fn run_install_chain(
    inst_client: &mut InstallationProxyClient,
    already_installed: bool,
    bundle_id: &str,
    file_name: &str,
) -> Result<(), IdeviceError> {
    let candidates = install_candidates(bundle_id, file_name);
    let bundle_id = bundle_id.to_string();

    // 第一轮：按候选链逐一尝试（lookup 失败按未安装处理，不阻断首装）
    let mut last_missing_path_error: Option<IdeviceError> = None;
    for (path, options) in &candidates {
        let result =
            issue_install_command(inst_client, already_installed, path, options).await;
        match result {
            Ok(()) => return Ok(()),
            Err(e) if is_missing_package_path(&e) => {
                last_missing_path_error = Some(e);
            }
            Err(e) => {
                return Err(ctx(
                    e,
                    &format!(
                        "install/组合（{path}）已被 installd 定位到（{}）,真实安装错误",
                        if already_installed { "Upgrade" } else { "Install" }
                    ),
                ))
            }
        }
    }

    // 第二轮：卸载 lookup 看不到的残留记录后再试一轮全新 Install
    let _ = inst_client.uninstall(bundle_id, None).await;
    for (path, options) in &candidates {
        let result = inst_client.install(path, Some(options.clone())).await;
        match result {
            Ok(()) => return Ok(()),
            Err(e) if is_missing_package_path(&e) => continue,
            Err(e) => {
                return Err(ctx(
                    e,
                    &format!("install/卸载残留后组合（{path}）（fallback-tried）"),
                ))
            }
        }
    }

    Err(IdeviceError::UnexpectedResponse(format!(
        "install/installd 在所有候选组合均未找到暂存包（候选: {:?}）；最后错误: {:?}",
        candidates.iter().map(|(p, _)| p).collect::<Vec<_>>(),
        last_missing_path_error
    )))
}

fn is_missing_package_path(error: &IdeviceError) -> bool {
    format!("{error:?}").contains("MissingPackagePath")
}

async fn issue_install_command(
    client: &mut InstallationProxyClient,
    upgrade: bool,
    path: &str,
    options: &Value,
) -> Result<(), IdeviceError> {
    if upgrade {
        client
            .upgrade(path, Some(options.clone()))
            .await
    } else {
        client
            .install(path, Some(options.clone()))
            .await
    }
}

pub async fn remove_app_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    inst_client.uninstall(bundle_id, None).await
}

pub async fn lookup_app_rppairing(bundle_id: String) -> Result<Option<String>, IdeviceError> {
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;
    let apps = inst_client
        .get_apps(None, Some(vec![bundle_id.clone()]))
        .await?;
    Ok(apps.contains_key(&bundle_id).then_some(bundle_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn developer_options_only_carry_package_type() {
        let v = developer_client_options();
        // RustBridge 源码审计（含测试模块）禁止显式 panic 快捷方式，故用 match 断言。
        // 对齐 jas：Developer 安装只给 PackageType，不得额外携带 CFBundleIdentifier。
        match v.as_dictionary() {
            Some(dict) => {
                assert_eq!(
                    dict.get("PackageType").and_then(|x| x.as_string()),
                    Some("Developer")
                );
                assert!(dict.get("CFBundleIdentifier").is_none());
                assert_eq!(dict.len(), 1);
            }
            None => assert!(false, "options must be a dictionary"),
        }
    }

    #[test]
    fn staging_dir_is_public_staging_root() {
        // 对齐 jas：暂存包直接放 PublicStaging/<Name>.ipa 根目录单层，不建 <bid> 子目录。
        assert_eq!(STAGING_DIR, "PublicStaging");
    }

    #[test]
    fn detect_application_name_extracts_app_dir() {
        // 构造一个最小 IPA：Payload/TestApp.app/Info.plist
        let mut buf = Vec::new();
        {
            use std::io::Write;
            let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let options = zip::write::SimpleFileOptions::default();
            match zip.start_file("Payload/TestApp.app/Info.plist", options) {
                Ok(()) => {}
                Err(e) => {
                    // 审计禁止 unwrap，用 match 断言
                    assert!(false, "start_file failed: {e:?}");
                    return;
                }
            }
            match zip.write_all(b"<?xml version=\"1.0\"?><plist><dict/></plist>") {
                Ok(()) => {}
                Err(e) => {
                    assert!(false, "write_all failed: {e:?}");
                    return;
                }
            }
            match zip.finish() {
                Ok(_) => {}
                Err(e) => {
                    assert!(false, "finish failed: {e:?}");
                    return;
                }
            }
        }
        match detect_application_name(&buf) {
            Ok(name) => assert_eq!(name, "TestApp.app"),
            Err(e) => {
                assert!(false, "detect_application_name failed: {e:?}");
            }
        }
    }
}
