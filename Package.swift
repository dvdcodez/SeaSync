// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SeaSync",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SeaSync", targets: ["SeaSync"])
    ],
    targets: [
        .executableTarget(
            name: "SeaSync",
            path: "SeaSync",
            resources: [
                .process("Assets.xcassets")
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreServices")
            ]
        )
    ]
)
