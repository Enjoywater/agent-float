// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentFloat",
    // tools-version 6.0 lacks .v26 (added in 6.2); use the equivalent string deployment target.
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AgentFloatCore", targets: ["AgentFloatCore"]),
        .executable(name: "AgentFloat", targets: ["AgentFloat"]),
    ],
    targets: [
        .target(name: "AgentFloatCore"),
        .executableTarget(name: "AgentFloat", dependencies: ["AgentFloatCore"]),
        .testTarget(
            name: "AgentFloatCoreTests",
            dependencies: ["AgentFloatCore"],
            resources: [.copy("Fixtures")]
        ),
        // ReplyCenter lives in the app target, so its tests need a separate target.
        .testTarget(name: "AgentFloatTests", dependencies: ["AgentFloat", "AgentFloatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
