// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "llbuild-worker",
    products: [
        .library(name: "CASProtocol", targets: ["CASProtocol"]),
        .executable(name: "casctl", targets: ["casctl"]),
        // Loaded by swift-frontend via -cas-plugin-path for compilation caching.
        .library(name: "CASPlugin", type: .dynamic, targets: ["CASPlugin"]),
        .executable(name: "CASWorkerWasm", targets: ["CASWorkerWasm"]),
    ],
    dependencies: [
        // workers-swift PR #12 provides the native WebSocket transport. Pinned to
        // PR #13's commit, which lets the native client receive replies over 16 KiB;
        // move back to a merge commit on main once #13 lands.
        .package(
            url: "https://github.com/sevki/workers-swift.git",
            revision: "0094ea55669aafa2cad7ed252ae5582aafaf9997"
        ),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
    ],
    targets: [
        .target(
            name: "CASProtocol",
            dependencies: [
                .product(name: "WorkersDistributed", package: "workers-swift")
            ]
        ),
        .executableTarget(
            name: "casctl",
            dependencies: [
                "CASProtocol",
                "CASClient",
                .product(name: "WorkersDistributed", package: "workers-swift")
            ]
        ),
        .target(name: "CLLCAS"),
        // Native-only client for the CAS service; shared by casctl and the plugin.
        .target(
            name: "CASClient",
            dependencies: [
                "CASProtocol",
                .product(name: "WorkersDistributed", package: "workers-swift")
            ]
        ),
        .target(
            name: "CASPlugin",
            dependencies: ["CASProtocol", "CASClient", "CLLCAS"]
        ),
        .target(
            name: "CASWorker",
            dependencies: [
                "CASProtocol",
                .product(name: "WorkersSwift", package: "workers-swift"),
                .product(name: "WorkersDistributed", package: "workers-swift"),
                .product(name: "JavaScriptKit", package: "JavaScriptKit")
            ]
        ),
        .executableTarget(
            name: "CASWorkerWasm",
            dependencies: [
                .target(name: "CASWorker", condition: .when(platforms: [.wasi]))
            ]
        ),
        .testTarget(name: "CASProtocolTests", dependencies: ["CASProtocol"]),
        .testTarget(name: "CASPluginTests", dependencies: ["CASPlugin", "CASProtocol"]),
    ]
)
