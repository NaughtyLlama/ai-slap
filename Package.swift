// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISlap",
    platforms: [.macOS(.v14)],  // SCScreenshotManager (handoff capture) is 14+
    targets: [
        .executableTarget(
            name: "AISlap",
            path: "Sources/AISlap",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
