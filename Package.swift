// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AISlap",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AISlap",
            path: "Sources/AISlap",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
