// swift-tools-version:5.9
import PackageDescription

// Layering mirrors Ghostty:
//   CPTY        ~ ghostty/src/pty.c + src/pty.zig      (openpty/forkpty, TIOCSWINSZ)
//   MantisCore  ~ ghostty/src/terminal (libghostty-vt)  (parser, screen state, encoders) — no UI deps
//   Mantis      ~ ghostty/macos + src/apprt + renderer  (AppKit shell, threads, drawing)
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
    ]
)
