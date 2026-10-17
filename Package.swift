// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "distractorRemover",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "distractorRemover", targets: ["DistractorRemover"]),
        .library(name: "BlockerCore", targets: ["BlockerCore"]),
    ],
    targets: [
        // Pure logic, persistence and the privileged-helper backend. No AppKit.
        .target(name: "BlockerCore"),
        // Korean/English wording and date formatting (Foundation only).
        .target(name: "AppText", dependencies: ["BlockerCore"]),
        // The menu bar app (AppKit UI only).
        .executableTarget(name: "DistractorRemover", dependencies: ["BlockerCore", "AppText"]),
    ]
)
