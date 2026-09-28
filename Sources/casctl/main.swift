import CASProtocol
import Foundation
import WorkersDistributed

func usage() -> Never {
    FileHandle.standardError.write(
        Data("usage: casctl <worker-url> status\n".utf8)
    )
    exit(64)
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let workerURL = URL(string: arguments[1]),
      ["http", "https"].contains(workerURL.scheme ?? "") else {
    usage()
}

guard arguments[2] == "status" else {
    usage()
}

let system = WorkersActorSystem(worker: workerURL)

do {
    let service = try CASService.resolve(id: "cas-service", using: system)
    let status = try await service.status()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(status))
    FileHandle.standardOutput.write(Data([0x0a]))
    system.close()
    await system.wait()
    if !status.storageConfigured {
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    system.close()
    await system.wait()
    exit(1)
}
