// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pastly",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pastly",
            path: "Sources/Pastly",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
