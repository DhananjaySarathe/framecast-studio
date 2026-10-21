// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Framecast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Framecast", targets: ["Framecast"]),
        .executable(name: "fcverify", targets: ["fcverify"]),
        .executable(name: "framecast-mcp", targets: ["framecast-mcp"]),
        .library(name: "FramecastEngine", targets: ["FramecastEngine"]),
    ],
    dependencies: [
        // Open-source (Apache-2.0) WebRTC client for guests; talks to a LiveKit server on this Mac.
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.8.1"),
    ],
    targets: [
        .target(
            name: "FramecastEngine",
            path: "Sources/FramecastEngine"
        ),
        .executableTarget(
            name: "Framecast",
            dependencies: ["FramecastEngine", .product(name: "LiveKit", package: "client-sdk-swift")],
            path: "Sources/Framecast",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // Passes MCP messages between apps like Claude Desktop and Framecast's local control link.
        .executableTarget(
            name: "framecast-mcp",
            path: "Sources/framecast-mcp"
        ),
        .executableTarget(
            name: "fcverify",
            dependencies: ["FramecastEngine"],
            path: "Sources/fcverify"
        ),
    ]
)
