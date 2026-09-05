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
        .executable(name: "Companion", targets: ["Companion"]),
    ],
    dependencies: [
        // Xcode has no terminal at all — only the LLDB console — so a terminal has to be
        // ours. SwiftTerm is a real emulator; a hand-rolled PTY with escape sequences
        // stripped is unusable the moment anything draws (`less`, `htop`, colour).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
    ],
    targets: [
        .target(name: "CompanionCore"),
        // Types only, for Xcode's index store. No library is linked: see the header.
        .target(name: "CIndexStore"),
        .executableTarget(name: "Companion",
                          dependencies: ["CompanionCore", "CIndexStore",
                                         .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ]
)
