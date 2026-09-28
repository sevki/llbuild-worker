// The LLVM CAS plugin C API (llvm-c/CAS/PluginAPI_functions.h) that
// swift-frontend loads through -cas-plugin-path. Every function here is a
// C-ABI export; the vendored types live in the CLLCAS module.
import CASProtocol
import CLLCAS
import Foundation

public typealias ErrorOut = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?

private func setError(_ out: ErrorOut, _ message: String) {
    out?.pointee = strdup(message)
}

private func plugin(_ cas: llcas_cas_t?) -> Plugin {
    Unmanaged<Plugin>.fromOpaque(UnsafeRawPointer(cas!)).takeUnretainedValue()
}

private func options(_ options: llcas_cas_options_t?) -> PluginOptions {
    Unmanaged<PluginOptions>.fromOpaque(UnsafeRawPointer(options!)).takeUnretainedValue()
}

private func digest(_ value: llcas_digest_t) -> CASDigest {
    guard let data = value.data else { return CASDigest(bytes: []) }
    return CASDigest(bytes: Array(UnsafeBufferPointer(start: data, count: value.size)))
}

// MARK: - Versioning and strings

@_cdecl("llcas_get_plugin_version")
public func llcas_get_plugin_version(
    _ major: UnsafeMutablePointer<UInt32>?, _ minor: UnsafeMutablePointer<UInt32>?
) {
    major?.pointee = UInt32(LLCAS_VERSION_MAJOR)
    minor?.pointee = UInt32(LLCAS_VERSION_MINOR)
}

@_cdecl("llcas_string_dispose")
public func llcas_string_dispose(_ string: UnsafeMutablePointer<CChar>?) {
    free(string)
}

// MARK: - Cancellation (all calls complete synchronously)

@_cdecl("llcas_cancellable_cancel")
public func llcas_cancellable_cancel(_ token: llcas_cancellable_t?) {}

@_cdecl("llcas_cancellable_dispose")
public func llcas_cancellable_dispose(_ token: llcas_cancellable_t?) {}

// MARK: - Options and lifecycle

@_cdecl("llcas_cas_options_create")
public func llcas_cas_options_create() -> llcas_cas_options_t? {
    OpaquePointer(Unmanaged.passRetained(PluginOptions()).toOpaque())
}

@_cdecl("llcas_cas_options_dispose")
public func llcas_cas_options_dispose(_ opts: llcas_cas_options_t?) {
    guard let opts else { return }
    Unmanaged<PluginOptions>.fromOpaque(UnsafeRawPointer(opts)).release()
}

@_cdecl("llcas_cas_options_set_client_version")
public func llcas_cas_options_set_client_version(
    _ opts: llcas_cas_options_t?, _ major: UInt32, _ minor: UInt32
) {}

@_cdecl("llcas_cas_options_set_ondisk_path")
public func llcas_cas_options_set_ondisk_path(
    _ opts: llcas_cas_options_t?, _ path: UnsafePointer<CChar>?
) {
    options(opts).onDiskPath = path.map { String(cString: $0) }
}

@_cdecl("llcas_cas_options_set_option")
public func llcas_cas_options_set_option(
    _ opts: llcas_cas_options_t?, _ name: UnsafePointer<CChar>?,
    _ value: UnsafePointer<CChar>?, _ error: ErrorOut
) -> Bool {
    guard let name, let value else {
        setError(error, "missing option name or value")
        return true
    }
    options(opts).options[String(cString: name)] = String(cString: value)
    return false
}

@_cdecl("llcas_cas_create")
public func llcas_cas_create(_ opts: llcas_cas_options_t?, _ error: ErrorOut) -> llcas_cas_t? {
    let configured = options(opts)
    guard let path = configured.onDiskPath, !path.isEmpty else {
        setError(error, "llbuild-worker CAS plugin needs an on-disk path (-cas-path)")
        return nil
    }
    let store = LocalStore(root: URL(fileURLWithPath: path, isDirectory: true))
    do {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
    } catch let failure {
        setError(error, "cannot create \(path): \(failure)")
        return nil
    }
    var remote: RemoteTier?
    if let value = configured.options["remote-url"] {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? "") else {
            setError(error, "remote-url must be an http(s) URL: \(value)")
            return nil
        }
        do {
            remote = try RemoteTier(url: url)
        } catch let failure {
            setError(error, "cannot set up the remote CAS at \(value): \(failure)")
            return nil
        }
    }
    return OpaquePointer(Unmanaged.passRetained(Plugin(store: store, remote: remote)).toOpaque())
}

@_cdecl("llcas_cas_dispose")
public func llcas_cas_dispose(_ cas: llcas_cas_t?) {
    guard let cas else { return }
    Unmanaged<Plugin>.fromOpaque(UnsafeRawPointer(cas)).release()
}

// MARK: - Storage management (no size accounting or pruning yet)

@_cdecl("llcas_cas_get_ondisk_size")
public func llcas_cas_get_ondisk_size(_ cas: llcas_cas_t?, _ error: ErrorOut) -> Int64 {
    -1
}

@_cdecl("llcas_cas_set_ondisk_size_limit")
public func llcas_cas_set_ondisk_size_limit(
    _ cas: llcas_cas_t?, _ limit: Int64, _ error: ErrorOut
) -> Bool {
    false
}

@_cdecl("llcas_cas_prune_ondisk_data")
public func llcas_cas_prune_ondisk_data(_ cas: llcas_cas_t?, _ error: ErrorOut) -> Bool {
    false
}

@_cdecl("llcas_cas_validate")
public func llcas_cas_validate(_ cas: llcas_cas_t?, _ checkHash: Bool, _ error: ErrorOut) -> Bool {
    false
}

@_cdecl("llcas_actioncache_validate")
public func llcas_actioncache_validate(_ cas: llcas_cas_t?, _ error: ErrorOut) -> Bool {
    false
}

@_cdecl("llcas_cas_get_hash_schema_name")
public func llcas_cas_get_hash_schema_name(_ cas: llcas_cas_t?) -> UnsafeMutablePointer<CChar>? {
    strdup(CASIdentity.schemaName)
}

// MARK: - Digests and object IDs

@_cdecl("llcas_digest_parse")
public func llcas_digest_parse(
    _ cas: llcas_cas_t?, _ printed: UnsafePointer<CChar>?, _ bytes: UnsafeMutablePointer<UInt8>?,
    _ bytesSize: Int, _ error: ErrorOut
) -> UInt32 {
    guard let printed, let parsed = CASDigest(hex: String(cString: printed)),
          parsed.bytes.count == CASIdentity.digestSize else {
        setError(error, "not a valid llbuild-worker digest")
        return 0
    }
    if bytesSize < parsed.bytes.count { return UInt32(parsed.bytes.count) }
    parsed.bytes.withUnsafeBufferPointer { source in
        bytes?.update(from: source.baseAddress!, count: source.count)
    }
    return UInt32(parsed.bytes.count)
}

@_cdecl("llcas_digest_print")
public func llcas_digest_print(
    _ cas: llcas_cas_t?, _ value: llcas_digest_t,
    _ printed: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ error: ErrorOut
) -> Bool {
    printed?.pointee = strdup(digest(value).hex)
    return false
}

@_cdecl("llcas_cas_get_objectid")
public func llcas_cas_get_objectid(
    _ cas: llcas_cas_t?, _ value: llcas_digest_t, _ out: UnsafeMutablePointer<llcas_objectid_t>?,
    _ error: ErrorOut
) -> Bool {
    let parsed = digest(value)
    guard parsed.bytes.count == CASIdentity.digestSize else {
        setError(error, "digest must be \(CASIdentity.digestSize) bytes")
        return true
    }
    out?.pointee = plugin(cas).objectID(for: parsed)
    return false
}

@_cdecl("llcas_objectid_get_digest")
public func llcas_objectid_get_digest(_ cas: llcas_cas_t?, _ id: llcas_objectid_t) -> llcas_digest_t {
    plugin(cas).digestBuffer(of: id)
}

// MARK: - Objects

@_cdecl("llcas_cas_contains_object")
public func llcas_cas_contains_object(
    _ cas: llcas_cas_t?, _ id: llcas_objectid_t, _ globally: Bool, _ error: ErrorOut
) -> llcas_lookup_result_t {
    let instance = plugin(cas)
    guard let digest = instance.digest(of: id) else {
        setError(error, "unknown object id")
        return LLCAS_LOOKUP_RESULT_ERROR
    }
    if instance.store.contains(digest) { return LLCAS_LOOKUP_RESULT_SUCCESS }
    if globally, let remote = instance.remote, remote.contains(digest) == true {
        return LLCAS_LOOKUP_RESULT_SUCCESS
    }
    return LLCAS_LOOKUP_RESULT_NOTFOUND
}

private func load(
    _ instance: Plugin, _ id: llcas_objectid_t
) -> (result: llcas_lookup_result_t, object: llcas_loaded_object_t, message: String?) {
    let none = llcas_loaded_object_t(opaque: 0)
    guard let digest = instance.digest(of: id) else {
        return (LLCAS_LOOKUP_RESULT_ERROR, none, "unknown object id")
    }
    do {
        if let stored = try instance.store.get(digest) {
            return (LLCAS_LOOKUP_RESULT_SUCCESS, instance.addLoaded(stored), nil)
        }
        // Local miss: try the shared tier, keeping what it returns.
        if let remote = instance.remote, let fetched = remote.get(digest), let blob = fetched {
            try instance.store.put(blob, digest: digest)
            remote.log("fetched \(digest.hex) (\(blob.data.count) bytes)")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, instance.addLoaded(blob), nil)
        }
        return (LLCAS_LOOKUP_RESULT_NOTFOUND, none, nil)
    } catch {
        return (LLCAS_LOOKUP_RESULT_ERROR, none, "\(error)")
    }
}

@_cdecl("llcas_cas_load_object")
public func llcas_cas_load_object(
    _ cas: llcas_cas_t?, _ id: llcas_objectid_t, _ out: UnsafeMutablePointer<llcas_loaded_object_t>?,
    _ error: ErrorOut
) -> llcas_lookup_result_t {
    let loaded = load(plugin(cas), id)
    if let message = loaded.message { setError(error, message) }
    if loaded.result == LLCAS_LOOKUP_RESULT_SUCCESS { out?.pointee = loaded.object }
    return loaded.result
}

@_cdecl("llcas_cas_load_object_async")
public func llcas_cas_load_object_async(
    _ cas: llcas_cas_t?, _ id: llcas_objectid_t, _ context: UnsafeMutableRawPointer?,
    _ callback: llcas_cas_load_object_cb?, _ cancel: UnsafeMutablePointer<llcas_cancellable_t?>?
) {
    cancel?.pointee = nil
    let loaded = load(plugin(cas), id)
    callback?(context, loaded.result, loaded.object, loaded.message.flatMap { strdup($0) })
}

@_cdecl("llcas_cas_store_object")
public func llcas_cas_store_object(
    _ cas: llcas_cas_t?, _ data: llcas_data_t, _ refs: UnsafePointer<llcas_objectid_t>?,
    _ refsCount: Int, _ out: UnsafeMutablePointer<llcas_objectid_t>?, _ error: ErrorOut
) -> Bool {
    let instance = plugin(cas)
    var refDigests = [CASDigest]()
    for index in 0..<refsCount {
        guard let refs, let ref = instance.digest(of: refs[index]) else {
            setError(error, "unknown reference id")
            return true
        }
        refDigests.append(ref)
    }
    let bytes = data.data.map { Array(UnsafeRawBufferPointer(start: $0, count: data.size)) } ?? []
    let id = CASIdentity.identify(refs: refDigests, data: bytes)
    do {
        try instance.store.put(StoredObject(refs: refDigests, data: bytes), digest: id)
    } catch let failure {
        setError(error, "\(failure)")
        return true
    }
    out?.pointee = instance.objectID(for: id)
    return false
}

@_cdecl("llcas_cas_store_from_filepath")
public func llcas_cas_store_from_filepath(
    _ cas: llcas_cas_t?, _ path: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<llcas_objectid_t>?,
    _ error: ErrorOut
) -> Bool {
    guard let path else {
        setError(error, "missing file path")
        return true
    }
    let instance = plugin(cas)
    do {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: String(cString: path))))
        let id = CASIdentity.identify(refs: [], data: bytes)
        try instance.store.put(StoredObject(refs: [], data: bytes), digest: id)
        out?.pointee = instance.objectID(for: id)
        return false
    } catch let failure {
        setError(error, "\(failure)")
        return true
    }
}

@_cdecl("llcas_loaded_object_get_data")
public func llcas_loaded_object_get_data(
    _ cas: llcas_cas_t?, _ object: llcas_loaded_object_t
) -> llcas_data_t {
    guard let loaded = plugin(cas).loaded(object) else { return llcas_data_t(data: nil, size: 0) }
    return llcas_data_t(data: UnsafeRawPointer(loaded.data), size: loaded.size)
}

@_cdecl("llcas_loaded_object_get_refs")
public func llcas_loaded_object_get_refs(
    _ cas: llcas_cas_t?, _ object: llcas_loaded_object_t
) -> llcas_object_refs_t {
    // opaque_b is the loaded-object handle, opaque_e its reference count.
    let count = plugin(cas).loaded(object)?.refs.count ?? 0
    return llcas_object_refs_t(opaque_b: object.opaque, opaque_e: UInt64(count))
}

@_cdecl("llcas_object_refs_get_count")
public func llcas_object_refs_get_count(_ cas: llcas_cas_t?, _ refs: llcas_object_refs_t) -> Int {
    Int(refs.opaque_e)
}

@_cdecl("llcas_object_refs_get_id")
public func llcas_object_refs_get_id(
    _ cas: llcas_cas_t?, _ refs: llcas_object_refs_t, _ index: Int
) -> llcas_objectid_t {
    plugin(cas).loaded(llcas_loaded_object_t(opaque: refs.opaque_b))?.refs[index]
        ?? llcas_objectid_t(opaque: 0)
}

@_cdecl("llcas_loaded_object_export_data_to_filepath")
public func llcas_loaded_object_export_data_to_filepath(
    _ cas: llcas_cas_t?, _ object: llcas_loaded_object_t, _ path: UnsafePointer<CChar>?,
    _ error: ErrorOut
) -> Bool {
    guard let path, let loaded = plugin(cas).loaded(object) else {
        setError(error, "invalid object or path")
        return true
    }
    do {
        let data = Data(bytes: loaded.data, count: loaded.size)
        try data.write(to: URL(fileURLWithPath: String(cString: path)))
        return false
    } catch let failure {
        setError(error, "\(failure)")
        return true
    }
}

// MARK: - Action cache

private func actionGet(
    _ instance: Plugin, _ key: llcas_digest_t, globally: Bool
) -> (result: llcas_lookup_result_t, value: llcas_objectid_t, message: String?) {
    let none = llcas_objectid_t(opaque: 0)
    let keyDigest = digest(key)
    do {
        if let value = try instance.store.actionGet(keyDigest) {
            return (LLCAS_LOOKUP_RESULT_SUCCESS, instance.objectID(for: value), nil)
        }
        if globally, let remote = instance.remote, let fetched = remote.actionGet(keyDigest),
           let value = fetched {
            try instance.store.actionPut(keyDigest, value: value)
            remote.log("action \(keyDigest.hex) hit remotely")
            return (LLCAS_LOOKUP_RESULT_SUCCESS, instance.objectID(for: value), nil)
        }
        return (LLCAS_LOOKUP_RESULT_NOTFOUND, none, nil)
    } catch {
        return (LLCAS_LOOKUP_RESULT_ERROR, none, "\(error)")
    }
}

@_cdecl("llcas_actioncache_get_for_digest")
public func llcas_actioncache_get_for_digest(
    _ cas: llcas_cas_t?, _ key: llcas_digest_t, _ out: UnsafeMutablePointer<llcas_objectid_t>?,
    _ globally: Bool, _ error: ErrorOut
) -> llcas_lookup_result_t {
    let found = actionGet(plugin(cas), key, globally: globally)
    if let message = found.message { setError(error, message) }
    if found.result == LLCAS_LOOKUP_RESULT_SUCCESS { out?.pointee = found.value }
    return found.result
}

@_cdecl("llcas_actioncache_get_for_digest_async")
public func llcas_actioncache_get_for_digest_async(
    _ cas: llcas_cas_t?, _ key: llcas_digest_t, _ globally: Bool, _ context: UnsafeMutableRawPointer?,
    _ callback: llcas_actioncache_get_cb?, _ cancel: UnsafeMutablePointer<llcas_cancellable_t?>?
) {
    cancel?.pointee = nil
    let found = actionGet(plugin(cas), key, globally: globally)
    callback?(context, found.result, found.value, found.message.flatMap { strdup($0) })
}

private func actionPut(
    _ instance: Plugin, _ key: llcas_digest_t, _ value: llcas_objectid_t, globally: Bool
) -> String? {
    guard let valueDigest = instance.digest(of: value) else { return "unknown object id" }
    let keyDigest = digest(key)
    do {
        try instance.store.actionPut(keyDigest, value: valueDigest)
        // Share the result only if all of it can be shared: the action entry
        // must never point at an object another machine cannot fetch.
        if globally, let remote = instance.remote, remote.isEnabled {
            if remote.ensureUploaded(valueDigest, from: instance.store),
               remote.actionPut(keyDigest, value: valueDigest) {
                remote.log("shared action \(keyDigest.hex)")
            } else {
                remote.log("kept action \(keyDigest.hex) local")
            }
        }
        return nil
    } catch {
        return "\(error)"
    }
}

@_cdecl("llcas_actioncache_put_for_digest")
public func llcas_actioncache_put_for_digest(
    _ cas: llcas_cas_t?, _ key: llcas_digest_t, _ value: llcas_objectid_t, _ globally: Bool,
    _ error: ErrorOut
) -> Bool {
    if let message = actionPut(plugin(cas), key, value, globally: globally) {
        setError(error, message)
        return true
    }
    return false
}

@_cdecl("llcas_actioncache_put_for_digest_async")
public func llcas_actioncache_put_for_digest_async(
    _ cas: llcas_cas_t?, _ key: llcas_digest_t, _ value: llcas_objectid_t, _ globally: Bool,
    _ context: UnsafeMutableRawPointer?, _ callback: llcas_actioncache_put_cb?,
    _ cancel: UnsafeMutablePointer<llcas_cancellable_t?>?
) {
    cancel?.pointee = nil
    let message = actionPut(plugin(cas), key, value, globally: globally)
    callback?(context, message != nil, message.flatMap { strdup($0) })
}
