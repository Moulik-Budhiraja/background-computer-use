// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BackgroundComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BackgroundComputerUse", targets: ["BackgroundComputerUse"]),
        .executable(name: "bcu", targets: ["bcu"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Private macOS APIs (CGVirtualDisplay, SkyLight) wrapped in plain C/ObjC calls.
        .target(
            name: "CPrivate",
            path: "Sources/CPrivate",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        // Wire protocol, tool catalog and socket client shared by the app and the CLI.
        .target(
            name: "BCUShared",
            path: "Sources/BCUShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Display, input, accessibility, capture, window management and the focus guard.
        .target(
            name: "BCUCore",
            dependencies: ["CPrivate", "BCUShared"],
            path: "Sources/BCUCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        // The menu bar app. Owns the virtual display and serves tool calls over a unix socket.
        .executableTarget(
            name: "BackgroundComputerUse",
            dependencies: ["BCUCore", "BCUShared", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BackgroundComputerUse",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI: `bcu mcp` (stdio MCP server for agents) and `bcu call` (debugging).
        .executableTarget(
            name: "bcu",
            dependencies: ["BCUShared"],
            path: "Sources/bcu",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
