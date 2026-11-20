// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GitHubPet",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GitHubPet", targets: ["GitHubPet"]),
        .library(name: "GitHubPetCore", targets: ["GitHubPetCore"]),
    ],
    dependencies: [
        // Automatic updates (#90). Exact stable release, not the 2.11 beta.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure, UI-free logic: inbox state, event dedupe, settings, gh CLI, link safety.
        .target(name: "GitHubPetCore"),
        // SwiftUI menu-bar app plus AppKit mascot window.
        .executableTarget(name: "GitHubPet", dependencies: [
            "GitHubPetCore",
            .product(name: "Sparkle", package: "Sparkle"),
        ]),
        .testTarget(name: "GitHubPetCoreTests", dependencies: ["GitHubPetCore"]),
        .testTarget(name: "GitHubPetAppTests", dependencies: ["GitHubPet"]),
    ]
)
