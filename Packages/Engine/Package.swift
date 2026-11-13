// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Engine",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "GameCore", targets: ["GameCore"]),
        .library(name: "MapGen", targets: ["MapGen"]),
        .library(name: "MapRendering", targets: ["MapRendering"]),
        .library(name: "GameAI", targets: ["GameAI"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "headless-sim", targets: ["HeadlessSim"]),
    ],
    targets: [
        // Pure Swift simulation. Must never import UIKit/SpriteKit/AppKit. The rules data is a
        // package resource (Sources/GameCore/Rules/*.json), so every module and test can use
        // `Ruleset.standard`.
        .target(name: "GameCore", resources: [.copy("Rules")]),
        .target(name: "MapGen", dependencies: ["GameCore"]),
        .target(name: "MapRendering", dependencies: ["GameCore"]),
        // The M1 AI: decides from its player's knowledge, acts only through GameEngine.
        .target(name: "GameAI", dependencies: ["GameCore"]),
        // Save files.
        .target(name: "Persistence", dependencies: ["GameCore"]),
        .executableTarget(name: "HeadlessSim", dependencies: ["GameCore", "MapGen", "GameAI"]),

        // MapGen: the tribal village tests play on generated maps (phase 3g).
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore", "MapGen"]),
        .testTarget(name: "MapGenTests", dependencies: ["MapGen", "GameCore"]),
        .testTarget(name: "MapRenderingTests", dependencies: ["MapRendering", "GameCore", "MapGen"]),
        .testTarget(name: "GameAITests", dependencies: ["GameAI", "GameCore", "MapGen"]),
        // Fixtures: a version-1 save written before tribal villages (phase 3g), with its hashes.
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "GameCore", "MapGen"], resources: [.copy("Fixtures")]),
    ]
)
