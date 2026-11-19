// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Restor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Restor",
            path: "Sources/Restor",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
