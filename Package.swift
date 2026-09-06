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
        .executableTarget(
            name: "Companion",
            dependencies: ["CompanionCore", "CIndexStore"],
            // SwiftPM cannot build an asset catalogue or an Icon Composer document, and it
            // does not own the Info.plist either: `tools/xc.sh` assembles the .app and runs
            // `actool` over these by hand. Excluding them silences the "unhandled files"
            // warning without changing what ships — the bundle still gets its icon, which
            // matters because macOS shows it in the "would like to control this computer"
            // prompt.
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "AutographeAppIcon.icon",
            ]
        ),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
    ]
)
