// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "helios",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "helios",
            path: "Sources/helios",
            swiftSettings: [
                // Strictly sequential CLI; Swift 6 concurrency checks add no value.
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedFramework("NetFS")
            ]
        )
    ]
)
