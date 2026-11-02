// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CompanionLLM", targets: ["CompanionLLM"]),
        .library(name: "CompanionPageFinder", targets: ["CompanionPageFinder"]),
        .library(name: "CompanionBridge", targets: ["CompanionBridge"]),
        .library(name: "CompanionCapture", targets: ["CompanionCapture"]),
        .library(name: "CompanionUI", targets: ["CompanionUI"]),
        .library(name: "CompanionSession", targets: ["CompanionSession"]),
        .executable(name: "CompanionUIDemo", targets: ["CompanionUIDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "CompanionLLM", dependencies: ["CompanionCore"]),
        .target(name: "CompanionPageFinder", dependencies: ["CompanionCore"]),
        .target(name: "CompanionBridge", dependencies: ["CompanionCore"]),
        .target(name: "CompanionCapture", dependencies: ["CompanionCore"]),
        .target(name: "CompanionUI", dependencies: ["CompanionCore", "KeyboardShortcuts"],
                resources: [.copy("Resources/web")]),
        .target(name: "CompanionSession", dependencies: [
            "CompanionCore", "CompanionLLM", "CompanionPageFinder",
            "CompanionBridge", "CompanionCapture", "CompanionUI"]),
        .executableTarget(name: "CompanionUIDemo", dependencies: ["CompanionUI", "CompanionCore"]),
        .target(name: "CompanionTestSupport", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore", "CompanionTestSupport"]),
        .testTarget(name: "CompanionLLMTests", dependencies: ["CompanionLLM", "CompanionTestSupport"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "CompanionPageFinderTests", dependencies: ["CompanionPageFinder", "CompanionTestSupport"]),
        .testTarget(name: "CompanionBridgeTests", dependencies: ["CompanionBridge", "CompanionTestSupport"]),
        .testTarget(name: "CompanionCaptureTests", dependencies: ["CompanionCapture", "CompanionTestSupport"]),
        .testTarget(name: "CompanionUITests", dependencies: ["CompanionUI", "CompanionTestSupport"]),
        .testTarget(name: "CompanionSessionTests", dependencies: [
            "CompanionSession", "CompanionCore", "CompanionLLM", "CompanionPageFinder",
            "CompanionBridge", "CompanionCapture", "CompanionUI", "CompanionTestSupport"]),
    ]
)
