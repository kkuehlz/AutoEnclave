// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoEnclave",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SSHConfigKit", path: "Sources/SSHConfigKit"),
        .executableTarget(
            name: "AutoEnclave",
            dependencies: ["SSHConfigKit"],
            path: "Sources/AutoEnclave"
        ),
        // Self-checks for the ssh_config parser. Neither XCTest nor swift-testing ship with
        // Command Line Tools, so this is a plain executable: `make test`.
        .executableTarget(
            name: "sshconfig-checks",
            dependencies: ["SSHConfigKit"],
            path: "Sources/sshconfig-checks"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
