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
                // CPU 温度走 IOHID 的 AppleVendor 温度传感器（IOHIDEventSystemClient）。
                .linkedFramework("IOKit"),
                .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
            ]
        )
    ]
)
