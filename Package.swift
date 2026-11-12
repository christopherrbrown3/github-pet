// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GitHubPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GitHubPet", targets: ["GitHubPet"]),
        .library(name: "GitHubPetCore", targets: ["GitHubPetCore"]),
    ],
    targets: [
        // Pure, UI-free logic: inbox state, event dedupe, settings, gh CLI, link safety.
        .target(name: "GitHubPetCore"),
        // SwiftUI menu-bar app plus AppKit mascot window.
        .executableTarget(name: "GitHubPet", dependencies: ["GitHubPetCore"]),
        .testTarget(name: "GitHubPetCoreTests", dependencies: ["GitHubPetCore"]),
    ]
)
