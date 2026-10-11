// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Autotime",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Autotime",
            path: "Sources/Autotime",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
