use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use crate::idevice_support::mounter::mount_personalized_ddi_rppairing;
use crate::idevice_support::rsd::set_rppairing_file;
use crate::idevice_support::{
    device::{fetch_udid_rppairing, test_device_connection},
    install::{
        install_ipa_rppairing, lookup_app_rppairing, remove_app_rppairing,
        stage_and_install_rppairing, yeet_app_afc_rppairing,
    },
    jit::{debug_app_rppairing, debug_process_rppairing},
    provision::{
        dump_provisioning_profile_rppairing, install_provisioning_profile_rppairing,
        remove_provisioning_profile_rppairing,
    },
};
use crate::post17::shared_runtime;
use crate::IdeviceFfiError;

fn to_char(value: String) -> *mut c_char {
    CString::new(value)
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn c_string_arg(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(ToOwned::to_owned)
}

fn bytes_arg<'a>(ptr: *const u8, len: u32) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, len as usize) })
}

fn invalid_argument_error() -> *mut IdeviceFfiError {
    crate::ffi_err!(IdeviceError::InvalidArgument)
}

fn runtime_error() -> *mut IdeviceFfiError {
    crate::errors::internal_ffi_error("RustBridge async runtime is unavailable")
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_test_device_connection() -> bool {
    test_device_connection()
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_fetch_udid(
    udid_out: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if udid_out.is_null() {
        return invalid_argument_error();
    }

    unsafe {
        *udid_out = std::ptr::null_mut();
    }

    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    match runtime.block_on(fetch_udid_rppairing()) {
        Ok(udid) => {
            let pointer = to_char(udid);
            if pointer.is_null() {
                return crate::errors::internal_ffi_error("Unable to encode device UDID");
            }
            unsafe {
                *udid_out = pointer;
            }
            std::ptr::null_mut()
        }
        Err(err) => crate::ffi_err!(err),
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_yeet_app_afc(
    bundle_id: *const c_char,
    ipa_ptr: *const u8,
    ipa_len: u32,
) -> *mut IdeviceFfiError {
    let Some(bundle_id) = c_string_arg(bundle_id) else {
        return invalid_argument_error();
    };
    let Some(ipa_bytes) = bytes_arg(ipa_ptr, ipa_len) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match yeet_app_afc_rppairing(bundle_id, ipa_bytes).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_install_ipa(
    bundle_id: *const c_char,
) -> *mut IdeviceFfiError {
    let Some(bundle_id) = c_string_arg(bundle_id) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match install_ipa_rppairing(bundle_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_stage_and_install(
    bundle_id: *const c_char,
    ipa_ptr: *const u8,
    ipa_len: u32,
) -> *mut IdeviceFfiError {
    let Some(bundle_id) = c_string_arg(bundle_id) else {
        return invalid_argument_error();
    };
    let Some(ipa_bytes) = bytes_arg(ipa_ptr, ipa_len) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match stage_and_install_rppairing(bundle_id, ipa_bytes, |_| {}).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

/// 带上传进度回调的合并调用（AFC 上传期间回传 0-100，0 与 100 各至少一次）。
/// progress_cb 在 Rust 上传线程回调，progress_ctx 为不透明指针原样回传。
/// 与不带回调版本 `rust_bridge_idevice_stage_and_install` 并存，旧路径不受影响。
#[no_mangle]
pub extern "C" fn rust_bridge_idevice_stage_and_install_with_callback(
    bundle_id: *const c_char,
    ipa_ptr: *const u8,
    ipa_len: u32,
    progress_cb: Option<extern "C" fn(u64, *mut std::ffi::c_void)>,
    progress_ctx: usize,
) -> *mut IdeviceFfiError {
    let Some(bundle_id) = c_string_arg(bundle_id) else {
        return invalid_argument_error();
    };
    let Some(ipa_bytes) = bytes_arg(ipa_ptr, ipa_len) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        let upload_cb = move |pct: u64| {
            if let Some(cb) = progress_cb {
                cb(pct, progress_ctx as *mut std::ffi::c_void);
            }
        };
        match stage_and_install_rppairing(bundle_id, ipa_bytes, upload_cb).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

/// 生成 OTA 本地 HTTPS 证书（自签根 + 服务器叶子），返回 JSON：
/// { "ca_pem": ..., "cert_pem": ..., "key_pem": ... }
/// 失败返回 null。调用方负责用 rust_bridge_idevice_free_string 释放。
#[no_mangle]
pub extern "C" fn rust_bridge_ota_identity_generate() -> *mut c_char {
    match crate::ota_server::generate_identity() {
        Ok(identity) => {
            let json = serde_json::json!({
                "ca_pem": identity.ca_pem,
                "cert_pem": identity.cert_pem,
                "key_pem": identity.key_pem,
            });
            match serde_json::to_string(&json) {
                Ok(s) => match std::ffi::CString::new(s) {
                    Ok(c) => c.into_raw(),
                    Err(_) => std::ptr::null_mut(),
                },
                Err(_) => std::ptr::null_mut(),
            }
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// 配置 OTA 服务器资源（PEM 证书/密钥、清单、IPA 路径、CA 描述文件路径）
#[no_mangle]
pub extern "C" fn rust_bridge_ota_configure(
    ca_pem: *const c_char,
    cert_pem: *const c_char,
    key_pem: *const c_char,
    ca_profile_path: *const c_char,
    manifest_path: *const c_char,
    ipa_path: *const c_char,
) -> *mut IdeviceFfiError {
    let (Some(ca_pem), Some(cert_pem), Some(key_pem), Some(ca_profile_path), Some(manifest_path), Some(ipa_path)) = (
        c_string_arg(ca_pem),
        c_string_arg(cert_pem),
        c_string_arg(key_pem),
        c_string_arg(ca_profile_path),
        c_string_arg(manifest_path),
        c_string_arg(ipa_path),
    ) else {
        return invalid_argument_error();
    };

    match crate::ota_server::configure(
        &ca_pem,
        &cert_pem,
        &key_pem,
        std::fs::read(&ca_profile_path).unwrap_or_default(),
        manifest_path.clone(),
        ipa_path,
    ) {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => crate::errors::internal_ffi_error(e),
    }
}

/// 启动 OTA HTTPS 服务器（127.0.0.1 随机端口，后台常驻），端口写入 port_out
#[no_mangle]
pub extern "C" fn rust_bridge_ota_serve(port_out: *mut u16) -> *mut IdeviceFfiError {
    if port_out.is_null() {
        return invalid_argument_error();
    }
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    let result = runtime.block_on(async move { crate::ota_server::serve().await });
    match result {
        Ok(port) => {
            unsafe { *port_out = port };
            std::ptr::null_mut()
        }
        Err(e) => crate::errors::internal_ffi_error(e),
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_remove_app(bundle_id: *const c_char) -> *mut IdeviceFfiError {
    let Some(bundle_id) = c_string_arg(bundle_id) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match remove_app_rppairing(bundle_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_lookup_app(
    bundle_id: *const c_char,
    result_out: *mut *mut c_char,
) -> *mut IdeviceFfiError {
    if result_out.is_null() { return invalid_argument_error(); }
    unsafe { *result_out = std::ptr::null_mut(); }
    let Some(bundle_id) = c_string_arg(bundle_id) else { return invalid_argument_error(); };
    let Some(runtime) = shared_runtime() else { return runtime_error(); };
    runtime.block_on(async move {
        match lookup_app_rppairing(bundle_id).await {
            Ok(Some(found_bundle_id)) => {
                let pointer = to_char(found_bundle_id);
                if pointer.is_null() { return crate::errors::internal_ffi_error("Unable to encode app bundle id"); }
                unsafe { *result_out = pointer; }
                std::ptr::null_mut()
            }
            Ok(None) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_debug_app(app_id: *const c_char) -> *mut IdeviceFfiError {
    let Some(app_id) = c_string_arg(app_id) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match debug_app_rppairing(app_id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_debug_process(pid: u32) -> *mut IdeviceFfiError {
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match debug_process_rppairing(pid).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_install_provisioning_profile(
    profile_ptr: *const u8,
    profile_len: u32,
) -> *mut IdeviceFfiError {
    let Some(profile) = bytes_arg(profile_ptr, profile_len) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match install_provisioning_profile_rppairing(profile).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_remove_provisioning_profile(
    id: *const c_char,
) -> *mut IdeviceFfiError {
    let Some(id) = c_string_arg(id) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match remove_provisioning_profile_rppairing(id).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_dump_provisioning_profile(
    docs_path: *const c_char,
) -> *mut IdeviceFfiError {
    let Some(docs_path) = c_string_arg(docs_path) else {
        return invalid_argument_error();
    };
    let Some(runtime) = shared_runtime() else {
        return runtime_error();
    };

    runtime.block_on(async move {
        match dump_provisioning_profile_rppairing(docs_path).await {
            Ok(()) => std::ptr::null_mut(),
            Err(err) => crate::ffi_err!(err),
        }
    })
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_set_rppairing_file(
    pairing_file: *const c_char,
) -> *mut IdeviceFfiError {
    let Some(pairing_file) = c_string_arg(pairing_file) else {
        return invalid_argument_error();
    };

    match set_rppairing_file(pairing_file) {
        Ok(()) => std::ptr::null_mut(),
        Err(err) => crate::ffi_err!(err),
    }
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_invalidate_rsd_connection() {
    crate::idevice_support::rsd::invalidate_rsd_connection();
}

#[no_mangle]
pub extern "C" fn rust_bridge_idevice_mount_personalized_ddi(
    image_ptr: *const u8,
    image_len: u32,
    trustcache_ptr: *const u8,
    trustcache_len: u32,
    manifest_ptr: *const u8,
    manifest_len: u32,
) -> i32 {
    let Some(image) = bytes_arg(image_ptr, image_len) else { return 1; };
    let Some(trustcache) = bytes_arg(trustcache_ptr, trustcache_len) else { return 1; };
    let Some(manifest) = bytes_arg(manifest_ptr, manifest_len) else { return 1; };
    let Some(runtime) = shared_runtime() else { return 9; };

    runtime.block_on(async move {
        mount_personalized_ddi_rppairing(image, trustcache, manifest).await
    })
}
