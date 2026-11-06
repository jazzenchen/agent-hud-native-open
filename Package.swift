// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentHUDOpen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentHUDSupport", targets: ["AgentHUDSupport"]),
        .library(name: "AgentHUDCore", targets: ["AgentHUDCore"]),
        .library(name: "AgentHUDDesktop", targets: ["AgentHUDDesktop"]),
        .executable(name: "AgentHUDOpen", targets: ["AgentHUDOpenApp"]),
    ],
    targets: [
        .target(name: "AgentHUDSupport", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AgentHUDCore", dependencies: ["AgentHUDSupport"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AgentHUDDesktop", dependencies: ["AgentHUDCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "AgentHUDOpenApp", dependencies: ["AgentHUDDesktop", "AgentHUDCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AgentHUDSupportTests", dependencies: ["AgentHUDSupport"]),
        .testTarget(name: "AgentHUDCoreTests", dependencies: ["AgentHUDCore", "AgentHUDSupport"],
                    resources: [.copy("Providers/Kit/Zstandard/Fixtures")]),
        .testTarget(name: "AgentHUDDesktopTests", dependencies: ["AgentHUDDesktop"]),
    ]
)
