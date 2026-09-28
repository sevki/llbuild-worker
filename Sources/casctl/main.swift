import CASClient
import CASProtocol
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: casctl <worker-url> <command>

    commands:
      status                    print the service status (exit 2 if it has no storage)
      put <file>                store a file as an object and print its digest
      get <digest> <out-file>   fetch an object's data into a file
      has <digest>              exit 0 if the object exists, 1 if not

    """.utf8))
    exit(64)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("casctl: \(message)\n".utf8))
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
            FileHandle.standardError.write(Data("casctl: not found\n".utf8))
            return 1
        }
        try Data(blob.data).write(to: URL(fileURLWithPath: arguments[4]))
        return 0

    case ("has", 4):
        return try await client.contains(digest(arguments[3])) ? 0 : 1

    default:
        usage()
    }
}

var status: Int32
do {
    status = try await run()
} catch {
    FileHandle.standardError.write(Data("casctl: \(error)\n".utf8))
    status = 1
}
await client.close()
exit(status)
