import CASProtocol
import CLLCAS
import Foundation

/// State behind one `llcas_cas_t`. Handles given to the client (object IDs,
/// loaded objects, digest buffers) stay valid until `llcas_cas_dispose`.
final class Plugin: @unchecked Sendable {
    struct Loaded {
        var data: UnsafeMutableRawPointer
        var size: Int
        var refs: [llcas_objectid_t]
    }

    let store: LocalStore
    let remote: RemoteTier?
    /// See `RemoteConfig.remoteScopeIsAll`.
    let remoteScopeIsAll: Bool
    private let lock = NSLock()
    private var digests: [CASDigest] = []
    private var digestBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var indexByDigest: [CASDigest: Int] = [:]
    private var loaded: [Loaded] = []

    init(store: LocalStore, remote: RemoteTier?, remoteScopeIsAll: Bool = false) {
        self.store = store
        self.remote = remote
        self.remoteScopeIsAll = remoteScopeIsAll
    }

    /// Whether a request is served by the shared tier: when the compiler asks
    /// for it (`globally`), or always when the plugin was configured that way.
    func wantsRemote(globally: Bool) -> Bool {
        globally || remoteScopeIsAll
    }

    deinit {
        remote?.close()
        for buffer in digestBuffers { buffer.deallocate() }
        for object in loaded { free(object.data) }
    }

    /// Object IDs are 1-based indexes into `digests`; 0 is never valid.
    func objectID(for digest: CASDigest) -> llcas_objectid_t {
        lock.lock()
        defer { lock.unlock() }
        if let index = indexByDigest[digest] {
            return llcas_objectid_t(opaque: UInt64(index + 1))
        }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(digest.bytes.count, 1))
        buffer.initialize(from: digest.bytes, count: digest.bytes.count)
        digests.append(digest)
        digestBuffers.append(buffer)
        indexByDigest[digest] = digests.count - 1
        return llcas_objectid_t(opaque: UInt64(digests.count))
    }

    func digest(of id: llcas_objectid_t) -> CASDigest? {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(id.opaque) - 1
        return digests.indices.contains(index) ? digests[index] : nil
    }

    func digestBuffer(of id: llcas_objectid_t) -> llcas_digest_t {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(id.opaque) - 1
        guard digestBuffers.indices.contains(index) else {
            return llcas_digest_t(data: nil, size: 0)
        }
        return llcas_digest_t(data: UnsafePointer(digestBuffers[index]), size: digests[index].bytes.count)
    }

    func addLoaded(_ object: StoredObject) -> llcas_loaded_object_t {
        // The API requires an 8-byte aligned buffer with a trailing NUL.
        var raw: UnsafeMutableRawPointer?
        posix_memalign(&raw, 8, object.data.count + 1)
        let pointer = raw!
        object.data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                pointer.copyMemory(from: base, byteCount: object.data.count)
            }
        }
        pointer.storeBytes(of: 0, toByteOffset: object.data.count, as: UInt8.self)
        let refs = object.refs.map { objectID(for: $0) }
        lock.lock()
        defer { lock.unlock() }
        loaded.append(Loaded(data: pointer, size: object.data.count, refs: refs))
        return llcas_loaded_object_t(opaque: UInt64(loaded.count))
    }

    func loaded(_ handle: llcas_loaded_object_t) -> Loaded? {
        lock.lock()
        defer { lock.unlock() }
        let index = Int(handle.opaque) - 1
        return loaded.indices.contains(index) ? loaded[index] : nil
    }
}

final class PluginOptions: @unchecked Sendable {
    var onDiskPath: String?
    var options: [String: String] = [:]
}
