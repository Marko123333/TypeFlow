// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeFlow",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "SwitcherCore",
            path: "Sources/SwitcherCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TypeFlow",
            dependencies: ["SwitcherCore"],
            path: "Sources/TypeFlow",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "SwitcherCoreTests",
            dependencies: ["SwitcherCore"],
            path: "Tests/SwitcherCoreTests"
        ),
        .testTarget(
            name: "TypeFlowTests",
            dependencies: ["TypeFlow"],
            path: "Tests/TypeFlowTests"
        ),
    ]
)
