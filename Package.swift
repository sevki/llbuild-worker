// swift-tools-version: 6.3

import PackageDescription

// Everything is built through the compile cache in CI, including test
// targets' dependencies, but not the test targets' own compiles: SwiftPM finds
// tests through the index store, and a compile replayed from the cache does not
// write index data ("index store path does not exist" / "Failed opening
// .../index/store/.../units/X.swift.o-..."). -cache-disable-replay makes these
// compiles run even on a hit, so they write it; it does nothing without the
// cache flags.
let testSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xfrontend", "-cache-disable-replay"])]

let package = Package(
    name: "llbuild-worker",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CASProtocol", targets: ["CASProtocol"]),
        .executable(name: "castool", targets: ["castool"]),
        // Loaded by swift-frontend via -cas-plugin-path for compilation caching.
        .library(name: "CASPlugin", type: .dynamic, targets: ["CASPlugin"]),
        .executable(name: "CASWorkerWasm", targets: ["CASWorkerWasm"]),
    ],
    dependencies: [
        // WorkerKit's native WebSocket transport (PR #12) with the client
        // frame-size fix (PR #13), R2 bindings (PR #14), worker-build's `--`
        // pass-through (PR #16) and Request.cf (PR #17), pinned at its merge
        // commit on main.
        .package(
            url: "https://github.com/sevki/WorkerKit.git",
            revision: "4821611f07708cb4402922b584323dec5668a5b4"
        ),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
        .package(url: "https://github.com/pointfreeco/swift-html", from: "0.5.0"),
        // SI prefixes (symbol and power of ten) for the sizes the stats page shows.
        .package(url: "https://github.com/moriturus/SystemeInternational.git", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "CASProtocol",
            dependencies: [
                .product(name: "WorkerKitDistributed", package: "WorkerKit"),
                .product(name: "PrefixesDuSI", package: "SystemeInternational"),
            ]
        ),
        .executableTarget(
            name: "castool",
            dependencies: [
                "CASProtocol",
                "CASClient",
                .product(name: "WorkerKitDistributed", package: "WorkerKit")
            ]
        ),
        .target(name: "CLLCAS"),
        // Native-only client for the CAS service; shared by castool and the plugin.
        .target(
            name: "CASClient",
            dependencies: [
                "CASProtocol",
                .product(name: "WorkerKitDistributed", package: "WorkerKit")
            ]
        ),
        .target(
            name: "CASPlugin",
            dependencies: ["CASProtocol", "CASClient", "CLLCAS"],
            linkerSettings: [
                // swift-frontend dlcloses the plugin when it exits, while the
                // WebSocket client's NIO threads are still running; they then
                // execute unmapped code and the compiler crashes (signal 11,
                // reported as "generate-pcm command failed"). NODELETE keeps
                // the library mapped for the life of the process.
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "nodelete"], .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "CASWorker",
            dependencies: [
                "CASProtocol",
                .product(name: "WorkerKit", package: "WorkerKit", condition: .when(platforms: [.wasi])),
                .product(name: "WorkerKitDistributed", package: "WorkerKit"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit", condition: .when(platforms: [.wasi])),
                .product(name: "Html", package: "swift-html")
            ]
        ),
        .executableTarget(
            name: "CASWorkerWasm",
            dependencies: [
                .target(name: "CASWorker", condition: .when(platforms: [.wasi]))
            ]
        ),
        .testTarget(name: "CASProtocolTests", dependencies: [
            "CASProtocol", "CASClient",
            .product(name: "WorkerKitDistributed", package: "WorkerKit"),
        ], swiftSettings: testSwiftSettings),
        .testTarget(name: "CASPluginTests", dependencies: ["CASPlugin", "CASProtocol"], swiftSettings: testSwiftSettings),
    ]
)
