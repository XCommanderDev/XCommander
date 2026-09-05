// swift-tools-version: 6.0
import PackageDescription

// Autographe for Xcode — a keyboard companion that drives Xcode from outside.
//
// The same split the editor uses, and for the same reason: CompanionCore is pure
// logic with no AppKit, so the keymap engine, the session state machine and the
// which-key model all compile and run headless under `swift test`. Everything that
// touches CGEventTap, AXUIElement or an NSWindow lives in Companion, and stays thin.
let package = Package(
    name: "AutographeForXcode",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CompanionCore", targets: ["CompanionCore"]),
        .library(name: "CIndexStore", targets: ["CIndexStore"]),
        .executable(name: "Companion", targets: ["Companion"]),
    ],
    targets: [
        .target(name: "CompanionCore"),
        // Types only, for Xcode's index store. No library is linked: see the header.
        .target(name: "CIndexStore"),
        .executableTarget(name: "Companion", dependencies: ["CompanionCore", "CIndexStore"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ]
)
