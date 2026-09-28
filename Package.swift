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
        // Merged workers-swift PR #12 provides the native WebSocket transport and RPCGateway.
        .package(
            url: "https://github.com/sevki/workers-swift.git",
            revision: "2db5bab408d8a2aeae720cd123a92b32e2d73c43"
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
                .product(name: "WorkersDistributed", package: "workers-swift")
            ]
        ),
        .target(name: "CLLCAS"),
        .target(
            name: "CASPlugin",
            dependencies: ["CASProtocol", "CLLCAS"]
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
