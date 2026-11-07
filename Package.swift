// swift-tools-version: 5.9
// EdgePal: the edges of your Mac trackpad, put to work.
import PackageDescription

let package = Package(
    name: "EdgePal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EdgePal", targets: ["EdgePal"]),
        // Loaded at runtime by /usr/bin/perl, never linked into the app. See MediaHelper.swift.
        .library(name: "EdgePalMedia", type: .dynamic, targets: ["EdgePalMedia"]),
    ],
    targets: [
        .executableTarget(
            name: "EdgePal",
            dependencies: ["EdgeTouch"],
            path: "Sources/EdgePal"
        ),
        // Small C bridge to Apple's private MultitouchSupport framework (raw finger positions + haptics).
        .target(
            name: "EdgeTouch",
            path: "Sources/EdgeTouch"
        ),
        .target(
            name: "EdgePalMedia",
            path: "Sources/EdgePalMedia",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation")]
        ),
    ]
)
