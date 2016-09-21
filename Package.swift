import PackageDescription

let package = Package(
    name: "SafetySynth",
    dependencies: [
        .Package(url: "https://github.com/ltentrup/CAiger.git", majorVersion: 0, minor: 1),
        .Package(url: "https://github.com/ltentrup/Aiger.git", majorVersion: 0, minor: 2),
        .Package(url: "https://github.com/ltentrup/CUDD.git", majorVersion: 0, minor: 2),
    ]
)