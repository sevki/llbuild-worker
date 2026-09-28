// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "llbuild-worker",
    products: [
        .library(name: "CASProtocol", targets: ["CASProtocol"]),
        .executable(name: "casctl", targets: ["casctl"]),
        .executable(name: "CASWorkerWasm", targets: ["CASWorkerWasm"]),
    ],
    dependencies: [
        // PR #12 adds the native WebSocket transport and RPCGateway used by casctl.
        .package(
            url: "https://github.com/sevki/workers-swift.git",
            revision: "69f99e254b096d140be335dd764d9be2743d56d4"
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
            ],
            plugins: [
                .plugin(name: "WorkerBuild", package: "workers-swift")
            ]
        ),
        .testTarget(name: "CASProtocolTests", dependencies: ["CASProtocol"]),
    ]
)
