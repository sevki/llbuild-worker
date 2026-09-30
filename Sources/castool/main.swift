import CASClient
import CASProtocol
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: castool <worker-url> <command>

    commands:
      status                    print the service status (exit 2 if it has no storage)
      put <file>                store a file as an object and print its digest
      get <digest> <out-file>   fetch an object's data into a file
      has <digest>              exit 0 if the object exists, 1 if not
      bench <count> <size>      seed <count> distinct <size>-byte objects (sequentially,
                                 not timed), then fetch all of them concurrently on one
                                 client and print the wall-clock time — the read path is
                                 what many concurrent compile jobs actually exercise, so
                                 it is the one worth timing under concurrency

    """.utf8))
    exit(64)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("castool: \(message)\n".utf8))
    exit(code)
}

func digest(_ text: String) -> CASDigest {
    guard let parsed = CASDigest(hex: text), parsed.bytes.count == CASIdentity.digestSize else {
        fail("not a valid digest: \(text)", code: 64)
    }
    return parsed
}

let arguments = CommandLine.arguments
guard arguments.count >= 3,
      let workerURL = URL(string: arguments[1]),
      ["http", "https"].contains(workerURL.scheme ?? "") else {
    usage()
}

let client: CASClient
do {
    client = try CASClient(workerURL: workerURL)
} catch {
    fail("\(error)")
}

func run() async throws -> Int32 {
    switch (arguments[2], arguments.count) {
    case ("status", 3):
        let status = try await client.status()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(status))
        FileHandle.standardOutput.write(Data([0x0a]))
        return status.storageConfigured ? 0 : 2

    case ("put", 4):
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: arguments[3])))
        let stored = try await client.put(CASBlob(refs: [], data: bytes))
        print(stored.hex)
        return 0

    case ("get", 5):
        guard let blob = try await client.get(digest(arguments[3])) else {
            FileHandle.standardError.write(Data("castool: not found\n".utf8))
            return 1
        }
        try Data(blob.data).write(to: URL(fileURLWithPath: arguments[4]))
        return 0

    case ("has", 4):
        return try await client.contains(digest(arguments[3])) ? 0 : 1

    case ("bench", 5):
        guard let count = Int(arguments[3]), count > 0 else { fail("not a valid count: \(arguments[3])", code: 64) }
        guard let size = Int(arguments[4]), size > 0 else { fail("not a valid size: \(arguments[4])", code: 64) }

        // Distinct content per object, so each seeds its own digest instead
        // of every put deduplicating onto one.
        var digests = [CASDigest]()
        digests.reserveCapacity(count)
        for index in 0..<count {
            var bytes = [UInt8](repeating: 0, count: size)
            for offset in 0..<min(size, 8) { bytes[offset] = UInt8(truncatingIfNeeded: index &+ offset) }
            digests.append(try await client.put(CASBlob(refs: [], data: bytes)))
        }

        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for target in digests {
                group.addTask {
                    guard try await client.get(target) != nil else {
                        throw CASClientError("bench: object \(target.hex) missing right after put")
                    }
                }
            }
            try await group.waitForAll()
        }
        let elapsed = start.duration(to: clock.now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18

        print("bench: n=\(count) size=\(size)B concurrent_get_total=\(String(format: "%.3f", seconds))s "
            + "avg_latency=\(String(format: "%.1f", seconds / Double(count) * 1000))ms "
            + "throughput=\(String(format: "%.1f", Double(count) / seconds))obj/s")
        return 0

    default:
        usage()
    }
}

var status: Int32
do {
    status = try await run()
} catch {
    FileHandle.standardError.write(Data("castool: \(error)\n".utf8))
    status = 1
}
await client.close()
exit(status)
