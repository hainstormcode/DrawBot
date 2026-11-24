// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DrawBot",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure logic: image loading, colour quantisation, stroke planning, geometry. No AppKit.
        .target(name: "DrawBotCore", path: "Sources/DrawBotCore"),
        // macOS system layer: synthetic mouse events, permissions, hotkeys, window inspection, drawing engine.
        .target(name: "DrawBotSystem", dependencies: ["DrawBotCore"], path: "Sources/DrawBotSystem"),
        // The menu-bar app: UI, canvas selection overlay, colour prompts, orchestration.
        .executableTarget(name: "DrawBot", dependencies: ["DrawBotCore", "DrawBotSystem"], path: "Sources/DrawBot"),
        .testTarget(name: "DrawBotCoreTests", dependencies: ["DrawBotCore"], path: "Tests/DrawBotCoreTests"),
        .testTarget(name: "DrawBotSystemTests", dependencies: ["DrawBotSystem", "DrawBotCore"], path: "Tests/DrawBotSystemTests"),
    ]
)
