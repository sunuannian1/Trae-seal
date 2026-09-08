//
//  MinimuxerBridgeIdevice.swift
//  Minimuxer
//
//  Created by s s on 2026/4/3.
//

import Foundation

// MARK: - FFI Declarations

internal struct RustIdeviceFfiError {
	let code: Int32
	let message: UnsafePointer<Int8>?
}

@_silgen_name("idevice_error_free")
internal func _idevice_error_free(_ err: UnsafeMutablePointer<RustIdeviceFfiError>?)

@_silgen_name("rust_bridge_idevice_test_device_connection")
internal func _rust_bridge_idevice_test_device_connection() -> Bool

@_silgen_name("rust_bridge_idevice_fetch_udid")
internal func _rust_bridge_idevice_fetch_udid(
	_ udidOut: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_free_string")
internal func _rust_bridge_idevice_free_string(_ ptr: UnsafeMutablePointer<Int8>?)

@_silgen_name("rust_bridge_idevice_yeet_app_afc")
internal func _rust_bridge_idevice_yeet_app_afc(
	_ bundleId: UnsafePointer<Int8>?,
	_ ipaPtr: UnsafePointer<UInt8>?,
	_ ipaLen: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_install_ipa")
internal func _rust_bridge_idevice_install_ipa(
	_ bundleId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_stage_and_install")
internal func _rust_bridge_idevice_stage_and_install(
	_ bundleId: UnsafePointer<Int8>?,
	_ ipaPtr: UnsafePointer<UInt8>?,
	_ ipaLen: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_stage_and_install_with_callback")
internal func _rust_bridge_idevice_stage_and_install_with_callback(
	_ bundleId: UnsafePointer<Int8>?,
	_ ipaPtr: UnsafePointer<UInt8>?,
	_ ipaLen: UInt32,
	_ progressCb: (@convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void)?,
	_ progressCtx: UInt
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_ota_identity_generate")
internal func _rust_bridge_ota_identity_generate() -> UnsafeMutablePointer<CChar>?

@_silgen_name("rust_bridge_ota_configure")
internal func _rust_bridge_ota_configure(
	_ caPem: UnsafePointer<CChar>?,
	_ certPem: UnsafePointer<CChar>?,
	_ keyPem: UnsafePointer<CChar>?,
	_ caProfilePath: UnsafePointer<CChar>?,
	_ manifestPath: UnsafePointer<CChar>?,
	_ ipaPath: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_ota_serve")
internal func _rust_bridge_ota_serve(
	_ portOut: UnsafeMutablePointer<UInt16>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_remove_app")
internal func _rust_bridge_idevice_remove_app(
	_ bundleId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_invalidate_rsd_connection")
internal func _rust_bridge_idevice_invalidate_rsd_connection()

@_silgen_name("rust_bridge_idevice_lookup_app")
internal func _rust_bridge_idevice_lookup_app(
	_ bundleId: UnsafePointer<Int8>?,
	_ resultOut: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?
@_silgen_name("rust_bridge_idevice_debug_app")
internal func _rust_bridge_idevice_debug_app(
	_ appId: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_debug_process")
internal func _rust_bridge_idevice_debug_process(
    _ pid: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_install_provisioning_profile")
internal func _rust_bridge_idevice_install_provisioning_profile(
	_ profilePtr: UnsafePointer<UInt8>?,
	_ profileLen: UInt32
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_remove_provisioning_profile")
internal func _rust_bridge_idevice_remove_provisioning_profile(
	_ id: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_dump_provisioning_profile")
internal func _rust_bridge_idevice_dump_provisioning_profile(
	_ docsPath: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_set_rppairing_file")
internal func _rust_bridge_idevice_set_rppairing_file(
	_ pairingFile: UnsafePointer<Int8>?
) -> UnsafeMutablePointer<RustIdeviceFfiError>?

@_silgen_name("rust_bridge_idevice_mount_personalized_ddi")
internal func _rust_bridge_idevice_mount_personalized_ddi(
    _ image_ptr: UnsafePointer<UInt8>?, _ image_len: UInt32,
    _ trustcache_ptr: UnsafePointer<UInt8>?, _ trustcache_len: UInt32,
    _ manifest_ptr: UnsafePointer<UInt8>?, _ manifest_len: UInt32,
) -> Int32


// MARK: - Error Handling

@inline(__always)
private func rustIdeviceThrowIfNeeded(_ error: UnsafeMutablePointer<RustIdeviceFfiError>?) throws {
	guard let error else {
		return
	}

	let swiftError = NSError(domain: "minimuxer", code: Int(error.pointee.code), userInfo: [
        NSLocalizedDescriptionKey: error.pointee.message.map { String(cString: $0) } ?? "unknown error"
    ])

	_idevice_error_free(error)
	throw swiftError
}

@inline(__always)
private func rustIdeviceCheckedLength(_ count: Int) throws -> UInt32 {
	guard let length = UInt32(exactly: count) else {
		throw NSError(
			domain: "minimuxer",
			code: -1,
			userInfo: [NSLocalizedDescriptionKey: "RustBridge payload exceeds UInt32 length limit"]
		)
	}
	return length
}

// MARK: - Swift Wrappers
public class RustIdevice {
	public static func testDeviceConnection() -> Bool {
		_rust_bridge_idevice_test_device_connection()
	}

	/// 废弃缓存的 RSD 连接（隧道可能已断）。下一次服务调用会重建连接。
	public static func invalidateConnection() {
		_rust_bridge_idevice_invalidate_rsd_connection()
	}

	public static func fetchUDID() -> String? {
		var pointer: UnsafeMutablePointer<Int8>?
		let error = withUnsafeMutablePointer(to: &pointer) {
			_rust_bridge_idevice_fetch_udid($0)
		}

		do {
			try rustIdeviceThrowIfNeeded(error)
		} catch {
			return nil
		}

		guard let pointer else {
			return nil
		}

		defer { _rust_bridge_idevice_free_string(pointer) }
		return String(cString: pointer)
	}

	/// 不吞掉底层错误的 UDID 获取：把 Rust 侧 IdeviceError 的 Debug 文本（PairVerifyFailed /
	/// PairingRejected / UserDeniedPairing / Socket / TLS-RSD handshake 等）原样抛出，
	/// 让上层能据此给出精准引导，而不是把所有失败都笼统显示成“设备未响应/连接失败”。
	public static func fetchUDIDDetailed() throws -> String {
		var pointer: UnsafeMutablePointer<Int8>?
		let error = withUnsafeMutablePointer(to: &pointer) {
			_rust_bridge_idevice_fetch_udid($0)
		}

		try rustIdeviceThrowIfNeeded(error)

		guard let pointer else {
			throw NSError(
				domain: "minimuxer",
				code: -1,
				userInfo: [NSLocalizedDescriptionKey: "fetch_udid returned no device identifier and no error"]
			)
		}

		defer { _rust_bridge_idevice_free_string(pointer) }
		return String(cString: pointer)
	}

	public static func yeetAppAfc(bundleId: String, ipaBytes: Data) throws {
		let ipaLength = try rustIdeviceCheckedLength(ipaBytes.count)
		let error = ipaBytes.withUnsafeBytes { buffer in
			_rust_bridge_idevice_yeet_app_afc(
				bundleId,
				buffer.bindMemory(to: UInt8.self).baseAddress,
				ipaLength
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}

	public static func installIpa(bundleId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_install_ipa(bundleId))
	}

	/// 上传 + 安装合并调用：**安装主链路**。
	/// 上传与安装必须共用同一条缓存的隧道会话（shim afcd 暂存视图绑定会话，
	/// 跨会话暂存包对 installd 不可见 → MissingPackagePath）。
	public static func stageAndInstall(bundleId: String, ipaBytes: Data) throws {
		let ipaLength = try rustIdeviceCheckedLength(ipaBytes.count)
		let error = ipaBytes.withUnsafeBytes { buffer in
			_rust_bridge_idevice_stage_and_install(
				bundleId,
				buffer.bindMemory(to: UInt8.self).baseAddress,
				ipaLength
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}

	/// 带 AFC 上传进度的合并安装（0-1）。回调在 Rust 上传线程触发，Swift 负责换算与持有。
	public static func stageAndInstall(
		bundleId: String,
		ipaBytes: Data,
		progress: @escaping (Double) -> Void
	) throws {
		let ipaLength = try rustIdeviceCheckedLength(ipaBytes.count)
		let box = ProgressCallbackBox(handler: progress)
		let ctx = Unmanaged.passRetained(box).toOpaque()
		defer { Unmanaged<ProgressCallbackBox>.fromOpaque(ctx).release() }

		let error = ipaBytes.withUnsafeBytes { buffer in
			_rust_bridge_idevice_stage_and_install_with_callback(
				bundleId,
				buffer.bindMemory(to: UInt8.self).baseAddress,
				ipaLength,
				progressTrampoline,
				UInt(bitPattern: ctx)
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}

	/// 承接 Rust 上传线程回传的 0-100，统一换算为 0-1 后回调上层。
	private static let progressTrampoline: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { pct, ctx in
		guard let ctx else { return }
		let box = Unmanaged<ProgressCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
		box.handler(Double(pct) / 100.0)
	}

	/// 作为不透明上下文传给 Rust 的回调容器，持有上层进度闭包。
	private final class ProgressCallbackBox {
		let handler: (Double) -> Void
		init(handler: @escaping (Double) -> Void) { self.handler = handler }
	}

	/// OTA：生成本地 HTTPS 证书（自签根 + 服务器叶子），返回 JSON（ca_pem/cert_pem/key_pem）
	public static func otaIdentityGenerate() throws -> String {
		guard let ptr = _rust_bridge_ota_identity_generate() else {
			throw NSError(domain: "minimuxer", code: -910, userInfo: [NSLocalizedDescriptionKey: "OTA 证书生成失败"])
		}
		let json = String(cString: ptr)
		_rust_bridge_idevice_free_string(ptr)
		return json
	}

	/// OTA：配置服务器资源（证书/清单/IPA 路径）
	public static func otaConfigure(
		caPem: String, certPem: String, keyPem: String,
		caProfilePath: String, manifestPath: String, ipaPath: String
	) throws {
		let err = _rust_bridge_ota_configure(caPem, certPem, keyPem, caProfilePath, manifestPath, ipaPath)
		try rustIdeviceThrowIfNeeded(err)
	}

	/// OTA：启动 HTTPS 服务器，返回端口
	public static func otaServe() throws -> UInt16 {
		var port: UInt16 = 0
		try withUnsafeMutablePointer(to: &port) { portPtr in
			let err = _rust_bridge_ota_serve(portPtr)
			try rustIdeviceThrowIfNeeded(err)
		}
		return port
	}

	public static func removeApp(bundleId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_remove_app(bundleId))
	}

	public static func lookupApp(bundleId: String) throws -> String? {
		var pointer: UnsafeMutablePointer<Int8>?
		let error = withUnsafeMutablePointer(to: &pointer) {
			_rust_bridge_idevice_lookup_app(bundleId, $0)
		}
		try rustIdeviceThrowIfNeeded(error)

		guard let pointer else {
			return nil
		}
		defer { _rust_bridge_idevice_free_string(pointer) }
		return String(cString: pointer)
	}
	public static func debugApp(appId: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_debug_app(appId))
	}
    
    public static func debugApp(pid: UInt32) throws {
        try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_debug_process(pid))
    }

	public static func installProvisioningProfile(_ profile: Data) throws {
		let profileLength = try rustIdeviceCheckedLength(profile.count)
		let error = profile.withUnsafeBytes { buffer in
			_rust_bridge_idevice_install_provisioning_profile(
				buffer.bindMemory(to: UInt8.self).baseAddress,
				profileLength
			)
		}

		try rustIdeviceThrowIfNeeded(error)
	}
    
    public static func dumpProfiles(_ docPath: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_dump_provisioning_profile(docPath))
    }

	public static func removeProvisioningProfile(id: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_remove_provisioning_profile(id))
	}

	public static func setRpPairingFile(_ pairingFile: String) throws {
		try rustIdeviceThrowIfNeeded(_rust_bridge_idevice_set_rppairing_file(pairingFile))
	}

    public static func mountPersonalizedDDI(image: Data, trustcache: Data, manifest: Data) -> Int32 {
        guard let imageLength = UInt32(exactly: image.count),
              let trustcacheLength = UInt32(exactly: trustcache.count),
              let manifestLength = UInt32(exactly: manifest.count) else { return 1 }
        return image.withUnsafeBytes { imgBuf in
            trustcache.withUnsafeBytes { tcBuf in
                manifest.withUnsafeBytes { manBuf in
                    _rust_bridge_idevice_mount_personalized_ddi(
                        imgBuf.bindMemory(to: UInt8.self).baseAddress, imageLength,
                        tcBuf.bindMemory(to: UInt8.self).baseAddress, trustcacheLength,
                        manBuf.bindMemory(to: UInt8.self).baseAddress, manifestLength,
                    )
                }
            }
        }
    }

}

