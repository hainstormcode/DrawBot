// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DrawBot",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: image loading, color quantization, stroke planning, geometry. No AppKit.
        .target(name: "DrawBotCore", path: "Sources/DrawBotCore"),
        // macOS system layer: synthetic mouse events, permissions, hotkeys, window inspection, drawing engine.
        .target(name: "DrawBotSystem", dependencies: ["DrawBotCore"], path: "Sources/DrawBotSystem"),
        // The menu-bar app: UI, canvas selection overlay, color prompts, orchestration.
        .executableTarget(name: "DrawBot", dependencies: ["DrawBotCore", "DrawBotSystem"], path: "Sources/DrawBot"),
        // Dev tool: runs Color Learn on recorded demonstrations (JSON in, JSON out). See Tools/README.md.
        .executableTarget(name: "colorlearn-harness", dependencies: ["DrawBotCore"], path: "Tools/ColorLearnHarness"),
        // Dev tool: a separate app that plays scripted real input and records it with DrawBot's recorder.
        // Built into build/DrawBotTestRig.app by scripts/build_testrig.sh. See Tools/README.md.
        .executableTarget(name: "DrawBotTestRig", dependencies: ["DrawBotCore", "DrawBotSystem"], path: "Tools/TestRig"),
        .testTarget(name: "DrawBotCoreTests", dependencies: ["DrawBotCore"], path: "Tests/DrawBotCoreTests"),
        .testTarget(name: "DrawBotSystemTests", dependencies: ["DrawBotSystem", "DrawBotCore"], path: "Tests/DrawBotSystemTests"),
    ]
)
