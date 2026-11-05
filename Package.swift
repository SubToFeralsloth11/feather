// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Feather",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Feather",
            path: "Sources/Feather",
            linkerSettings: [
                .linkedFramework("WebKit"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
