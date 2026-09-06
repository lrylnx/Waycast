// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waycast",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Waycast",
            path: "Sources/Waycast",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreServices"),
                .linkedFramework("Vision"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
            ]
        )
    ]
)
