// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "distractorRemover",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "distractorRemover", targets: ["DistractorRemover"]),
    ],
    targets: [
        // Pure logic, persistence and the privileged-helper backend. No AppKit.
        .target(name: "BlockerCore"),
        // The menu bar app (AppKit UI only).
        .executableTarget(name: "DistractorRemover", dependencies: ["BlockerCore"]),
        // Self-contained checks: Command Line Tools ship neither XCTest nor the
        // swift-testing macro plugin, so tests run as `swift run CoreChecks`.
        .executableTarget(
            name: "CoreChecks",
            dependencies: ["BlockerCore"],
            path: "Tests/CoreChecks"
        ),
    ]
)
