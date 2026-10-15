// swift-tools-version: 6.0
import PackageDescription

// AgentHUDDesktop is built on AppKit and SwiftUI, which only exist on macOS, so the manifest declares it — and the
// executable's dependence on it — only there. Everything else, the platform-neutral record, data source and storage
// layers, builds on both; on Windows AgentHUDOpenApp runs its hook, adapter and probe commands without the interface.
// The SDK's SQLite3 module is likewise macOS-only, so on Windows the vendored amalgamation provides it instead.
#if os(Windows)
let platforms: [SupportedPlatform]? = nil
let uiTargets: [Target] = []
let uiTests: [Target] = []
let desktopDependencies: [Target.Dependency] = []
let sqliteTargets: [Target] = [.target(name: "SQLite3")]
let coreDependencies: [Target.Dependency] = ["SQLite3"]
let products: [Product] = [
    .library(name: "AgentHUDSupport", targets: ["AgentHUDSupport"]),
    .library(name: "AgentHUDCore", targets: ["AgentHUDCore"]),
    .executable(name: "AgentHUDOpen", targets: ["AgentHUDOpenApp"]),
]
#else
let platforms: [SupportedPlatform]? = [.macOS(.v14)]
let uiTargets: [Target] = [
    .target(name: "AgentHUDDesktop", dependencies: ["AgentHUDCore"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v6)]),
]
let uiTests: [Target] = [
    .testTarget(name: "AgentHUDDesktopTests", dependencies: ["AgentHUDDesktop"]),
]
let desktopDependencies: [Target.Dependency] = ["AgentHUDDesktop"]
let sqliteTargets: [Target] = []
let coreDependencies: [Target.Dependency] = []
let products: [Product] = [
    .library(name: "AgentHUDSupport", targets: ["AgentHUDSupport"]),
    .library(name: "AgentHUDCore", targets: ["AgentHUDCore"]),
    .library(name: "AgentHUDDesktop", targets: ["AgentHUDDesktop"]),
    .executable(name: "AgentHUDOpen", targets: ["AgentHUDOpenApp"]),
]
#endif

let package = Package(
    name: "AgentHUDOpen",
    platforms: platforms,
    products: products,
    targets: sqliteTargets + uiTargets + [
        .target(name: "AgentHUDSupport", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "AgentHUDCore", dependencies: coreDependencies + ["AgentHUDSupport"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "AgentHUDOpenApp", dependencies: desktopDependencies + ["AgentHUDCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "AgentHUDSupportTests", dependencies: ["AgentHUDSupport"]),
        .testTarget(name: "AgentHUDCoreTests", dependencies: ["AgentHUDCore", "AgentHUDSupport"]),
    ] + uiTests,
)
