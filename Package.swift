// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentFloat",
    // tools-version 6.0 에는 .v26 상수가 없어(6.2부터) 문자열 형태로 같은 배포 타깃을 지정한다
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
        // 답장 화면 상태(ReplyCenter)는 앱 타깃에 있어 따로 둔다
        .testTarget(name: "AgentFloatTests", dependencies: ["AgentFloat", "AgentFloatCore"]),
    ],
    swiftLanguageModes: [.v6]
)
