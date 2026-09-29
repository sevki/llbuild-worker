// swift-tools-version: 6.3

import PackageDescription

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
        // frame-size fix (PR #13) and R2 bindings (PR #14), pinned at its merge commit on main.
        .package(
            url: "https://github.com/sevki/WorkerKit.git",
            revision: "564ada3494f7a24df5b232831907c1fce3704de2"
        ),
        .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.59.0"),
        .package(url: "https://github.com/pointfreeco/swift-html", from: "0.5.0"),
    ],
    targets: [
        .target(
            name: "CASProtocol",
            dependencies: [
                .product(name: "WorkerKitDistributed", package: "WorkerKit")
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
            dependencies: ["CASProtocol", "CASClient", "CLLCAS"]
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
        .testTarget(name: "CASProtocolTests", dependencies: ["CASProtocol"]),
        .testTarget(name: "CASPluginTests", dependencies: ["CASPlugin", "CASProtocol"]),
    ]
)
