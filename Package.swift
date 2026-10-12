// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Autotime",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Autotime",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Autotime",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
