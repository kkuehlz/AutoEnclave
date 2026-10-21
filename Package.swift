// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoEnclave",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AutoEnclave",
            path: "Sources/AutoEnclave"
        )
    ],
    swiftLanguageVersions: [.v5]
)
