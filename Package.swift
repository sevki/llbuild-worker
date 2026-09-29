// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "llbuild-worker",
    products: [
        .library(name: "CASProtocol", targets: ["CASProtocol"]),
        .executable(name: "castool", targets: ["castool"]),
        // Loaded by swift-frontend via -cas-plugin-path for compilation caching.
        .library(name: "CASPlugin", type: .dynamic, targets: ["CASPlugin"]),
        .executable(name: "CASWorkerWasm", targets: ["CASWorkerWasm"]),
    ],
    dependencies: [
        // workers-swift's native WebSocket transport (PR #12) with the client
        // frame-size fix (PR #13), pinned at its merge commit on main.
        .package(
            url: "https://github.com/sevki/workers-swift.git",
            revision: "aaad96f185eaf30e74f8e817d683c10511de7a7b"
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
            name: "castool",
            dependencies: [
                "CASProtocol",
                "CASClient",
                .product(name: "WorkersDistributed", package: "workers-swift")
            ]
        ),
        .target(name: "CLLCAS"),
        // Native-only client for the CAS service; shared by castool and the plugin.
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
