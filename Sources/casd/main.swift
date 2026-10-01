import CASClient
import CASDaemon
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: casd --upstream <worker-url> [--listen <host:port>] [--cache <dir>] [--max-gb <n>]

    Serves the Worker's protocol on the loopback and forwards to <worker-url>
    (a scope is taken from the request path: <worker-url>/<scope>). Point the
    plugin's remote-url at http://<host>:<port>/<scope>. The access token comes
    from LLBUILD_CAS_TOKEN or ~/.config/llbuild-cas-remote-token.

      --listen    default 127.0.0.1:4170
      --cache     default ~/.cache/llbuild-casd
      --max-gb    local cache size per scope, default 4

    """.utf8))
    exit(64)
}

var upstream: URL?
var host = "127.0.0.1"
var port = 4170
var cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache/llbuild-casd")
var maxGB = 4.0

var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard let value = arguments.popFirst() else { usage() }
    switch flag {
    case "--upstream": upstream = URL(string: value)
    case "--listen":
        let parts = value.split(separator: ":")
        guard parts.count == 2, let parsed = Int(parts[1]) else { usage() }
        host = String(parts[0])
        port = parsed
    case "--cache": cache = URL(fileURLWithPath: value)
    case "--max-gb": maxGB = Double(value) ?? 4
    default: usage()
    }
}
guard let upstream, ["http", "https"].contains(upstream.scheme ?? "") else { usage() }

let verbose = ProcessInfo.processInfo.environment["LLBUILD_CAS_DEBUG"] != nil
let daemon = CASDaemon(
    .init(host: host, port: port, directory: cache, maxBytes: Int64(maxGB * 1_073_741_824)) { scope in
        ClientUpstream(url: upstream.appendingPathComponent(scope))
    },
    log: { message in
        if verbose { FileHandle.standardError.write(Data("casd: \(message)\n".utf8)) }
    })

do {
    let bound = try await daemon.start()
    FileHandle.standardOutput.write(Data("casd listening on \(host):\(bound), upstream \(upstream.absoluteString)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("casd: cannot listen on \(host):\(port): \(error)\n".utf8))
    exit(1)
}

// Until told to stop; on a signal, let acknowledged writes reach the Worker first.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
let stopped = AsyncStream<Void> { continuation in
    for signo in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
        source.setEventHandler { continuation.yield() }
        source.resume()
        signalSources.append(source)
    }
}
for await _ in stopped { break }
// Acknowledged writes get a little time to reach the Worker; what has not is queued on
// disk and goes on the next run. A Worker that is not answering must not hold the exit,
// so the deadline ends the process outright rather than waiting for the drain to notice.
Task {
    try? await Task.sleep(for: .seconds(30))
    FileHandle.standardError.write(Data("casd: stopping with writes still queued on disk\n".utf8))
    exit(0)
}
await daemon.drain()
for line in await daemon.summaries() { FileHandle.standardError.write(Data("casd: \(line)\n".utf8)) }
await daemon.stop()
