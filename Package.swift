// swift-tools-version:5.9
import PackageDescription

// Layering:
//   CPTY        pty shim                (openpty/forkpty, TIOCSWINSZ)
//   MantisCore  terminal core           (parser, screen state, encoders) — no UI deps
//   Mantis      macOS app               (AppKit shell, threads, drawing)
let package = Package(
    name: "Mantis",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Mantis", targets: ["Mantis"]),
        .library(name: "MantisCore", targets: ["MantisCore"]),
    ],
    targets: [
        .target(name: "CPTY"),
        // Hot path: skip runtime exclusivity checks on class property access (Swift keeps them on in -O).
        .target(name: "MantisCore", swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]),
        .executableTarget(name: "Mantis", dependencies: ["MantisCore", "CPTY"]),
        .testTarget(name: "MantisCoreTests", dependencies: ["MantisCore"]),
        .testTarget(name: "MantisTests", dependencies: ["Mantis", "MantisCore"]),
    ]
)
