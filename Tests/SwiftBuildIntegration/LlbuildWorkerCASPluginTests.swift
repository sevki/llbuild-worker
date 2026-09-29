// Scratch test (not part of swift-build): drives Swift Build, the build engine
// behind Xcode, against the llbuild-worker CAS plugin and a running Worker.
//   LLBUILD_CAS_PLUGIN  path to libCASPlugin
//   LLBUILD_CAS_REMOTE  path to a file holding the Worker URL
import Testing

import SWBCore
import SWBTestSupport
import SWBUtil
import SWBTaskExecution
import SWBProtocol

@Suite(.requireSwiftFeatures(.compilationCaching))
fileprivate struct LlbuildWorkerCASPluginTests: CoreBasedTests {
    @Test(.requireSDKs(.host))
    func remoteCachingThroughLlbuildWorkerPlugin() async throws {
        let pluginPath = try #require(getEnvironmentVariable("LLBUILD_CAS_PLUGIN")?.nilIfEmpty)
        let remoteConfig = try #require(getEnvironmentVariable("LLBUILD_CAS_REMOTE")?.nilIfEmpty)

        try await withTemporaryDirectory { (tmpDir: Path) in
            let testProject = try await TestProject(
                "TestProject",
                sourceRoot: tmpDir,
                groupTree: TestGroup("Sources", children: [TestFile("file.swift")]),
                buildConfigurations: [
                    TestBuildConfiguration("Debug", buildSettings: [
                        "ARCHS": "$(ARCHS_STANDARD)",
                        "PRODUCT_NAME": "$(TARGET_NAME)",
                        "SDKROOT": "$(HOST_PLATFORM)",
                        "SUPPORTED_PLATFORMS": "$(HOST_PLATFORM)",
                        "SWIFT_VERSION": swiftVersion,
                        "CODE_SIGNING_ALLOWED": "NO",
                        "SWIFT_ENABLE_COMPILE_CACHE": "YES",
                        "SWIFT_ENABLE_EXPLICIT_MODULES": "YES",
                        "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS": "YES",
                        "COMPILATION_CACHE_ENABLE_PLUGIN": "YES",
                        "COMPILATION_CACHE_PLUGIN_PATH": pluginPath,
                        "COMPILATION_CACHE_REMOTE_SERVICE_PATH": remoteConfig,
                    ])
                ],
                targets: [
                    TestStandardTarget(
                        "Library",
                        type: .staticLibrary,
                        buildConfigurations: [TestBuildConfiguration("Debug", buildSettings: [:])],
                        buildPhases: [TestSourcesBuildPhase(["file.swift"])]
                    ),
                ])
            let tester = try await BuildOperationTester(try await getCore(), testProject, simulated: false)
            let projectDir = tester.workspace.projects[0].sourceRoot
            try await tester.fs.writeFileContents(projectDir.join("file.swift")) { $0 <<< "public func libFunc() -> Int { 7 }\n" }

            // "Machine" 1: empty everything, publishes to the Worker.
            let one = BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": tmpDir.join("CompilationCache1").str])
            try await tester.checkBuild(parameters: one, runDestination: .host, persistent: true) { results in
                let compile: Task = try results.checkTask(.matchRuleType("SwiftCompile")) { $0 }
                results.check(contains: .taskHadEvent(compile, event: .hadOutput(contents: "Cache miss\n")))
                results.checkNoErrors()
            }

            try await tester.checkBuild(runDestination: .host, buildCommand: .cleanBuildFolder(style: .regular), body: { _ in })

            // "Machine" 2: a different, empty local CAS and the same Worker.
            let two = BuildParameters(configuration: "Debug", overrides: ["COMPILATION_CACHE_CAS_PATH": tmpDir.join("CompilationCache2").str])
            try await tester.checkBuild(parameters: two, runDestination: .host, persistent: true) { results in
                let compile: Task = try results.checkTask(.matchRuleType("SwiftCompile")) { $0 }
                results.check(contains: .taskHadEvent(compile, event: .hadOutput(contents: "Cache hit\n")))
                results.checkNoErrors()
            }
        }
    }
}
