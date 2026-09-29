import CASClient
import CASProtocol
import CLLCAS
import Distributed
import Foundation
import WorkersDistributed
import XCTest

@testable import CASPlugin

/// Needs a running Worker: set LLBUILD_CAS_TEST_URL (Scripts/test-remote-cache.sh does).
final class RemoteIntegrationTests: XCTestCase {
    private final class LoadResult: @unchecked Sendable {
        let continuation: CheckedContinuation<llcas_lookup_result_t, Never>
        init(_ continuation: CheckedContinuation<llcas_lookup_result_t, Never>) {
            self.continuation = continuation
        }
    }

    /// Swift Build calls the plugin's async entry points from Swift
    /// concurrency's worker threads, several at once. An implementation that
    /// blocks such a thread while waiting on work that also needs one starves
    /// the pool: every thread waits and nothing runs. This calls the async load
    /// from many more tasks than there are threads, against an empty local
    /// store so every load has to go to the Worker.
    func testManyConcurrentAsyncLoadsFromTheCooperativePoolComplete() async throws {
        guard let text = ProcessInfo.processInfo.environment["LLBUILD_CAS_TEST_URL"], let url = URL(string: text) else {
            throw XCTSkip("set LLBUILD_CAS_TEST_URL to a running Worker")
        }

        let client = try CASClient(workerURL: url)
        var digests = [CASDigest]()
        for index in 0..<96 {
            let blob = CASBlob(refs: [], data: Array("pool test \(index) \(UUID())".utf8))
            digests.append(try await client.put(blob))
        }
        await client.close()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugin-pool-test-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: directory) }

        var failure: UnsafeMutablePointer<CChar>?
        let options = llcas_cas_options_create()
        llcas_cas_options_set_ondisk_path(options, directory)
        XCTAssertFalse(llcas_cas_options_set_option(options, "remote-url", text, &failure))
        let cas = try XCTUnwrap(llcas_cas_create(options, &failure), "cas_create failed")
        llcas_cas_options_dispose(options)
        defer { llcas_cas_dispose(cas) }

        nonisolated(unsafe) let casHandle = cas
        let start = Date()
        let results = await withTaskGroup(of: llcas_lookup_result_t.self) { group in
            for digest in digests {
                group.addTask {
                    var id = llcas_objectid_t()
                    var error: UnsafeMutablePointer<CChar>?
                    let failed = digest.bytes.withUnsafeBufferPointer {
                        llcas_cas_get_objectid(
                            casHandle, llcas_digest_t(data: $0.baseAddress, size: $0.count), &id, &error)
                    }
                    if failed { return LLCAS_LOOKUP_RESULT_ERROR }
                    return await withCheckedContinuation { continuation in
                        let box = Unmanaged.passRetained(LoadResult(continuation))
                        llcas_cas_load_object_async(casHandle, id, box.toOpaque(), { context, result, _, error in
                            llcas_string_dispose(error)
                            Unmanaged<LoadResult>.fromOpaque(context!).takeRetainedValue()
                                .continuation.resume(returning: result)
                        }, nil)
                    }
                }
            }
            var all = [llcas_lookup_result_t]()
            for await result in group { all.append(result) }
            return all
        }

        XCTAssertEqual(results.count, digests.count)
        XCTAssertTrue(
            results.allSatisfy { $0 == LLCAS_LOOKUP_RESULT_SUCCESS },
            "every object should be fetched from the Worker")
        // A starved pool shows up as 30 s timeouts, not as a failure of the loads.
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "loads should not wait on timeouts")
    }

    /// A manifest may list one chunk many times, so its reference list can
    /// describe far more data than its declared size. The Worker must stop
    /// before assembling it, not after: unbounded, 15,000 references to one
    /// 256 KiB chunk (about what a 1 MiB message can carry) is nearly 4 GB.
    func testManifestListingMoreDataThanItDeclaresIsRejectedEarly() async throws {
        guard let text = ProcessInfo.processInfo.environment["LLBUILD_CAS_TEST_URL"], let url = URL(string: text) else {
            throw XCTSkip("set LLBUILD_CAS_TEST_URL to a running Worker")
        }
        let system = WorkersActorSystem(worker: url)
        defer { system.close() }
        let service = try CASService.resolve(id: "cas-service", using: system)

        var bytes = Array(UUID().uuidString.utf8)
        bytes += [UInt8](repeating: 7, count: CASLimits.chunkBytes - bytes.count)
        let chunk = CASBlob(refs: [], data: bytes)
        try await service.put(
            digest: chunk.digest.hex, refs: [], data: Data(chunk.data).base64EncodedString())

        // 40 references (10 MiB of chunk data) under a manifest that declares 600,000 bytes.
        let refs = [CASDigest](repeating: chunk.digest, count: 40)
        let manifest = CASBlob(refs: refs, data: CASChunking.manifestData(size: 600_000))
        try await service.put(
            digest: manifest.digest.hex, refs: refs.map(\.hex),
            data: Data(manifest.data).base64EncodedString())

        do {
            try await service.putLarge(
                digest: CASIdentity.identify(refs: [], data: [1, 2, 3]).hex, refs: [],
                manifest: manifest.digest.hex)
            XCTFail("a manifest listing more data than it declares must be rejected")
        } catch {
            // The early bound names the declared size; assembling everything
            // first would only notice the total afterwards.
            XCTAssertTrue("\(error)".contains("declared size"), "rejected, but not by the early bound: \(error)")
        }
    }

    private final class Probe: Sendable {}

    /// A finished call must not keep its completion (and whatever that captured)
    /// alive until the timeout: with a 30 s deadline per call, and 300 s for a
    /// publish, a long build would otherwise pile up retained plugin state.
    func testFinishedCallReleasesItsCompletionBeforeTheTimeout() async throws {
        guard let text = ProcessInfo.processInfo.environment["LLBUILD_CAS_TEST_URL"], let url = URL(string: text) else {
            throw XCTSkip("set LLBUILD_CAS_TEST_URL to a running Worker")
        }
        let tier = RemoteTier(url: url)
        let missing = CASIdentity.identify(refs: [], data: Array(UUID().uuidString.utf8))
        weak var probe: Probe?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held = Probe()
            probe = held
            tier.run("contains", { try await $0.contains(missing) }) { _ in
                _ = held
                continuation.resume()
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(probe, "the completion was still retained after the call finished")
        tier.close()
    }
}
