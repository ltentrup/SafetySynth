// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "SafetySynth",
    products: [
        .executable(name: "SafetySynth", targets: ["SafetySynth"]),
        .library(name: "SafetyGameSolver", targets: ["SafetyGameSolver"])
        ],
    dependencies: [
        .package(url: "https://github.com/ltentrup/CAiger.git", from: "0.1.0"),
        .package(url: "https://github.com/ltentrup/Aiger.git", from: "0.2.0"),
        .package(url: "https://github.com/ltentrup/CUDD.git", from: "0.2.0"),
        ],
    targets: [
        .target(name: "SafetySynth", dependencies: ["SafetyGameSolver"]),
        .target(name: "SafetyGameSolver", dependencies: ["CAiger", "CAigerHelper", "CUDD", "Aiger"]),
        ]
)
