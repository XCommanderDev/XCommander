// swift-tools-version: 6.0
import PackageDescription

// XCommander — a keyboard companion that drives Xcode from outside.
//
// The same split the editor uses, and for the same reason: XCommanderCore is pure
// logic with no AppKit, so the keymap engine, the session state machine and the
// which-key model all compile and run headless under `swift test`. Everything that
// touches CGEventTap, AXUIElement or an NSWindow lives in Companion, and stays thin.
let package = Package(
    name: "XCommander",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "XCommanderCore", targets: ["XCommanderCore"]),
        .library(name: "CIndexStore", targets: ["CIndexStore"]),
        .library(name: "CSourceKit", targets: ["CSourceKit"]),
        // The AX menu walk, shared by the app and the maintainer's CLI so that both see
        // exactly the same menu bar. An audit of something other than what ships is worthless.
        .library(name: "XcodeMenus", targets: ["XcodeMenus"]),
        .executable(name: "Companion", targets: ["Companion"]),
        .executable(name: "xcmdr", targets: ["xcmdr"]),
        // The developer tool: build, sign and run the app from Terminal, regenerate icons.
        .executable(name: "xcdev", targets: ["xcdev"]),
    ],
    targets: [
        .target(name: "XCommanderCore"),
        // Types only, for Xcode's index store. No library is linked: see the header.
        .target(name: "CIndexStore"),
        // Types only, for sourcekitd. Exists because its variant is a by-value
        // struct, which Swift will not put through @convention(c).
        .target(name: "CSourceKit"),
        .target(name: "XcodeMenus", dependencies: ["XCommanderCore"]),
        // The maintainer's tool: capture, audit, diff, doctor. No dependencies beyond the
        // two libraries, and no argument-parsing package — this project hand-rolls its TOML
        // reader for the same reason.
        .executableTarget(name: "xcmdr", dependencies: ["XCommanderCore", "XcodeMenus"]),
        .executableTarget(name: "xcdev"),
        .executableTarget(
            name: "Companion",
            dependencies: ["XCommanderCore", "CIndexStore", "CSourceKit", "XcodeMenus"],
            // SwiftPM cannot build an asset catalogue or an Icon Composer document, and it
            // does not own the Info.plist either: `xcdev` assembles the .app and runs
            // `actool` over these by hand. Excluding them silences the "unhandled files"
            // warning without changing what ships — the bundle still gets its icon, which
            // matters because macOS shows it in the "would like to control this computer"
            // prompt.
            exclude: [
                "Info.plist",
                "Assets.xcassets",
                "XCommanderAppIcon.icon",
            ]
        ),
        .testTarget(name: "XCommanderCoreTests", dependencies: ["XCommanderCore"]),
        .testTarget(name: "XcodeMenusTests", dependencies: ["XcodeMenus", "XCommanderCore"]),
    ]
)
