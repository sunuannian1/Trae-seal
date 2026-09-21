from __future__ import annotations

import pathlib
import shutil
import sys

UPSTREAM_COMMIT = "e3abb341b73a4fbeb96cdfc5e6652687e4bee130"
SEAL_PAIRING_FILE = "SealPairing.mobiledevicepairing"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    return text.replace(old, new, 1)


def insert_after_once(text: str, anchor: str, addition: str, description: str) -> str:
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    return text.replace(anchor, anchor + addition, 1)


def replace_tail_once(text: str, anchor: str, replacement: str, description: str) -> str:
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    start = text.index(anchor)
    return text[:start] + replacement


def patch_cargo(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    anchor = 'rust-i18n = "3"\n'
    addition = 'raw-window-handle = "0.6.2"\n'
    if addition not in text:
        text = insert_after_once(text, anchor, addition, "raw-window-handle dependency")
    path.write_text(text, encoding="utf-8", newline="\n")



def stage_ui_assets(root: pathlib.Path) -> None:
    source = pathlib.Path(__file__).resolve().parent / "assets"
    target = root / "src" / "seal_assets"
    target.mkdir(parents=True, exist_ok=True)
    required = [
        "seal_icon_ui.rgba",
        "iphone_model.rgba",
    ]
    for name in required:
        asset = source / name
        if not asset.exists():
            raise RuntimeError(f"missing Seal pairing UI asset: {asset}")
        shutil.copyfile(asset, target / name)


def patch_main(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    app_anchor = '            supported_apps.insert("Ksign".to_string(), "pairingFile.plist".to_string());\n'
    if text.count(app_anchor) != 2:
        raise RuntimeError(
            f"supported-app anchor drifted: expected 2, found {text.count(app_anchor)}"
        )
    app_replacement = app_anchor + (
        '            supported_apps.insert("Seal".to_string(), '
        f'"{SEAL_PAIRING_FILE}".to_string());\n'
    )
    text = text.replace(app_anchor, app_replacement, 2)

    font_function_end = """    }\n}\n\nfn main() {\n"""
    seal_theme = """    }\n}\n\nconst SEAL_ICON_RGBA: &[u8] = include_bytes!(\"seal_assets/seal_icon_ui.rgba\");\nconst SEAL_ICON_SIZE: [usize; 2] = [160, 160];\nconst IPHONE_MODEL_RGBA: &[u8] = include_bytes!(\"seal_assets/iphone_model.rgba\");\nconst IPHONE_MODEL_SIZE: [usize; 2] = [154, 300];\n\n#[cfg(windows)]\nfn setup_windows_backdrop(cc: &eframe::CreationContext<'_>) {\n    use raw_window_handle::{HasWindowHandle, RawWindowHandle};\n    use std::ffi::c_void;\n\n    #[link(name = \"dwmapi\")]\n    unsafe extern \"system\" {\n        fn DwmSetWindowAttribute(\n            hwnd: *mut c_void,\n            dw_attribute: u32,\n            pv_attribute: *const c_void,\n            cb_attribute: u32,\n        ) -> i32;\n    }\n\n    let Ok(window_handle) = cc.window_handle() else { return; };\n    let RawWindowHandle::Win32(handle) = window_handle.as_raw() else { return; };\n\n    const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;\n    const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;\n    const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;\n    const DWMWCP_ROUND: i32 = 2;\n    const DWMSBT_TRANSIENTWINDOW: i32 = 3;\n\n    let hwnd = handle.hwnd.get() as *mut c_void;\n    let light_mode: i32 = 0;\n    let corner = DWMWCP_ROUND;\n    let backdrop = DWMSBT_TRANSIENTWINDOW;\n    unsafe {\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_USE_IMMERSIVE_DARK_MODE,\n            &light_mode as *const _ as *const c_void,\n            std::mem::size_of_val(&light_mode) as u32,\n        );\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_WINDOW_CORNER_PREFERENCE,\n            &corner as *const _ as *const c_void,\n            std::mem::size_of_val(&corner) as u32,\n        );\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_SYSTEMBACKDROP_TYPE,\n            &backdrop as *const _ as *const c_void,\n            std::mem::size_of_val(&backdrop) as u32,\n        );\n    }\n}\n\n#[cfg(not(windows))]\nfn setup_windows_backdrop(_cc: &eframe::CreationContext<'_>) {}\n\nfn setup_seal_theme(ctx: &egui::Context) {\n    let seal_blue = Color32::from_rgb(0, 122, 255);\n    let seal_blue_soft = Color32::from_rgb(226, 239, 255);\n    let mut visuals = egui::Visuals::light();\n    visuals.panel_fill = Color32::from_rgba_unmultiplied(242, 247, 253, 218);\n    visuals.window_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 226);\n    visuals.extreme_bg_color = Color32::from_rgba_unmultiplied(255, 255, 255, 216);\n    visuals.faint_bg_color = Color32::from_rgba_unmultiplied(255, 255, 255, 150);\n    visuals.selection.bg_fill = seal_blue;\n    visuals.hyperlink_color = seal_blue;\n    visuals.widgets.active.bg_fill = seal_blue;\n    visuals.widgets.active.fg_stroke.color = Color32::WHITE;\n    visuals.widgets.hovered.bg_fill = seal_blue_soft;\n    visuals.widgets.hovered.fg_stroke.color = Color32::from_rgb(0, 94, 204);\n    visuals.widgets.inactive.bg_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 188);\n    visuals.widgets.inactive.weak_bg_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 150);\n    visuals.window_corner_radius = egui::CornerRadius::same(24);\n    visuals.menu_corner_radius = egui::CornerRadius::same(16);\n    visuals.widgets.noninteractive.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.inactive.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.hovered.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.active.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.open.corner_radius = egui::CornerRadius::same(14);\n    ctx.set_visuals(visuals);\n\n    let mut style = (*ctx.style()).clone();\n    style.spacing.item_spacing = egui::vec2(10.0, 10.0);\n    style.spacing.button_padding = egui::vec2(16.0, 10.0);\n    ctx.set_style(style);\n}\n\nfn seal_ios_supports_remote_pairing(ios_version: &str) -> Option<bool> {\n    let mut parts = ios_version.split('.');\n    let major: i64 = parts.next()?.trim().parse().ok()?;\n    let minor: i64 = parts.next().unwrap_or(\"0\").trim().parse().unwrap_or(0);\n    Some(major > 17 || (major == 17 && minor >= 4))\n}\n\nfn seal_mode_for_ios(ios_version: &str, default_mode: PairingMode) -> PairingMode {\n    match seal_ios_supports_remote_pairing(ios_version) {\n        Some(true) => PairingMode::RemotePairing,\n        Some(false) => PairingMode::Lockdown,\n        None => default_mode,\n    }\n}\n\n#[cfg(test)]\nmod seal_mode_for_ios_tests {\n    use super::*;\n\n    #[test]\n    fn remote_pairing_needs_ios_17_4() {\n        assert_eq!(seal_ios_supports_remote_pairing(\"16.0\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"16.7.10\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.0\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.3.1\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.4\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.7.2\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"18.6.2\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"26.7\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"—\"), None);\n        assert_eq!(\n            seal_mode_for_ios(\"16.0\", PairingMode::RemotePairing),\n            PairingMode::Lockdown\n        );\n        assert_eq!(\n            seal_mode_for_ios(\"17.3.1\", PairingMode::RemotePairing),\n            PairingMode::Lockdown\n        );\n        assert_eq!(\n            seal_mode_for_ios(\"17.4\", PairingMode::Lockdown),\n            PairingMode::RemotePairing\n        );\n        assert_eq!(\n            seal_mode_for_ios(\"—\", PairingMode::RemotePairing),\n            PairingMode::RemotePairing\n        );\n    }\n}\n\nfn main() {\n    rust_i18n::set_locale(\"zh-cn\");\n"""
    text = replace_once(text, font_function_end, seal_theme, "Seal theme injection")

    options_anchor = "    let mut options = eframe::NativeOptions::default();\n"
    options_replacement = """    let mut options = eframe::NativeOptions::default();\n    options.viewport = options\n        .viewport\n        .clone()\n        .with_inner_size([1180.0, 860.0])\n        .with_min_inner_size([980.0, 720.0])\n        .with_transparent(true)\n        .with_decorations(false);\n"""
    text = replace_once(text, options_anchor, options_replacement, "native viewport setup")
    text = replace_once(
        text,
        '&format!("idevice pair v{}", env!("CARGO_PKG_VERSION")),\n',
        '"Seal 配对助手",\n',
        "native window title",
    )

    creation_anchor = """        Box::new(|cc| {\n            setup_custom_fonts(&cc.egui_ctx);\n            Ok(Box::new(app))\n        }),\n"""
    creation_replacement = """        Box::new(|cc| {\n            setup_custom_fonts(&cc.egui_ctx);\n            setup_seal_theme(&cc.egui_ctx);\n            setup_windows_backdrop(cc);\n            Ok(Box::new(app))\n        }),\n"""
    text = replace_once(text, creation_anchor, creation_replacement, "Seal visual setup")

    init_anchor = "        show_logs: false,\n"
    init_replacement = "        show_logs: false,\n        pending_seal_install: false,\n        seal_icon_texture: None,\n        phone_texture: None,\n"
    text = replace_once(text, init_anchor, init_replacement, "pending Seal install init")

    struct_anchor = "    show_logs: bool,\n}"
    struct_replacement = "    show_logs: bool,\n    pending_seal_install: bool,\n    seal_icon_texture: Option<egui::TextureHandle>,\n    phone_texture: Option<egui::TextureHandle>,\n}"
    text = replace_once(text, struct_anchor, struct_replacement, "pending Seal install field")

    reset_anchor = "        self.validation_ip_input.clear();\n"
    reset_replacement = "        self.validation_ip_input.clear();\n        self.pending_seal_install = false;\n"
    text = replace_once(text, reset_anchor, reset_replacement, "pending Seal install reset")

    helper_anchor = """    fn push_pairing_status(&mut self, status: String) {\n        self.pairing_file_message = Some(status);\n    }\n}\n"""
    helper_replacement = """    fn push_pairing_status(&mut self, status: String) {\n        self.pairing_file_message = Some(status);\n    }\n\n    fn ensure_seal_textures(&mut self, ctx: &egui::Context) {
        if self.seal_icon_texture.is_none() {
            let image = egui::ColorImage::from_rgba_unmultiplied(SEAL_ICON_SIZE, SEAL_ICON_RGBA);
            self.seal_icon_texture = Some(ctx.load_texture(
                "seal-icon-ui",
                image,
                egui::TextureOptions::LINEAR,
            ));
        }
        if self.phone_texture.is_none() {
            let image = egui::ColorImage::from_rgba_unmultiplied(IPHONE_MODEL_SIZE, IPHONE_MODEL_RGBA);
            self.phone_texture = Some(ctx.load_texture(
                "iphone-model-ui",
                image,
                egui::TextureOptions::LINEAR,
            ));
        }
    }

    fn install_pairing_file_to_seal_if_ready(&mut self) -> bool {\n        let Some(dev) = self\n            .devices\n            .as_ref()\n            .and_then(|devices| devices.get(&self.selected_device))\n            .cloned()\n        else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"未找到当前 iPhone\".to_string());\n            return false;\n        };\n\n        let Some(pairing_file) = self.pairing_file.as_ref() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"配对文件尚未生成\".to_string());\n            return false;\n        };\n\n        let bytes = match pairing_file.bytes() {\n            Ok(bytes) => bytes,\n            Err(error) => {\n                self.pending_seal_install = false;\n                self.pairing_file_message = Some(error.to_string());\n                return false;\n            }\n        };\n\n        if self.installed_apps.is_none() {\n            self.pairing_file_message = Some(\"正在检测 Seal…\".to_string());\n            return false;\n        }\n\n        let Some(installed_apps) = self\n            .installed_apps\n            .as_ref()\n            .and_then(|apps| apps.as_ref().ok())\n        else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"无法读取已安装应用\".to_string());\n            return false;\n        };\n\n        let Some(bundle_id) = installed_apps.get(\"Seal\").cloned() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"未找到已安装的 Seal\".to_string());\n            return false;\n        };\n\n        let Some(path) = self.supported_apps().get(\"Seal\").cloned() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"Seal 写入路径缺失\".to_string());\n            return false;\n        };\n\n        self.pending_seal_install = false;\n        self.install_res.insert(\"Seal\".to_string(), None);\n        self.pairing_file_message = Some(\"正在写入 Seal…\".to_string());\n        self.idevice_sender\n            .send(IdeviceCommands::InstallPairingFile((\n                dev,\n                \"Seal\".to_string(),\n                bundle_id,\n                path,\n                bytes,\n            )))\n            .unwrap();\n        true\n    }\n}\n"""
    text = replace_once(text, helper_anchor, helper_replacement, "Seal auto-install helper")

    pairing_anchor = """                GuiCommands::PairingFile(pairing_file) => match pairing_file {\n                    Ok(p) => {\n                        self.pairing_file = Some(p.clone());\n                        self.pairing_file_message = None;\n                        self.pairing_file_string = match p.display_string() {\n                            Ok(serialized) => Some(serialized),\n                            Err(e) => {\n                                self.pairing_file_message = Some(e.to_string());\n                                None\n                            }\n                        };\n                    }\n                    Err(e) => {\n                        self.pairing_file = None;\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = Some(e.to_string());\n                    }\n                },\n"""
    pairing_replacement = """                GuiCommands::PairingFile(pairing_file) => match pairing_file {\n                    Ok(p) => {\n                        self.pairing_file = Some(p);\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = None;\n                        if self.pending_seal_install {\n                            self.install_pairing_file_to_seal_if_ready();\n                        }\n                    }\n                    Err(e) => {\n                        self.pending_seal_install = false;\n                        self.pairing_file = None;\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = Some(e.to_string());\n                    }\n                },\n"""
    text = replace_once(text, pairing_anchor, pairing_replacement, "secure pairing generation handling")

    apps_anchor = "                GuiCommands::InstalledApps(apps) => self.installed_apps = Some(apps),\n"
    apps_replacement = """                GuiCommands::InstalledApps(apps) => {\n                    self.installed_apps = Some(apps);\n                    if self.pending_seal_install && self.pairing_file.is_some() {\n                        self.install_pairing_file_to_seal_if_ready();\n                    }\n                }\n"""
    text = replace_once(text, apps_anchor, apps_replacement, "pending auto-install after installed apps")

    ui_anchor = "        egui::CentralPanel::default().show(ctx, |ui| {\n"
    ui_template = pathlib.Path(__file__).with_name("seal_ui_tail.rs.txt").read_text(
        encoding="utf-8"
    )
    if not ui_template.endswith("\n"):
        ui_template += "\n"
    text = replace_tail_once(text, ui_anchor, ui_template, "Seal minimal glass UI replacement")

    path.write_text(text, encoding="utf-8", newline="\n")


def patch_locale(path: pathlib.Path, expected: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(text, expected, replacement, f"locale {path.name}")
    path.write_text(text, encoding="utf-8", newline="\n")


def verify(root: pathlib.Path) -> None:
    main = (root / "src" / "main.rs").read_text(encoding="utf-8")
    cargo = (root / "Cargo.toml").read_text(encoding="utf-8")
    required = [
        'supported_apps.insert("Seal".to_string(), "SealPairing.mobiledevicepairing".to_string());',
        "fn setup_seal_theme",
        "fn setup_windows_backdrop",
        "DWMSBT_TRANSIENTWINDOW",
        'rust_i18n::set_locale("zh-cn");',
        '"Seal 配对助手"',
        "pending_seal_install",
        "seal_icon_texture",
        "phone_texture",
        "include_bytes!(\"seal_assets/seal_icon_ui.rgba\")",
        "include_bytes!(\"seal_assets/iphone_model.rgba\")",
        "fn ensure_seal_textures",
        "fn install_pairing_file_to_seal_if_ready",
        "生成并写入 Seal",
        "已写入 Seal",
        "未连接 iPhone",
        "GeneratePairingFile",
        "InstallPairingFile",
        "ValidateRemote",
        "EnableWireless",
        "CheckDevMode",
        "AutoMount",
        "PairingMode::Lockdown",
        "PairingMode::RemotePairing",
        "fn seal_ios_supports_remote_pairing",
        "fn seal_mode_for_ios",
        "seal_lockdown_only",
        "seal_mode_for_ios(&ios_version, self.pairing_mode)",
        "let has_ios_version = ios_version != \"—\";",
        "has_device && has_ios_version && !is_processing",
        "正在读取 iOS 版本…",
        # 2026-09-21：最低支持版本回到 iOS 16 ⇒ 助手对 16.x 必须走 Lockdown 并照常生成。
        # ⚠️ 标记必须是**短片段**：本清单在 workflow 里跑在 `cargo fmt --all` **之后**，
        # 长表达式被 rustfmt 折行会**误判为缺失** ⇒ 白烧一轮 CI ✗。
        # 这两条分别约 42 / 54 字符，远低于 rustfmt 默认 max_width = 100 ✓。
        # ⚠️ 它们与 `.github/workflows/pairing-assistant.yml` 的 required 清单是
        # **两道互相独立**的闸门（R60b 的教训：只留一道 = 自洽判据）✓。
        'seal_ios_supports_remote_pairing("16.0")',
        'seal_mode_for_ios("16.0", PairingMode::RemotePairing)',
    ]
    missing = [item for item in required if item not in main]
    if missing:
        raise RuntimeError(f"Seal/upstream feature verification failed: {missing}")

    marker = 'supported_apps.insert("Seal".to_string(), "SealPairing.mobiledevicepairing".to_string());'
    if main.count(marker) != 2:
        raise RuntimeError("Seal must be supported in both pairing modes")
    forbidden = [
        'RichText::new(&pairing_file).monospace()',
        "if let Some(pairing_file) = pairing_file_text",
        "seal_lang_selector",
        "seal_view_logs",
        "seal_pairing_ready",
        "seal_pairing_mode",
        "写入已安装应用",
    ]
    present = [item for item in forbidden if item in main]
    if present:
        raise RuntimeError(f"Minimal UI still contains removed surface: {present}")
    if 'raw-window-handle = "0.6.2"' not in cargo:
        raise RuntimeError("Windows backdrop dependency missing")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_upstream.py <idevice_pair checkout>", file=sys.stderr)
        return 2

    root = pathlib.Path(sys.argv[1]).resolve()
    patch_cargo(root / "Cargo.toml")
    stage_ui_assets(root)
    patch_main(root / "src" / "main.rs")
    patch_locale(
        root / "locales" / "zh-cn.toml",
        'app_title = "idevice pair"',
        'app_title = "Seal 配对助手"',
    )
    patch_locale(
        root / "locales" / "en.toml",
        'app_title = "idevice pair"',
        'app_title = "Seal Pairing Assistant"',
    )
    verify(root)
    print(f"Seal 1:1 glass UI v13 overlay applied to idevice_pair {UPSTREAM_COMMIT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
